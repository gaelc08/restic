#!/usr/bin/env bash
# Daily maintenance: apply each share's own retention policy (forget),
# reclaim space once for the whole repository (prune), then an
# optional metadata-only check.
#
# Intended to run daily via restic-maintenance.service / .timer, after
# restic-backup.sh - though the two can never actually run at the same
# time, see acquire_lock() in restic-common.sh.
#
# Retention is per share: SHARES_FILE names a retention policy per
# share, RETENTION_POLICIES_FILE defines each policy's keep-daily/
# weekly/monthly/yearly numbers (Cohesity-style short/mid/long tiers,
# or any other names you choose). `restic forget --path <share>` is
# run once per share with that share's own numbers - forget/prune
# operate on whole snapshots, and each share has owned its own
# snapshots since restic-backup.sh backs it up separately, so this is
# the only way to keep, say, a "long" retention share's history intact
# while a "short" retention share's older snapshots are forgotten.
#
# IMPORTANT: --max-repack-size 0 is always passed to the single, final
# prune. The repository's data lives behind S3 Glacier / tape. Without
# this flag, `restic prune` may try to repack (rewrite) pack files
# that are only partially referenced, which requires reading their old
# data back from Glacier/tape - slow, and can trigger retrieval costs
# or tape mounts. With --max-repack-size 0, prune only ever removes
# pack files that are 100% unreferenced (a pure delete, no re-read of
# archived data), and never repacks. See docs/glacier-notes.md.

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
    notify maintenance skipped "restic maintenance on $(hostname -f 2>/dev/null || hostname) skipped: a backup was still running. Will retry at the next scheduled time."
    exit 0
fi
log_info "acquired lock $RESTIC_LOCK_FILE"

parse_shares_file
log_info "shares: ${SHARE_PATHS[*]}"

FORGET_FAILED=0
FORGET_FAILED_SHARES=()

for i in "${!SHARE_PATHS[@]}"; do
    path="${SHARE_PATHS[$i]}"
    policy="${SHARE_POLICIES[$i]}"
    share_name="$(basename "$path")"
    daily="${POLICY_KEEP_DAILY[$policy]}"
    weekly="${POLICY_KEEP_WEEKLY[$policy]}"
    monthly="${POLICY_KEEP_MONTHLY[$policy]}"
    yearly="${POLICY_KEEP_YEARLY[$policy]}"

    log_info "applying policy '$policy' to share '$share_name' ($path): daily=$daily weekly=$weekly monthly=$monthly yearly=$yearly"

    # shellcheck disable=SC2054  # "host,paths" is one argument, the comma is intended
    FORGET_ARGS=(
        forget
        "${RESTIC_GLOBAL_ARGS[@]}"
        --path "$path"
        --group-by host,paths
        --keep-daily "$daily"
        --keep-weekly "$weekly"
        --keep-monthly "$monthly"
        --keep-yearly "$yearly"
    )

    log_info "running: restic ${FORGET_ARGS[*]}"
    restic "${FORGET_ARGS[@]}" >>"$LOG_FILE" 2>&1
    rc=$?

    if [[ $rc -eq 0 ]]; then
        log_info "share '$share_name' forget completed successfully"
    else
        log_error "share '$share_name' forget FAILED (exit $rc)"
        FORGET_FAILED=1
        FORGET_FAILED_SHARES+=("$share_name")
    fi
done

# shellcheck disable=SC2206
EXTRA_ARGS=(${RESTIC_MAINTENANCE_EXTRA_ARGS:---max-repack-size 0})

PRUNE_ARGS=(
    prune
    "${RESTIC_GLOBAL_ARGS[@]}"
    "${EXTRA_ARGS[@]}"
)

log_info "running: restic ${PRUNE_ARGS[*]}"
restic "${PRUNE_ARGS[@]}" >>"$LOG_FILE" 2>&1
PRUNE_RC=$?

if [[ $PRUNE_RC -eq 0 ]]; then
    log_info "prune completed successfully"
else
    log_error "prune FAILED (exit $PRUNE_RC)"
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
log_info "===== restic maintenance finished in ${DURATION}s (forget failed=$FORGET_FAILED, prune exit $PRUNE_RC, check exit $CHECK_RC) ====="

host="$(hostname -f 2>/dev/null || hostname)"
if [[ $FORGET_FAILED -eq 1 || $PRUNE_RC -ne 0 || $CHECK_RC -ne 0 ]]; then
    FAIL_PARTS=()
    [[ $FORGET_FAILED -eq 1 ]] && FAIL_PARTS+=("forget failed for share(s): ${FORGET_FAILED_SHARES[*]}")
    [[ $PRUNE_RC -ne 0 ]] && FAIL_PARTS+=("prune failed (exit $PRUNE_RC)")
    [[ $CHECK_RC -ne 0 ]] && FAIL_PARTS+=("check failed (exit $CHECK_RC)")
    IFS='; '; FAIL_SUMMARY="${FAIL_PARTS[*]}"; unset IFS
    notify maintenance failure "restic maintenance on ${host} FAILED after ${DURATION}s: ${FAIL_SUMMARY}. See ${LOG_FILE}."
    exit 1
fi
notify maintenance success "restic maintenance on ${host} completed successfully in ${DURATION}s (${#SHARE_PATHS[@]} share(s))."
exit 0
