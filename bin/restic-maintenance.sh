#!/usr/bin/env bash
# Daily maintenance: apply each share's own retention policy (forget),
# reclaim space once for the whole repository (prune), then an
# optional metadata-only check - forget/prune run every day, but check
# itself can be throttled to a specific day of the week
# (RESTIC_CHECK_DAY) since, unlike forget/prune, it grows with the
# repository's total size and can end up taking hours.
#
# Intended to run daily via restic-maintenance.service / .timer, after
# every restic-backup@<share>.service instance has had a chance to
# finish. This takes the lock in exclusive mode (see acquire_lock() in
# restic-common.sh), so it can never actually run at the same time as
# any of them - if one or more backups are still running (each holding
# the lock in shared mode) when this fires, acquire_lock's 0-second
# timeout means it doesn't wait around for them: it skips this run
# entirely rather than risk pruning while a backup is still writing
# pack files, and tries again at the next scheduled time.
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
# Scoped to --tag "${RESTIC_BACKUP_TAG:-scheduled}" (i.e. only the
# timer-triggered runs, never `restic-backup.sh --manual`): without
# this, an ad-hoc manual backup taken the same day as the scheduled one
# would win that day's --keep-daily slot (restic keeps only the latest
# snapshot per calendar day, regardless of tag), forgetting the actual
# scheduled backup early even though the policy's day-count wasn't
# reached yet. Manual snapshots are simply left alone by this automated
# retention - clean them up by hand with resticctl forget when you no
# longer need them.
#
# The "daily" number from retention-policies.conf is applied as
# --keep-within "${daily}d" rather than --keep-daily: a policy of e.g.
# 30 must mean "every scheduled snapshot from the last 30 days stays",
# a plain rolling time window - not restic's --keep-daily semantics of
# "keep the latest snapshot from each of the last 30 calendar days that
# has one", which would still collapse two scheduled runs landing on
# the same day (a timer catch-up after downtime, a DST-boundary day) to
# just one of them.
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

if ! acquire_lock 0 exclusive; then
    log_warn "could not acquire lock $RESTIC_LOCK_FILE (a backup is still running); skipping this maintenance run, will retry at the next scheduled time"
    log_info "===== restic maintenance skipped ====="
    notify maintenance skipped "restic maintenance on $(hostname -f 2>/dev/null || hostname) skipped: a backup was still running. Will retry at the next scheduled time."
    exit 0
fi
log_info "acquired lock $RESTIC_LOCK_FILE"

parse_shares_file
log_info "shares: ${SHARE_PATHS[*]}"

SCHEDULED_TAG="${RESTIC_BACKUP_TAG:-scheduled}"

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

    log_info "applying policy '$policy' to share '$share_name' ($path): keep-within=${daily}d weekly=$weekly monthly=$monthly yearly=$yearly (tag=$SCHEDULED_TAG only - manual backups are untouched)"

    # shellcheck disable=SC2054  # "host,paths" is one argument, the comma is intended
    FORGET_ARGS=(
        forget
        "${RESTIC_GLOBAL_ARGS[@]}"
        --tag "$SCHEDULED_TAG"
        --path "$path"
        --group-by host,paths
        --keep-within "${daily}d"
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
# RESTIC_CHECK_DAY ("Sun", "Mon", ... matching `date +%a`, or unset/empty
# for every day) throttles how often the check actually runs, separately
# from RESTIC_RUN_CHECK's on/off switch. check verifies every tree/blob
# in every snapshot, which (unlike forget/prune) grows with the
# repository's total size, not just what changed - confirmed on
# manny-01, where it grew from minutes to 4h30+ as the repository
# crossed a few hundred TB, blowing well past the margin before the
# 01:00 backup window and causing every backup that night to time out
# waiting for this exclusive lock. forget/prune still run every day
# (cheap, and retention needs to actually apply daily); only the much
# more expensive check is throttled.
TODAY="$(date +%a)"
if [[ "${RESTIC_RUN_CHECK:-true}" != "true" ]]; then
    log_info "RESTIC_RUN_CHECK is not true; skipping restic check"
elif [[ -n "${RESTIC_CHECK_DAY:-}" && "$RESTIC_CHECK_DAY" != "$TODAY" ]]; then
    log_info "RESTIC_CHECK_DAY=${RESTIC_CHECK_DAY}, today is ${TODAY}; skipping restic check until then"
else
    # The local metadata cache (RESTIC_CACHE_DIR) grows with the
    # repository and is never pruned automatically between runs -
    # confirmed on manny-01, where it reached 53G and, combined with
    # check's temporary download buffers, exhausted the filesystem
    # mid-check. That doesn't fail cleanly: restic's circuit breaker
    # trips on the resulting write errors and check reports hundreds of
    # "repository contains errors" lines that look like real data
    # corruption but aren't. Clearing stale cache entries first, and
    # refusing to even start if free space already looks tight, turns
    # that into one clear log line instead.
    log_info "running: restic cache --cleanup"
    restic cache --cleanup >>"$LOG_FILE" 2>&1 \
        || log_warn "restic cache --cleanup failed (non-fatal, continuing)"

    MIN_FREE_KB=$(( ${RESTIC_CHECK_MIN_FREE_GB:-20} * 1024 * 1024 ))
    FREE_KB="$(df -Pk "$RESTIC_CACHE_DIR" | awk 'NR==2 {print $4}')"
    if [[ "$FREE_KB" =~ ^[0-9]+$ ]] && (( FREE_KB < MIN_FREE_KB )); then
        log_error "only $((FREE_KB / 1024 / 1024))G free on the filesystem holding RESTIC_CACHE_DIR ($RESTIC_CACHE_DIR), below RESTIC_CHECK_MIN_FREE_GB=${RESTIC_CHECK_MIN_FREE_GB:-20}G - skipping restic check rather than risk a cache-exhaustion failure that reports as repository corruption. Free up space (or grow that filesystem) before the next scheduled check."
        CHECK_RC=1
    else
        # Metadata-only check: verifies the repository structure and
        # index consistency. Still reads some pack data (the tree blobs
        # embedded in data packs, needed to validate snapshot trees),
        # via RESTIC_CACHE_DIR - not a full --read-data pass, so it
        # does not touch every Glacier/tape-resident object, but it is
        # not literally zero local I/O either.
        CHECK_ARGS=(check "${RESTIC_GLOBAL_ARGS[@]}")
        log_info "running: restic ${CHECK_ARGS[*]}"
        restic "${CHECK_ARGS[@]}" >>"$LOG_FILE" 2>&1
        CHECK_RC=$?
        if [[ $CHECK_RC -eq 0 ]]; then
            log_info "restic check completed successfully"
        else
            log_error "restic check FAILED (exit $CHECK_RC)"
        fi
    fi
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
