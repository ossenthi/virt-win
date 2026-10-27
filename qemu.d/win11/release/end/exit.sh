#!/usr/bin/env bash

# Optional environment overrides:
#   FORCE=1                   continue even if /dev/vfio/* is still in use
#   RESTORE_WITHOUT_STATE=1   run with safe defaults if the state file is missing
set -uo pipefail

###############################################################################
# Configuration (keep VIRSH_*, STATE_FILE and LOCK_FILE identical in both scripts)
###############################################################################
VIRSH_GPU_VIDEO="pci_0000_01_00_0"     # overridden by values stored in the state file
VIRSH_GPU_AUDIO="pci_0000_01_00_1"

DESKTOP_USER="user"

STATE_FILE="/run/vm-gpu-passthrough.state"
LOCK_FILE="/run/vm-gpu-passthrough.lock"

ENABLE_LOGGING="${ENABLE_LOGGING:-1}"
LOG_DIR="${LOG_DIR:-/var/log/vm-gpu-passthrough}"
LOG_FILE="$LOG_DIR/restore.log"
LOG_MODE="${LOG_MODE:-0644}"                  # world-readable so a normal user can read it
LOG_MAX_BYTES=$((5 * 1024 * 1024))

NVIDIA_MODULES=(nvidia nvidia_modeset nvidia_drm nvidia_uvm)
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

on_exit() {
    local rc=$?
    trap - EXIT
    stop_logging
    exit "$rc"
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

###############################################################################
# Helpers
###############################################################################
FAILED=0

module_is_loaded() {
    awk -v m="$1" '$1 == m { found = 1 } END { exit !found }' /proc/modules
}

state_key() { printf '%s_%s' "$1" "${2//[^A-Za-z0-9]/_}"; }

# Hard step: a failure marks the restore incomplete (state file is kept for retry).
run() {
    "$@" || { echo "Restore command failed: $*" >&2; FAILED=1; }
}

# Soft step: used when the value came from a default rather than the state file.
run_soft() {
    "$@" || warn "Optional step failed (state value was assumed): $*"
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

###############################################################################
# State file loading - tolerant of missing, invalid and unknown entries
###############################################################################
declare -A STATE=()
STATE_PRESENT=0
STATE_COMPLETE=0

load_state() {
    local line key value
    [[ -r "$STATE_FILE" ]] || return 1
    STATE_PRESENT=1

    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        [[ -z "$line" || "$line" == \#* ]] && continue
        if [[ "$line" != *=* ]]; then
            warn "Ignoring malformed state line: $line"
            continue
        fi
        key="${line%%=*}"
        value="${line#*=}"
        if [[ ! "$key" =~ ^[A-Za-z][A-Za-z0-9_]*$ ]]; then
            warn "Ignoring state line with invalid key: $line"
            continue
        fi
        STATE["$key"]="$value"
    done < "$STATE_FILE"

    [[ "${STATE[END]:-}" == 1 ]] && STATE_COMPLETE=1
    return 0
}

# state_flag KEY DEFAULT -> sets REPLY to 0/1 (or DEFAULT) and LAST_DEFAULTED.
# Not used in $(...) so the LAST_DEFAULTED assignment survives.
LAST_DEFAULTED=0
state_flag() {
    local key="$1" default="$2" v
    LAST_DEFAULTED=0
    if [[ -v "STATE[$key]" ]]; then
        v="${STATE[$key]}"
        if [[ "$v" == 0 || "$v" == 1 ]]; then
            REPLY="$v"
            return 0
        fi
        warn "State value $key='$v' is invalid; assuming $default."
    else
        warn "State value $key is missing; assuming $default."
    fi
    LAST_DEFAULTED=1
    REPLY="$default"
}

# state_cpus KEY -> sets REPLY to a CPU list; empty means "all CPUs" (resets AllowedCPUs)
state_cpus() {
    local key="$1" v
    LAST_DEFAULTED=0
    if [[ -v "STATE[$key]" ]]; then
        v="${STATE[$key]}"
        if [[ "$v" =~ ^[0-9]*([,-][0-9]+)*$ ]]; then
            REPLY="$v"
            return 0
        fi
        warn "State value $key='$v' is invalid; allowing all CPUs."
    else
        warn "State value $key is missing; allowing all CPUs."
    fi
    LAST_DEFAULTED=1
    REPLY=""
}

###############################################################################
# PCI helpers
###############################################################################
node_to_bdf() {
    local node="$1" prefix domain bus slot fn
    [[ "$node" =~ ^pci_[0-9a-f]{4}_[0-9a-f]{2}_[0-9a-f]{2}_[0-7]$ ]] || return 1
    IFS=_ read -r prefix domain bus slot fn <<< "$node"
    printf '%s:%s:%s.%s\n' "$domain" "$bus" "$slot" "$fn"
}

current_driver() {
    local link="/sys/bus/pci/devices/$1/driver"
    if [[ -L "$link" ]]; then basename "$(readlink -f "$link")"; else echo "none"; fi
}

reattach_if_needed() {
    local node="$1" bdf driver
    bdf="$(node_to_bdf "$node")" || { echo "Invalid PCI node name: $node" >&2; FAILED=1; return 1; }

    if [[ ! -d "/sys/bus/pci/devices/$bdf" ]]; then
        echo "PCI device $bdf not found in sysfs." >&2
        FAILED=1
        return 1
    fi

    driver="$(current_driver "$bdf")"
    if [[ "$driver" != vfio* && "$driver" != none ]]; then
        log "$bdf already bound to $driver."
        return 0
    fi

    run virsh nodedev-reattach "$node"
    log "$bdf is now bound to: $(current_driver "$bdf")"
}

###############################################################################
# Start
###############################################################################
if (( EUID != 0 )); then
    echo "Run this script as root." >&2
    exit 1
fi

setup_logging

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    echo "Another setup/restore is already running." >&2
    exit 1
fi

if ! load_state; then
    if [[ "${RESTORE_WITHOUT_STATE:-0}" == "1" ]]; then
        warn "State file not found; restoring with safe defaults."
    else
        echo "Restore state file not found: $STATE_FILE" >&2
        echo "There is no saved setup state to restore." >&2
        echo "Set RESTORE_WITHOUT_STATE=1 to restore using safe defaults anyway." >&2
        exit 1
    fi
elif (( ! STATE_COMPLETE )); then
    warn "State file has no END marker (possibly truncated); missing values will use defaults."
fi

if [[ -v "STATE[VERSION]" && "${STATE[VERSION]}" != 2 ]]; then
    warn "Unexpected state file version '${STATE[VERSION]}'; trying best-effort restore."
fi

# Prefer the GPU nodes recorded at setup time over the hard-coded configuration.
for pair in "GPU_VIDEO:VIRSH_GPU_VIDEO" "GPU_AUDIO:VIRSH_GPU_AUDIO"; do
    skey="${pair%%:*}"; var="${pair##*:}"
    if [[ -n "${STATE[$skey]:-}" ]]; then
        if node_to_bdf "${STATE[$skey]}" >/dev/null; then
            printf -v "$var" '%s' "${STATE[$skey]}"
        else
            warn "State value $skey='${STATE[$skey]}' is invalid; using configured $var."
        fi
    fi
done

# Do not tear things down underneath a running VM.
shopt -s nullglob
VFIO_NODES=(/dev/vfio/[0-9]*)
shopt -u nullglob
if ((${#VFIO_NODES[@]})) && fuser -s "${VFIO_NODES[@]}" 2>/dev/null; then
    if [[ "${FORCE:-0}" == "1" ]]; then
        warn "VFIO devices are still in use; continuing because FORCE=1."
    else
        echo "VFIO devices are still in use (is the VM still running?). Refusing to restore." >&2
        echo "Stop the VM first, or re-run with FORCE=1." >&2
        fuser -v "${VFIO_NODES[@]}" >&2 2>&1 || true
        exit 1
    fi
fi

###############################################################################
# Restore (order: NVIDIA modules -> reattach -> VFIO modules -> rest)
###############################################################################

# 1. Remove VFIO modules that setup loaded (missing value => assume loaded, leave alone).
for module in "${VFIO_UNLOAD_ORDER[@]}"; do
    state_flag "$(state_key VFIO "$module")" 1
    flag="$REPLY"
    if [[ "$flag" == 0 ]] && module_is_loaded "$module"; then
        log "Unloading $module"
        run modprobe -r "$module"
    fi
done

# 2. Reload NVIDIA modules first so the host driver is available for reattach.
for module in "${NVIDIA_MODULES[@]}"; do
    state_flag "$(state_key NVIDIA "$module")" 1
    flag="$REPLY"; defaulted=$LAST_DEFAULTED
    if [[ "$flag" == 1 ]] && ! module_is_loaded "$module"; then
        log "Loading $module"
        if (( defaulted )); then run_soft modprobe "$module"; else run modprobe "$module"; fi
    fi
done

# 3. Reattach the video and audio functions.
    reattach_if_needed "$VIRSH_GPU_VIDEO"
    reattach_if_needed "$VIRSH_GPU_AUDIO"


# 4. Hugepages (missing/invalid => release them: 0).
saved_hp="${STATE[HUGEPAGES]:-}"
if [[ ! "$saved_hp" =~ ^[0-9]+$ ]]; then
    warn "Saved hugepage count is missing or invalid; releasing hugepages (0)."
    saved_hp=0
fi
log "Restoring nr_hugepages to $saved_hp"
if ! printf '%s\n' "$saved_hp" > /proc/sys/vm/nr_hugepages; then
    echo "Could not restore the original hugepage count." >&2
    FAILED=1
else
    cur_hp="$(cat /proc/sys/vm/nr_hugepages)"
    if (( cur_hp != saved_hp )); then
        warn "nr_hugepages is $cur_hp (wanted $saved_hp); some pages are probably still in use."
    fi
fi

# 5. CPU limits (missing => empty value, which lifts the restriction).
for unit in "${CPU_UNITS[@]}"; do
    state_cpus "$(state_key CPU "$unit")"
    cpus="$REPLY"
    run systemctl set-property --runtime "$unit" "AllowedCPUs=$cpus"
done

# 6. Remove only the runtime sleep masks that setup added (missing => assume setup added it).
for unit in "${SLEEP_UNITS[@]}"; do
    state_flag "$(state_key SLEEPMASKED "$unit")" 0
    flag="$REPLY"
    if [[ "$flag" == 0 ]]; then
        run systemctl unmask --runtime "$unit"
    fi
done

sleep 1

# 7. nvidia-powerd: restore if known, otherwise leave it alone.
if [[ -v "STATE[POWERD_ACTIVE]" && ( "${STATE[POWERD_ACTIVE]}" == 0 || "${STATE[POWERD_ACTIVE]}" == 1 ) ]]; then
    if [[ "${STATE[POWERD_ACTIVE]}" == 1 ]]; then
        run systemctl start nvidia-powerd.service
    else
        run systemctl stop nvidia-powerd.service
    fi
else
    warn "POWERD_ACTIVE is missing or invalid; leaving nvidia-powerd.service unchanged."
fi

###############################################################################
# Finish
###############################################################################
if (( FAILED )); then
    echo "Restore was incomplete. State file kept so you can retry: $STATE_FILE" >&2
    exit 1
fi

(( STATE_PRESENT )) && rm -f -- "$STATE_FILE"

notify_user "VM stopped; host restored"
log "Restore completed successfully."
