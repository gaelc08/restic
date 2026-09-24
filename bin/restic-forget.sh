#!/usr/bin/env bash
# Safety-wrapped `restic forget` for manual/ad-hoc snapshot removal.
#
# Usage:
#   restic-forget.sh [--yes] [--no-prune] <snapshot-id> [<snapshot-id> ...]
#   restic-forget.sh [--yes] [--no-prune] --tag <tag> --keep-last N
#
# Any argument not consumed by this script's own --yes/--no-prune
# flags is passed straight through to `restic forget` - snapshot IDs,
# or restic's own filter/policy flags (--tag, --path, --host,
# --keep-*, --group-by, ...). See
# https://restic.readthedocs.io/en/latest/060_forget.html
#
# This is destructive and, once pruned, irreversible: forgotten
# snapshots' pack data is deleted from the Glacier/tape-backed
# repository. This script always shows what `restic forget` would do
# first (--dry-run) and asks for confirmation before actually running
# it; pass --yes to skip the prompt (required for non-interactive
# use - it refuses to proceed without a TTY unless --yes is given).
#
# By default also runs `restic prune --max-repack-size 0` afterward to
# actually reclaim space (same as restic-maintenance.sh; the
# --max-repack-size 0 is mandatory for the same reason - see
# docs/glacier-notes.md). Pass --no-prune to skip that and batch
# multiple forget runs before a single prune.

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/restic-common.sh"

LOG_FILE="${MAINTENANCE_LOG_FILE:-${LOG_DIR}/maintenance.log}"

ASSUME_YES=0
RUN_PRUNE=1
FORGET_ARGS=()

for arg in "$@"; do
    case "$arg" in
        --yes|-y)
            ASSUME_YES=1
            ;;
        --no-prune)
            RUN_PRUNE=0
            ;;
        *)
            FORGET_ARGS+=("$arg")
            ;;
    esac
done

if [[ ${#FORGET_ARGS[@]} -eq 0 ]]; then
    echo "Usage: $(basename "$0") [--yes] [--no-prune] <snapshot-id> [<snapshot-id> ...]" >&2
    echo "       $(basename "$0") [--yes] [--no-prune] <restic forget filter/policy flags>" >&2
    echo "Example: $(basename "$0") 35f79137 740bba99" >&2
    echo "Example: $(basename "$0") --tag share:test --keep-last 1" >&2
    exit 2
fi

log_info "===== restic forget (manual) starting: restic forget ${FORGET_ARGS[*]} ====="

echo "The following snapshots would be removed:"
restic forget "${RESTIC_GLOBAL_ARGS[@]}" --dry-run "${FORGET_ARGS[@]}"
dryrun_rc=$?
if [[ $dryrun_rc -ne 0 ]]; then
    log_error "restic forget --dry-run failed (exit $dryrun_rc); aborting, no changes made"
    exit $dryrun_rc
fi

if [[ $ASSUME_YES -ne 1 ]]; then
    if [[ ! -t 0 ]]; then
        log_error "not running interactively and --yes was not given; aborting without making changes"
        exit 1
    fi
    read -r -p "Proceed with forgetting the snapshot(s) above? [y/N] " reply
    case "$reply" in
        y|Y|yes|YES) ;;
        *)
            log_info "aborted by user, no changes made"
            exit 1
            ;;
    esac
fi

if ! acquire_lock "${RESTIC_BACKUP_LOCK_TIMEOUT:-300}"; then
    log_error "could not acquire lock $RESTIC_LOCK_FILE (backup or maintenance running?); aborting"
    exit 1
fi
log_info "acquired lock $RESTIC_LOCK_FILE"

restic forget "${RESTIC_GLOBAL_ARGS[@]}" "${FORGET_ARGS[@]}" 2>&1 | tee -a "$LOG_FILE"
forget_rc=${PIPESTATUS[0]}

if [[ $forget_rc -ne 0 ]]; then
    log_error "restic forget FAILED (exit $forget_rc)"
    exit "$forget_rc"
fi
log_info "restic forget completed successfully"

if [[ $RUN_PRUNE -eq 1 ]]; then
    # shellcheck disable=SC2206
    EXTRA_ARGS=(${RESTIC_MAINTENANCE_EXTRA_ARGS:---max-repack-size 0})
    log_info "running: restic prune ${RESTIC_GLOBAL_ARGS[*]} ${EXTRA_ARGS[*]}"
    restic prune "${RESTIC_GLOBAL_ARGS[@]}" "${EXTRA_ARGS[@]}" 2>&1 | tee -a "$LOG_FILE"
    prune_rc=${PIPESTATUS[0]}
    if [[ $prune_rc -ne 0 ]]; then
        log_error "restic prune FAILED (exit $prune_rc)"
        exit "$prune_rc"
    fi
    log_info "restic prune completed successfully"
else
    log_info "--no-prune given; space not yet reclaimed - run restic-forget.sh again (or 'restic prune --max-repack-size 0' directly) later to reclaim it"
fi

log_info "===== restic forget (manual) finished ====="
