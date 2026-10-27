#!/usr/bin/env bash

set -Eeuo pipefail

###############################################################################
# Configuration (keep VIRSH_*, STATE_FILE and LOCK_FILE identical in both scripts)
###############################################################################
VIRSH_GPU_VIDEO="pci_0000_01_00_0"
VIRSH_GPU_AUDIO="pci_0000_01_00_1"
MEMORY_MB=16384
HOST_CPUS="0,1,2,3"            # CPUs left to the host while the VM runs
HUGEPAGE_MAX_TRIES=100

DESKTOP_USER="user"            # who receives desktop notifications

STATE_FILE="/run/vm-gpu-passthrough.state"
LOCK_FILE="/run/vm-gpu-passthrough.lock"

# Logging: on by default; disable with ENABLE_LOGGING=0
ENABLE_LOGGING="${ENABLE_LOGGING:-1}"
LOG_DIR="${LOG_DIR:-/var/log/vm-gpu-passthrough}"
LOG_FILE="$LOG_DIR/setup.log"
LOG_MODE="${LOG_MODE:-0644}"                  # world-readable so a normal user can read it
LOG_MAX_BYTES=$((5 * 1024 * 1024))            # rotate once to setup.log.1 above this

NVIDIA_MODULES=(nvidia nvidia_modeset nvidia_drm nvidia_uvm)
NVIDIA_UNLOAD_ORDER=(nvidia_uvm nvidia_drm nvidia_modeset nvidia)
VFIO_MODULES=(vfio_pci vfio_iommu_type1 vfio)
VFIO_UNLOAD_ORDER=(vfio_pci vfio_iommu_type1 vfio)
CPU_UNITS=(user.slice system.slice init.scope)
SLEEP_UNITS=(sleep.target suspend.target hibernate.target hybrid-sleep.target)

###############################################################################
# Logging helpers
###############################################################################
LOGGING_ACTIVE=0
LOG_OUT_PID=""
LOG_ERR_PID=""

log()  { echo "$*"; }
warn() { echo "WARNING: $*" >&2; }
die()  { echo "ERROR: $*" >&2; exit 1; }

# Copies each line to the original console fd and to the log with a timestamp.
log_pipe() {
    local level="$1" fd="$2" line
    while IFS= read -r line; do
        printf '%s\n' "$line" >&"$fd"
        printf '%(%Y-%m-%d %H:%M:%S)T [%s] %s\n' -1 "$level" "$line" >> "$LOG_FILE" 2>/dev/null || true
    done
}

setup_logging() {
    [[ "$ENABLE_LOGGING" == "1" ]] || return 0

    (
        umask 022
        [[ -d "$LOG_DIR" ]] || mkdir -p -m 0755 "$LOG_DIR"
        if [[ -f "$LOG_FILE" ]] && (( $(stat -c %s "$LOG_FILE") > LOG_MAX_BYTES )); then
            mv -f -- "$LOG_FILE" "$LOG_FILE.1"
            chmod "$LOG_MODE" "$LOG_FILE.1" || true
        fi
        touch "$LOG_FILE"
        chmod "$LOG_MODE" "$LOG_FILE"
    ) || { echo "WARNING: cannot prepare $LOG_FILE; continuing without a log file." >&2; return 0; }

    exec 3>&1 4>&2
    exec > >(log_pipe INFO 3)
    LOG_OUT_PID=$!
    exec 2> >(log_pipe ERROR 4)
    LOG_ERR_PID=$!
    LOGGING_ACTIVE=1
    echo "=== $(basename "$0") started (pid $$) - logging to $LOG_FILE ==="
}

stop_logging() {
    (( LOGGING_ACTIVE )) || return 0
    LOGGING_ACTIVE=0
    exec 1>&3 2>&4
    wait "$LOG_OUT_PID" "$LOG_ERR_PID" 2>/dev/null || true
}

###############################################################################
# Rollback state
###############################################################################
ORIG_POWERD_ACTIVE=0
ORIG_HUGEPAGES=""
STATE_SAVED=0
POWERD_TOUCHED=0
NVIDIA_UNLOAD_ATTEMPTED=0
VFIO_LOAD_ATTEMPTED=0
VIDEO_DETACH_ATTEMPTED=0
AUDIO_DETACH_ATTEMPTED=0
HUGEPAGES_CHANGED=0
SLEEP_MASK_ATTEMPTED=0

declare -A NVIDIA_WAS_LOADED=()
declare -A VFIO_WAS_LOADED=()
declare -A SLEEP_WAS_MASKED=()
declare -A CPU_OLD_ALLOWED=()
declare -A CPU_CHANGE_ATTEMPTED=()
declare -A DRM_SEEN=()
NVIDIA_DRM_NODES=()

###############################################################################
# Helpers
###############################################################################
module_is_loaded() {
    awk -v m="$1" '$1 == m { found = 1 } END { exit !found }' /proc/modules
}

# Key suffix usable in the state file: "user.slice" -> "user_slice"
state_key() { printf '%s_%s' "$1" "${2//[^A-Za-z0-9]/_}"; }

virsh_node_to_bdf() {
    local node="$1" prefix domain bus slot fn
    [[ "$node" =~ ^pci_[0-9a-f]{4}_[0-9a-f]{2}_[0-9a-f]{2}_[0-7]$ ]] || return 1
    IFS=_ read -r prefix domain bus slot fn <<< "$node"
    printf '%s:%s:%s.%s\n' "$domain" "$bus" "$slot" "$fn"
}

notify_user() {
    local uid bus
    command -v notify-send >/dev/null 2>&1 || return 0
    uid="$(id -u "$DESKTOP_USER" 2>/dev/null)" || return 0
    bus="/run/user/$uid/bus"
    [[ -S "$bus" ]] || return 0
    timeout 5 runuser -u "$DESKTOP_USER" -- \
        env DBUS_SESSION_BUS_ADDRESS="unix:path=$bus" \
        notify-send -t 5000 "$@" >/dev/null 2>&1 || true
}

add_drm_node() {
    local path="$1"
    [[ -c "$path" ]] || return 0
    path="$(readlink -f -- "$path" 2>/dev/null || true)"
    [[ -n "$path" && -z "${DRM_SEEN[$path]:-}" ]] || return 0
    DRM_SEEN[$path]=1
    NVIDIA_DRM_NODES+=("$path")
}

# Finds /dev/dri card and render nodes that belong to one PCI device.
# Uses several independent methods and merges the results:
#   1. /sys/bus/pci/devices/<bdf>/drm/        (authoritative; falls back to /dev/char/MAJ:MIN)
#   2. /sys/class/drm/*/device symlink scan   (case-insensitive BDF match)
#   3. /dev/dri/by-path/pci-<bdf>-*           (udev symlinks)
find_target_gpu_drm_nodes() {
    local bdf="${1,,}" entry name real link
    NVIDIA_DRM_NODES=()
    DRM_SEEN=()

    for entry in "/sys/bus/pci/devices/$bdf/drm/"*; do
        [[ -e "$entry" ]] || continue
        name="${entry##*/}"
        [[ "$name" =~ ^(card|renderD)[0-9]+$ ]] || continue
        if [[ -c "/dev/dri/$name" ]]; then
            add_drm_node "/dev/dri/$name"
        elif [[ -r "$entry/dev" ]]; then
            add_drm_node "/dev/char/$(<"$entry/dev")"
        fi
    done

    for entry in /sys/class/drm/*; do
        [[ -e "$entry" ]] || continue
        name="${entry##*/}"
        [[ "$name" =~ ^(card|renderD)[0-9]+$ ]] || continue
        real="$(readlink -f -- "$entry/device" 2>/dev/null || true)"
        [[ -n "$real" && "${real##*/}" == "$bdf" ]] || continue
        add_drm_node "/dev/dri/$name"
    done

    for link in /dev/dri/by-path/pci-"$bdf"-*; do
        [[ -e "$link" ]] || continue
        add_drm_node "$link"
    done
}

write_state() {
    local tmp unit module
    tmp="$(mktemp "${STATE_FILE}.XXXXXX")"
    {
        echo "# vm-gpu-passthrough state - written by sethugepages.sh"
        echo "VERSION=2"
        printf 'CREATED=%(%s)T\n' -1
        echo "GPU_VIDEO=$VIRSH_GPU_VIDEO"
        echo "GPU_AUDIO=$VIRSH_GPU_AUDIO"
        echo "HUGEPAGES=$ORIG_HUGEPAGES"
        echo "POWERD_ACTIVE=$ORIG_POWERD_ACTIVE"
        for unit in "${CPU_UNITS[@]}"; do
            echo "$(state_key CPU "$unit")=${CPU_OLD_ALLOWED[$unit]}"
        done
        for unit in "${SLEEP_UNITS[@]}"; do
            echo "$(state_key SLEEPMASKED "$unit")=${SLEEP_WAS_MASKED[$unit]}"
        done
        for module in "${NVIDIA_MODULES[@]}"; do
            echo "$(state_key NVIDIA "$module")=${NVIDIA_WAS_LOADED[$module]}"
        done
        for module in "${VFIO_MODULES[@]}"; do
            echo "$(state_key VFIO "$module")=${VFIO_WAS_LOADED[$module]}"
        done
        echo "END=1"   # lets the restore script detect a truncated file
    } > "$tmp" || { rm -f -- "$tmp"; return 1; }
    chmod 600 "$tmp"
    mv -f -- "$tmp" "$STATE_FILE"
}

###############################################################################
# Failure rollback / exit handling
###############################################################################
rollback() {
    local rc="$1" module unit
    echo "Setup failed (exit $rc); attempting rollback..." >&2
    set +e +E

    for unit in "${SLEEP_UNITS[@]}"; do
        if (( SLEEP_MASK_ATTEMPTED )) && [[ ${SLEEP_WAS_MASKED[$unit]:-0} == 0 ]]; then
            systemctl unmask --runtime "$unit" || true
        fi
    done

    for unit in "${CPU_UNITS[@]}"; do
        if [[ ${CPU_CHANGE_ATTEMPTED[$unit]:-0} == 1 ]]; then
            systemctl set-property --runtime "$unit" "AllowedCPUs=${CPU_OLD_ALLOWED[$unit]}" || true
        fi
    done

    # NVIDIA must be loaded before the GPU is handed back to the host.
    if (( NVIDIA_UNLOAD_ATTEMPTED )); then
        for module in "${NVIDIA_MODULES[@]}"; do
            if [[ ${NVIDIA_WAS_LOADED[$module]:-0} == 1 ]]; then
                modprobe "$module" || true
            fi
        done
    fi

    (( VIDEO_DETACH_ATTEMPTED )) && { virsh nodedev-reattach "$VIRSH_GPU_VIDEO" || true; }
    (( AUDIO_DETACH_ATTEMPTED )) && { virsh nodedev-reattach "$VIRSH_GPU_AUDIO" || true; }

    if (( VFIO_LOAD_ATTEMPTED )); then
        for module in "${VFIO_UNLOAD_ORDER[@]}"; do
            if [[ ${VFIO_WAS_LOADED[$module]:-0} == 0 ]] && module_is_loaded "$module"; then
                modprobe -r "$module" || true
            fi
        done
    fi

    if (( HUGEPAGES_CHANGED )) && [[ -n "$ORIG_HUGEPAGES" ]]; then
        printf '%s\n' "$ORIG_HUGEPAGES" > /proc/sys/vm/nr_hugepages || true
    fi

    if (( POWERD_TOUCHED && ORIG_POWERD_ACTIVE )); then
        systemctl start nvidia-powerd.service || true
    fi

    # Remove state only if this run created it; a pre-existing file is preserved.
    (( STATE_SAVED )) && rm -f -- "$STATE_FILE"
    return 0
}

on_exit() {
    local rc=$?
    trap - EXIT
    if (( rc != 0 )); then
        rollback "$rc"
    fi
    stop_logging
    exit "$rc"
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'echo "ERROR: line $LINENO: $BASH_COMMAND" >&2' ERR

###############################################################################
# Pre-flight checks
###############################################################################
if (( EUID != 0 )); then
    echo "Run this script as root." >&2
    exit 1
fi

setup_logging

# Only one setup/restore at a time.
exec 9>"$LOCK_FILE"
flock -n 9 || die "Another setup/restore is already running."

for cmd in virsh modprobe systemctl fuser awk flock mktemp readlink; do
    command -v "$cmd" >/dev/null 2>&1 || die "Required command not found: $cmd"
done

GPU_BDF="$(virsh_node_to_bdf "$VIRSH_GPU_VIDEO")" || die "Invalid VIRSH_GPU_VIDEO: $VIRSH_GPU_VIDEO"
AUDIO_BDF="$(virsh_node_to_bdf "$VIRSH_GPU_AUDIO")" || die "Invalid VIRSH_GPU_AUDIO: $VIRSH_GPU_AUDIO"
[[ "$MEMORY_MB" =~ ^[1-9][0-9]*$ ]] || die "MEMORY_MB must be a positive integer."
[[ "$HOST_CPUS" =~ ^[0-9]+([,-][0-9]+)*$ ]] || die "HOST_CPUS is not a valid CPU list: $HOST_CPUS"

for dev in "$GPU_BDF" "$AUDIO_BDF"; do
    [[ -r "/sys/bus/pci/devices/$dev/vendor" ]] || die "PCI device not found in sysfs: $dev"
    vendor="$(<"/sys/bus/pci/devices/$dev/vendor")"
    [[ "$vendor" == "0x10de" ]] || die "Device $dev is not an NVIDIA PCI device (vendor $vendor)."
done

[[ -d "/sys/bus/pci/devices/$GPU_BDF/iommu_group" ]] \
    || die "No IOMMU group for $GPU_BDF - is IOMMU enabled in firmware and on the kernel command line?"

# Warn if the IOMMU group contains devices that are not part of the GPU.
for dev_path in "/sys/bus/pci/devices/$GPU_BDF/iommu_group/devices/"*; do
    dev="${dev_path##*/}"
    [[ "$dev" == "$GPU_BDF" || "$dev" == "$AUDIO_BDF" ]] && continue
    class="$(cat "$dev_path/class" 2>/dev/null || echo 0)"
    [[ "$class" == 0x0604* ]] && continue   # PCI bridges are fine
    warn "IOMMU group of $GPU_BDF also contains $dev; passthrough may fail."
done

if [[ "$(cat "/sys/bus/pci/devices/$GPU_BDF/boot_vga" 2>/dev/null || echo 0)" == "1" ]]; then
    warn "$GPU_BDF is the boot VGA device; it may be driving the host display."
fi

# A leftover state file may mean an earlier restore did not finish.
if [[ -e "$STATE_FILE" ]]; then
    die "State file already exists; run removehugepages.sh first (or delete it if nothing is detached): $STATE_FILE"
fi

HUGEPAGE_KB="$(awk '/^Hugepagesize:/ { print $2 }' /proc/meminfo)"
[[ -n "$HUGEPAGE_KB" ]] && (( HUGEPAGE_KB > 0 )) || die "Could not determine the system hugepage size."
MEMORY_KB=$((MEMORY_MB * 1024))
(( MEMORY_KB % HUGEPAGE_KB == 0 )) || die "Requested memory is not a multiple of the hugepage size (${HUGEPAGE_KB} kB)."
HUGEPAGES=$((MEMORY_KB / HUGEPAGE_KB))
MEMTOTAL_KB="$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo)"
(( MEMORY_KB < MEMTOTAL_KB )) || die "Requested ${MEMORY_MB} MB is not smaller than total system memory."

###############################################################################
# Capture and persist original state
###############################################################################
if systemctl is-active --quiet nvidia-powerd.service; then
    ORIG_POWERD_ACTIVE=1
fi

for module in "${NVIDIA_MODULES[@]}"; do
    if module_is_loaded "$module"; then NVIDIA_WAS_LOADED[$module]=1; else NVIDIA_WAS_LOADED[$module]=0; fi
done
for module in "${VFIO_MODULES[@]}"; do
    if module_is_loaded "$module"; then VFIO_WAS_LOADED[$module]=1; else VFIO_WAS_LOADED[$module]=0; fi
done
for unit in "${SLEEP_UNITS[@]}"; do
    state="$(systemctl is-enabled "$unit" 2>/dev/null || true)"
    if [[ "$state" == masked* ]]; then SLEEP_WAS_MASKED[$unit]=1; else SLEEP_WAS_MASKED[$unit]=0; fi
done
for unit in "${CPU_UNITS[@]}"; do
    CPU_OLD_ALLOWED[$unit]="$(systemctl show --property=AllowedCPUs --value "$unit" 2>/dev/null || true)"
done
ORIG_HUGEPAGES="$(cat /proc/sys/vm/nr_hugepages)"

write_state
STATE_SAVED=1
log "Saved restore state to $STATE_FILE"

###############################################################################
# Setup
###############################################################################
POWERD_TOUCHED=1
systemctl stop nvidia-powerd.service 2>/dev/null || true

# Allocate hugepages first: it is the step most likely to fail, and it is cheap to undo.
log "Allocating $HUGEPAGES hugepages (${HUGEPAGE_KB} kB each)..."
HUGEPAGES_CHANGED=1
printf '%s\n' "$HUGEPAGES" > /proc/sys/vm/nr_hugepages

TRIES=0
ALLOC_PAGES="$(cat /proc/sys/vm/nr_hugepages)"
while (( ALLOC_PAGES != HUGEPAGES && TRIES < HUGEPAGE_MAX_TRIES )); do
    printf '1\n' > /proc/sys/vm/compact_memory
    printf '%s\n' "$HUGEPAGES" > /proc/sys/vm/nr_hugepages
    ALLOC_PAGES="$(cat /proc/sys/vm/nr_hugepages)"
    log "Allocated $ALLOC_PAGES / $HUGEPAGES hugepages"
    TRIES=$((TRIES + 1))
    sleep 0.1
done
(( ALLOC_PAGES == HUGEPAGES )) || die "Could not allocate all requested hugepages ($ALLOC_PAGES / $HUGEPAGES)."

# Refuse to detach the GPU if NVIDIA or its DRM nodes are in use.
shopt -s nullglob
NVIDIA_DEVICE_NODES=(/dev/nvidia* /dev/nvidia-caps/*)
shopt -u nullglob

find_target_gpu_drm_nodes "$GPU_BDF"
if ((${#NVIDIA_DRM_NODES[@]})); then
    log "DRM nodes for $GPU_BDF: ${NVIDIA_DRM_NODES[*]}"
else
    log "No DRM card/render nodes found for $GPU_BDF (normal if nvidia_drm modeset is off)."
fi

CHECK_NODES=("${NVIDIA_DEVICE_NODES[@]}" "${NVIDIA_DRM_NODES[@]}")
if ((${#CHECK_NODES[@]})) && fuser -s "${CHECK_NODES[@]}" 2>/dev/null; then
    users="$(fuser -v "${CHECK_NODES[@]}" 2>&1 || true)"
    notify_user "NVIDIA GPU is in use" "$users"
    echo "NVIDIA device nodes are in use; refusing to detach the GPU." >&2
    echo "$users" >&2
    exit 1
fi

sleep 1

# Unload only NVIDIA modules that were loaded before setup.
NVIDIA_UNLOAD_ATTEMPTED=1
for module in "${NVIDIA_UNLOAD_ORDER[@]}"; do
    if [[ ${NVIDIA_WAS_LOADED[$module]:-0} == 1 ]]; then
        log "Unloading $module"
        modprobe -r -w 1 "$module"
    fi
done

sleep 1

# Mark each device before detaching, so rollback handles partial failure.
VFIO_LOAD_ATTEMPTED=1
VIDEO_DETACH_ATTEMPTED=1
virsh nodedev-detach "$VIRSH_GPU_VIDEO"
AUDIO_DETACH_ATTEMPTED=1
virsh nodedev-detach "$VIRSH_GPU_AUDIO"

for dev in "$GPU_BDF" "$AUDIO_BDF"; do
    drv_link="/sys/bus/pci/devices/$dev/driver"
    drv="none"
    [[ -L "$drv_link" ]] && drv="$(basename "$(readlink -f "$drv_link")")"
    log "$dev is now bound to: $drv"
done

for unit in "${CPU_UNITS[@]}"; do
    CPU_CHANGE_ATTEMPTED[$unit]=1
    systemctl set-property --runtime "$unit" "AllowedCPUs=$HOST_CPUS"
done

# Runtime masks do not persist across reboot.
SLEEP_MASK_ATTEMPTED=1
systemctl mask --runtime "${SLEEP_UNITS[@]}"

notify_user "NVIDIA card detached successfully"
log "Setup completed successfully."
