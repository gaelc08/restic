#!/usr/bin/env bash
# Starts one restic-backup@<share>.service instance per share
# currently in shares.conf, with --no-block, then exits - it does not
# wait for any of them to finish.
#
# This is the ExecStart of restic-backup.service (the daily timer-
# driven entry point) and also what `resticctl backup-all` runs for an
# ad-hoc "right now" trigger. Both read shares.conf fresh every time
# they run, so a newly added share is picked up automatically on the
# very next run - no separate per-share enable step.
#
# Why a dispatcher instead of one static restic-backup@.timer instance
# per share: that was tried first and worked, but needed an explicit
# `resticctl enable-backups` (or manual `systemctl enable`) run every
# time a share was added - annoying to remember, and easy to silently
# miss. This dispatcher is deliberately trivial and fast (it only
# *starts* jobs, via --no-block, never waits on them), so it finishes
# in a couple seconds regardless of how long any individual share's
# backup takes - meaning restic-backup.service is never still "active"
# at the next day's scheduled start, which is the exact failure mode
# (one slow share silently blocking every other share's backup) that
# the per-share restic-backup@.service units were introduced to fix in
# the first place. A share's actual backup outcome is tracked the
# normal way regardless of how it was started: its own
# restic-backup@<share>.service unit/journal entry,
# /var/log/restic/backup.log, and the per-share row in the next
# restic-report.sh digest - this script only logs whether each job was
# successfully *queued*, not how the backup itself turned out.

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/restic-common.sh"

LOG_FILE="${BACKUP_LOG_FILE:-${LOG_DIR}/backup.log}"

log_info "===== restic backup dispatch starting ====="

parse_shares_file
log_info "shares: ${SHARE_PATHS[*]}"

FAILED=0
FAILED_SHARES=()

for path in "${SHARE_PATHS[@]}"; do
    name="$(basename "$path")"
    log_info "starting restic-backup@${name}.service"
    if systemctl start --no-block "restic-backup@${name}.service" >>"$LOG_FILE" 2>&1; then
        log_info "restic-backup@${name}.service queued"
    else
        log_error "failed to queue restic-backup@${name}.service"
        FAILED=1
        FAILED_SHARES+=("$name")
    fi
done

host="$(hostname -f 2>/dev/null || hostname)"
if [[ $FAILED -eq 1 ]]; then
    log_error "===== restic backup dispatch finished: failed to queue share(s): ${FAILED_SHARES[*]} ====="
    notify backup failure "restic backup dispatch on ${host} FAILED to queue share(s): ${FAILED_SHARES[*]} - they were never started. See ${LOG_FILE}."
    exit 1
fi

log_info "===== restic backup dispatch finished: queued ${#SHARE_PATHS[@]} share(s) ====="
exit 0
