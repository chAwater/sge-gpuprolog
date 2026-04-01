#!/bin/sh
#
# reserve-gpu.sh — Manually reserve/release GPU devices.
#
# Problem:
#   Manually creating lock directories without updating SGE resource counts
#   causes prolog.sh to fail (cannot acquire enough GPUs). This script keeps
#   lock files and SGE gpu resource values in sync.
#
# How it works:
#   - lock:   Creates /tmp/lock-gpu<id> (same lock used by prolog.sh),
#             then decrements the SGE gpu resource for the host via qconf.
#   - unlock: Removes the lock directory, then increments the SGE gpu resource.
#   - status: Scans all GPUs for lock state and compares with SGE resource count.
#             Warns if they are out of sync.
#
# Prerequisites:
#   - qconf privileges (SGE manager or operator)
#   - nvidia-smi available on the host
#   - Lock path /tmp/lock-gpu<id> must match prolog.sh and epilog.sh
#
# Usage:
#   reserve-gpu.sh lock   <gpu_id> [hostname]   Reserve a GPU
#   reserve-gpu.sh unlock <gpu_id> [hostname]   Release a GPU
#   reserve-gpu.sh status [hostname]            Show GPU status
#
# Examples:
#   reserve-gpu.sh lock 2              # Reserve GPU 2 on this host
#   reserve-gpu.sh lock 0 node01       # Reserve GPU 0 on node01
#   reserve-gpu.sh unlock 2            # Release GPU 2 on this host
#   reserve-gpu.sh status              # Show status for this host
#   reserve-gpu.sh status node01       # Show status for node01
#

ACTION=$1
GPU_ID=$2
HOST=${3:-$(hostname)}

# Lock directory prefix — must match prolog.sh and epilog.sh
LOCK_PREFIX="/tmp/lock-gpu"

usage() {
  echo "Usage:"
  echo "  $0 lock   <gpu_id> [hostname]  - Reserve a GPU and decrement SGE resource"
  echo "  $0 unlock <gpu_id> [hostname]  - Release a GPU and increment SGE resource"
  echo "  $0 status [hostname]           - Show GPU lock and SGE resource status"
  exit 1
}

# Read current SGE gpu resource value for a host.
# Args: $1 = hostname
get_sge_gpu() {
  qconf -se "$1" 2>/dev/null | sed -n 's/.*gpu=\([0-9]*\).*/\1/p'
}

# Update SGE gpu resource value for a host.
# Args: $1 = hostname, $2 = new value
set_sge_gpu() {
  local host=$1
  local value=$2
  qconf -mattr exechost complex_values "gpu=$value" "$host"
}

# Get total physical GPU count via nvidia-smi.
get_total_gpus() {
  nvidia-smi -L 2>/dev/null | wc -l | tr -d ' '
}

# Validate that gpu_id is a non-negative integer.
# Args: $1 = gpu_id
validate_gpu_id() {
  case "$1" in
    ''|*[!0-9]*) echo "ERROR: gpu_id must be a non-negative integer, got '$1'"; exit 1 ;;
  esac
}

# Verify that gpu_id exists on this host (within range).
# Args: $1 = gpu_id
check_gpu_exists() {
  local total
  total=$(get_total_gpus)
  if [ "$1" -ge "$total" ]; then
    echo "ERROR: GPU $1 does not exist (this host has $total GPUs: 0-$((total - 1)))"
    exit 1
  fi
}

case "$ACTION" in
  lock)
    if [ -z "$GPU_ID" ]; then usage; fi
    validate_gpu_id "$GPU_ID"
    check_gpu_exists "$GPU_ID"

    # Step 1: Create lock directory (atomic via mkdir, same as prolog.sh)
    lockfile="${LOCK_PREFIX}${GPU_ID}"
    if ! mkdir "$lockfile" 2>/dev/null; then
      echo "ERROR: GPU $GPU_ID is already locked ($lockfile exists)"
      exit 1
    fi

    # Step 2: Decrement SGE gpu resource so scheduler stops counting this GPU
    current=$(get_sge_gpu "$HOST")
    if [ -z "$current" ]; then
      echo "WARNING: Cannot read SGE gpu resource for $HOST, lock file created but SGE not updated"
      echo "  Locked: GPU $GPU_ID"
      exit 1
    fi

    if [ "$current" -le 0 ]; then
      echo "WARNING: SGE gpu resource is already 0, lock file created but SGE not decremented"
      echo "  Locked: GPU $GPU_ID"
      exit 0
    fi

    new_val=$((current - 1))
    if set_sge_gpu "$HOST" "$new_val"; then
      echo "Locked GPU $GPU_ID on $HOST (SGE gpu: $current -> $new_val)"
    else
      # Rollback: remove lock directory to avoid inconsistent state
      echo "ERROR: Failed to update SGE resource, rolling back lock"
      rmdir "$lockfile"
      exit 1
    fi
    ;;

  unlock)
    if [ -z "$GPU_ID" ]; then usage; fi
    validate_gpu_id "$GPU_ID"

    # Step 1: Remove lock directory
    lockfile="${LOCK_PREFIX}${GPU_ID}"
    if ! rmdir "$lockfile" 2>/dev/null; then
      echo "ERROR: GPU $GPU_ID is not locked ($lockfile does not exist)"
      exit 1
    fi

    # Step 2: Increment SGE gpu resource
    current=$(get_sge_gpu "$HOST")
    if [ -z "$current" ]; then
      echo "WARNING: Cannot read SGE gpu resource for $HOST, lock file removed but SGE not updated"
      echo "  Unlocked: GPU $GPU_ID"
      exit 1
    fi

    # Guard: do not exceed total physical GPU count
    total=$(get_total_gpus)
    if [ "$current" -ge "$total" ]; then
      echo "WARNING: SGE gpu resource ($current) already >= total GPUs ($total), lock removed but SGE not incremented"
      echo "  Unlocked: GPU $GPU_ID"
      exit 0
    fi

    new_val=$((current + 1))
    if set_sge_gpu "$HOST" "$new_val"; then
      echo "Unlocked GPU $GPU_ID on $HOST (SGE gpu: $current -> $new_val)"
    else
      # Lock already removed — cannot rollback, prompt manual fix
      echo "WARNING: Lock removed but failed to update SGE resource"
      echo "  Unlocked: GPU $GPU_ID, please manually run: qconf -mattr exechost complex_values gpu=$new_val $HOST"
      exit 1
    fi
    ;;

  status)
    # For status, hostname is the 2nd positional arg (where gpu_id normally goes)
    HOST=${GPU_ID:-$HOST}
    total=$(get_total_gpus)
    sge_gpu=$(get_sge_gpu "$HOST")

    echo "Host: $HOST"
    echo "Physical GPUs: $total"
    echo "SGE gpu resource: ${sge_gpu:-N/A}"
    echo ""
    echo "Lock status:"

    locked=0
    id=0
    while [ "$id" -lt "$total" ]; do
      lockfile="${LOCK_PREFIX}${id}"
      if [ -d "$lockfile" ]; then
        echo "  GPU $id: LOCKED"
        locked=$((locked + 1))
      else
        echo "  GPU $id: available"
      fi
      id=$((id + 1))
    done

    echo ""
    echo "Summary: $locked locked, $((total - locked)) available"

    # Warn if SGE resource count does not match actual available GPUs
    if [ -n "$sge_gpu" ] && [ "$sge_gpu" -ne $((total - locked)) ]; then
      echo "WARNING: SGE resource ($sge_gpu) does not match available GPUs ($((total - locked)))"
    fi
    ;;

  *)
    usage
    ;;
esac
