#!/usr/bin/env bash
# Run a restic backup of all configured mounted shares against the
# S3 (Glacier) repository. Intended to be run by restic-backup.service
# (see systemd/restic-backup.service / .timer).
#
# Each share is backed up as its own `restic backup <path>` call, i.e.
# its own snapshot, tagged with the share's name and retention policy.
# This is required so restic-maintenance.sh can apply a different
# retention policy per share (restic forget/prune act on whole
# snapshots, not on sub-paths within one) - see restic-common.sh.
#
# Exit codes: 0 if every share backed up cleanly, 3 if every share
# succeeded but at least one completed with restic's own "some source
# files could not be read" warning (its exit code 3), 1 if any share
# failed outright. See
# https://restic.readthedocs.io/en/latest/040_backup.html#exit-status-codes

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/restic-common.sh"

LOG_FILE="${BACKUP_LOG_FILE:-${LOG_DIR}/backup.log}"

START_TS=$(date +%s)
log_info "===== restic backup starting (repo: ${RESTIC_REPOSITORY}) ====="

parse_shares_file
if ! check_shares_mounted; then
    log_error "===== restic backup aborted: invalid shares ====="
    exit 1
fi
log_info "shares: ${VALID_SHARE_PATHS[*]}"

RESTIC_BACKUP_LOCK_TIMEOUT="${RESTIC_BACKUP_LOCK_TIMEOUT:-300}"
if ! acquire_lock "$RESTIC_BACKUP_LOCK_TIMEOUT"; then
    log_error "===== restic backup aborted: could not acquire lock $RESTIC_LOCK_FILE within ${RESTIC_BACKUP_LOCK_TIMEOUT}s (maintenance running?) ====="
    exit 1
fi
log_info "acquired lock $RESTIC_LOCK_FILE"

FAILED=0
WARNED=0

for i in "${!VALID_SHARE_PATHS[@]}"; do
    path="${VALID_SHARE_PATHS[$i]}"
    policy="${VALID_SHARE_POLICIES[$i]}"
    share_name="$(basename "$path")"

    BACKUP_ARGS=(
        backup
        "${RESTIC_GLOBAL_ARGS[@]}"
        --read-concurrency "$RESTIC_READ_CONCURRENCY"
        --one-file-system
        --tag "${RESTIC_BACKUP_TAG:-scheduled}"
        --tag "share:${share_name}"
        --tag "policy:${policy}"
    )

    if [[ -n "${EXCLUDE_FILE:-}" && -r "${EXCLUDE_FILE:-}" ]]; then
        BACKUP_ARGS+=(--exclude-file "$EXCLUDE_FILE")
    fi

    if [[ "$RESTIC_JSON_LOG" == "true" ]]; then
        BACKUP_ARGS+=(--json)
    fi

    BACKUP_ARGS+=("$path")

    log_info "backing up share '$share_name' (policy=$policy): running restic ${BACKUP_ARGS[*]}"
    restic "${BACKUP_ARGS[@]}" >>"$LOG_FILE" 2>&1
    rc=$?

    if [[ $rc -eq 0 ]]; then
        log_info "share '$share_name' backup completed successfully"
    elif [[ $rc -eq 3 ]]; then
        log_warn "share '$share_name' backup completed with warnings (some source files could not be read, exit 3)"
        WARNED=1
    else
        log_error "share '$share_name' backup FAILED (exit $rc)"
        FAILED=1
    fi
done

END_TS=$(date +%s)
DURATION=$((END_TS - START_TS))

if [[ $FAILED -eq 1 ]]; then
    RC=1
    log_error "restic backup finished in ${DURATION}s with at least one failed share"
elif [[ $WARNED -eq 1 ]]; then
    RC=3
    log_warn "restic backup completed in ${DURATION}s; all shares backed up but at least one had warnings"
else
    RC=0
    log_info "restic backup completed successfully in ${DURATION}s"
fi

log_info "===== restic backup finished (exit $RC) ====="
exit $RC
