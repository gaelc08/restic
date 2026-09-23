#!/usr/bin/env bash
# Run a restic backup of all configured mounted shares against the
# S3 (Glacier) repository. Intended to be run by restic-backup.service
# (see systemd/restic-backup.service / .timer).
#
# Exit codes: restic's own (0 = ok, 3 = ok but some files could not be
# read, >0 = failure). See
# https://restic.readthedocs.io/en/latest/040_backup.html#exit-status-codes

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/restic-common.sh"

LOG_FILE="${BACKUP_LOG_FILE:-${LOG_DIR}/backup.log}"

START_TS=$(date +%s)
log_info "===== restic backup starting (repo: ${RESTIC_REPOSITORY}) ====="

if ! check_backup_paths; then
    log_error "===== restic backup aborted: invalid backup paths ====="
    exit 1
fi
log_info "backup paths: ${VALID_BACKUP_PATHS[*]}"

BACKUP_ARGS=(
    backup
    "${RESTIC_GLOBAL_ARGS[@]}"
    --read-concurrency "$RESTIC_READ_CONCURRENCY"
    --one-file-system
    --tag "${RESTIC_BACKUP_TAG:-scheduled}"
)

if [[ -n "${EXCLUDE_FILE:-}" && -r "${EXCLUDE_FILE:-}" ]]; then
    BACKUP_ARGS+=(--exclude-file "$EXCLUDE_FILE")
fi

if [[ "$RESTIC_JSON_LOG" == "true" ]]; then
    BACKUP_ARGS+=(--json)
fi

BACKUP_ARGS+=("${VALID_BACKUP_PATHS[@]}")

log_info "running: restic ${BACKUP_ARGS[*]}"
restic "${BACKUP_ARGS[@]}" >>"$LOG_FILE" 2>&1
RC=$?

END_TS=$(date +%s)
DURATION=$((END_TS - START_TS))

if [[ $RC -eq 0 ]]; then
    log_info "restic backup completed successfully in ${DURATION}s"
elif [[ $RC -eq 3 ]]; then
    log_warn "restic backup completed in ${DURATION}s with warnings (some source files could not be read, exit 3)"
else
    log_error "restic backup FAILED after ${DURATION}s (exit $RC)"
fi

log_info "===== restic backup finished (exit $RC) ====="
exit $RC
