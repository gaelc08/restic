#!/usr/bin/env bash
# Daily maintenance: apply the retention policy (forget) and reclaim
# space (prune), then an optional metadata-only check.
#
# Intended to run daily, after restic-backup.sh, via
# restic-maintenance.service / .timer.
#
# IMPORTANT: --max-repack-size 0 is always passed to prune. The
# repository's data lives behind S3 Glacier / tape. Without this flag,
# `restic prune` may try to repack (rewrite) pack files that are only
# partially referenced, which requires reading their old data back
# from Glacier/tape - slow, and can trigger retrieval costs or tape
# mounts. With --max-repack-size 0, prune only ever removes pack files
# that are 100% unreferenced (a pure delete, no read of archived
# data), and never repacks. See docs/glacier-notes.md.

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/restic-common.sh"

LOG_FILE="${MAINTENANCE_LOG_FILE:-${LOG_DIR}/maintenance.log}"

START_TS=$(date +%s)
log_info "===== restic maintenance starting (repo: ${RESTIC_REPOSITORY}) ====="

if ! acquire_lock 0; then
    log_warn "could not acquire lock $RESTIC_LOCK_FILE (a backup is still running); skipping this maintenance run, will retry at the next scheduled time"
    log_info "===== restic maintenance skipped ====="
    exit 0
fi
log_info "acquired lock $RESTIC_LOCK_FILE"

: "${RESTIC_KEEP_DAILY:=30}"
: "${RESTIC_KEEP_WEEKLY:=12}"
: "${RESTIC_KEEP_MONTHLY:=12}"
: "${RESTIC_KEEP_YEARLY:=7}"

log_info "retention policy (Cohesity-style short/mid/long): daily=${RESTIC_KEEP_DAILY} weekly=${RESTIC_KEEP_WEEKLY} monthly=${RESTIC_KEEP_MONTHLY} yearly=${RESTIC_KEEP_YEARLY}"

# shellcheck disable=SC2206
EXTRA_ARGS=(${RESTIC_MAINTENANCE_EXTRA_ARGS:---max-repack-size 0})

FORGET_ARGS=(
    forget
    "${RESTIC_GLOBAL_ARGS[@]}"
    --group-by host,paths
    --keep-daily "$RESTIC_KEEP_DAILY"
    --keep-weekly "$RESTIC_KEEP_WEEKLY"
    --keep-monthly "$RESTIC_KEEP_MONTHLY"
    --keep-yearly "$RESTIC_KEEP_YEARLY"
    --prune
    "${EXTRA_ARGS[@]}"
)

log_info "running: restic ${FORGET_ARGS[*]}"
restic "${FORGET_ARGS[@]}" >>"$LOG_FILE" 2>&1
FORGET_RC=$?

if [[ $FORGET_RC -eq 0 ]]; then
    log_info "forget --prune completed successfully"
else
    log_error "forget --prune FAILED (exit $FORGET_RC)"
fi

CHECK_RC=0
if [[ "${RESTIC_RUN_CHECK:-true}" == "true" ]]; then
    # Metadata-only check: verifies the repository structure and index
    # consistency without downloading pack data, so it does not touch
    # Glacier/tape-resident objects.
    CHECK_ARGS=(check "${RESTIC_GLOBAL_ARGS[@]}")
    log_info "running: restic ${CHECK_ARGS[*]}"
    restic "${CHECK_ARGS[@]}" >>"$LOG_FILE" 2>&1
    CHECK_RC=$?
    if [[ $CHECK_RC -eq 0 ]]; then
        log_info "restic check completed successfully"
    else
        log_error "restic check FAILED (exit $CHECK_RC)"
    fi
else
    log_info "RESTIC_RUN_CHECK is not true; skipping restic check"
fi

END_TS=$(date +%s)
DURATION=$((END_TS - START_TS))
log_info "===== restic maintenance finished in ${DURATION}s (forget/prune exit $FORGET_RC, check exit $CHECK_RC) ====="

if [[ $FORGET_RC -ne 0 || $CHECK_RC -ne 0 ]]; then
    exit 1
fi
exit 0
