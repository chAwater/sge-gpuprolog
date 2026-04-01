#!/bin/bash
#
# reserve-gpu.sh — Manually reserve/release GPU devices.
#
# Problem:
#   Manually creating lock directories without updating SGE resource counts
#   causes prolog.sh to fail (cannot acquire enough GPUs). This script keeps
#   lock files and SGE gpu resource values in sync.
#
# How it works:
#   - lock:   Creates /tmp/lock-gpu<id> on the target host (same lock used by
#             prolog.sh), then decrements the SGE gpu resource via qconf.
#   - unlock: Removes the lock directory on the target host, then increments
#             the SGE gpu resource.
#   - status: Scans all GPUs on the target host for lock state and compares
#             with SGE resource count. Warns if they are out of sync.
#
# Prerequisites:
#   - qconf privileges (SGE manager or operator)
#   - nvidia-smi available on the target host
#   - SSH key-based auth for remote hosts (no password prompt)
#   - Lock path /tmp/lock-gpu<id> must match prolog.sh and epilog.sh
#
# Usage:
#   reserve-gpu.sh lock   <gpu_id> [hostname]   Reserve a GPU
#   reserve-gpu.sh unlock <gpu_id> [hostname]   Release a GPU
#   reserve-gpu.sh status [hostname]            Show GPU status
#
# Examples:
#   reserve-gpu.sh lock 2              # Reserve GPU 2 on this host
#   reserve-gpu.sh lock 0 node01       # Reserve GPU 0 on node01 (via SSH)
#   reserve-gpu.sh unlock 2            # Release GPU 2 on this host
#   reserve-gpu.sh status              # Show status for this host
#   reserve-gpu.sh status node01       # Show status for node01 (via SSH)
#

ACTION=$1
LOCAL_HOST=$(hostname)

# Lock directory prefix — must match prolog.sh and epilog.sh
LOCK_PREFIX="/tmp/lock-gpu"

# Parse positional args: status uses $2 as hostname, lock/unlock uses $2 as gpu_id.
if [ "$ACTION" = "status" ]; then
  GPU_ID=""
  HOST=${2:-$LOCAL_HOST}
else
  GPU_ID=$2
  HOST=${3:-$LOCAL_HOST}
fi

usage() {
  echo "Usage:"
  echo "  $0 lock   <gpu_id> [hostname]  - Reserve a GPU and decrement SGE resource"
  echo "  $0 unlock <gpu_id> [hostname]  - Release a GPU and increment SGE resource"
  echo "  $0 status [hostname]           - Show GPU lock and SGE resource status"
  exit 1
}

# Run a command on the target host.
# Local: runs directly.  Remote: runs via SSH.
run_on_host() {
  if [ "$HOST" = "$LOCAL_HOST" ]; then
    sh -c "$1"
  else
    ssh -o BatchMode=yes -o ConnectTimeout=5 "$HOST" "$1"
  fi
}

# Read current SGE gpu resource value for a host.
# Runs locally (qconf talks to qmaster directly).
get_sge_gpu() {
  qconf -se "$1" 2>/dev/null | sed -n 's/.*gpu=\([0-9]*\).*/\1/p'
}

# Update SGE gpu resource value for a host.
# Runs locally (qconf talks to qmaster directly).
set_sge_gpu() {
  qconf -mattr exechost complex_values "gpu=$2" "$1"
}

# Get total physical GPU count on the target host.
get_total_gpus() {
  run_on_host "nvidia-smi -L 2>/dev/null | wc -l | tr -d ' \r'"
}

# Validate that gpu_id is a non-negative integer.
validate_gpu_id() {
  case "$1" in
    ''|*[!0-9]*) echo "ERROR: gpu_id must be a non-negative integer, got '$1'"; exit 1 ;;
  esac
}

# Verify that gpu_id exists on the target host (within range).
check_gpu_exists() {
  local total
  total=$(get_total_gpus)
  if [ -z "$total" ] || [ "$total" -eq 0 ]; then
    echo "ERROR: Cannot query GPUs on $HOST (nvidia-smi failed or SSH unreachable)"
    exit 1
  fi
  if [ "$1" -ge "$total" ]; then
    echo "ERROR: GPU $1 does not exist ($HOST has $total GPUs: 0-$((total - 1)))"
    exit 1
  fi
}

# Verify SSH connectivity for remote hosts.
check_remote_access() {
  if [ "$HOST" != "$LOCAL_HOST" ]; then
    if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "$HOST" "true" 2>/dev/null; then
      echo "ERROR: Cannot SSH to $HOST (check key-based auth and connectivity)"
      exit 1
    fi
  fi
}

case "$ACTION" in
  lock)
    if [ -z "$GPU_ID" ]; then usage; fi
    validate_gpu_id "$GPU_ID"
    check_remote_access
    check_gpu_exists "$GPU_ID"

    # Step 1: Create lock directory on target host (atomic via mkdir)
    if ! run_on_host "mkdir '${LOCK_PREFIX}${GPU_ID}' 2>/dev/null"; then
      echo "ERROR: GPU $GPU_ID is already locked on $HOST"
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
      # Rollback: remove lock directory on target host
      echo "ERROR: Failed to update SGE resource, rolling back lock"
      run_on_host "rmdir '${LOCK_PREFIX}${GPU_ID}'" 2>/dev/null
      exit 1
    fi
    ;;

  unlock)
    if [ -z "$GPU_ID" ]; then usage; fi
    validate_gpu_id "$GPU_ID"
    check_remote_access

    # Step 1: Remove lock directory on target host
    if ! run_on_host "rmdir '${LOCK_PREFIX}${GPU_ID}' 2>/dev/null"; then
      echo "ERROR: GPU $GPU_ID is not locked on $HOST"
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
    check_remote_access
    total=$(get_total_gpus)
    sge_gpu=$(get_sge_gpu "$HOST")

    if [ -z "$total" ] || [ "$total" -eq 0 ]; then
      echo "ERROR: Cannot query GPUs on $HOST"
      exit 1
    fi

    echo "Host: $HOST"
    echo "Physical GPUs: $total"
    echo "SGE gpu resource: ${sge_gpu:-N/A}"
    echo ""
    echo "Lock status:"

    # Query all lock directories in a single remote call
    locked_ids=$(run_on_host "for id in \$(seq 0 $((total - 1))); do [ -d '${LOCK_PREFIX}'\$id ] && echo \$id; done")

    locked=0
    id=0
    while [ "$id" -lt "$total" ]; do
      if echo "$locked_ids" | grep -qx "$id"; then
        echo "  GPU $id: LOCKED"
        locked=$((locked + 1))
      else
        echo "  GPU $id: available"
      fi
      id=$((id + 1))
    done

    echo ""

    # Derive manual vs SGE job locks from existing data:
    #   manual_locks = total - sge_gpu  (reserve-gpu.sh decrements sge_gpu on each lock)
    #   sge_job_locks = locked - manual_locks
    # If either is negative, state is inconsistent.
    if [ -n "$sge_gpu" ]; then
      manual_locks=$((total - sge_gpu))
      sge_job_locks=$((locked - manual_locks))

      echo "Summary: $locked locked ($manual_locks manual, $sge_job_locks SGE jobs), $((total - locked)) available"

      if [ "$manual_locks" -lt 0 ]; then
        echo "WARNING: SGE gpu resource ($sge_gpu) exceeds physical GPUs ($total)"
      elif [ "$sge_job_locks" -lt 0 ]; then
        echo "WARNING: SGE gpu resource ($sge_gpu) too low — expected $manual_locks manual locks but only $locked total locks on disk"
      fi
    else
      echo "Summary: $locked locked, $((total - locked)) available (SGE resource unavailable)"
    fi
    ;;

  *)
    usage
    ;;
esac
