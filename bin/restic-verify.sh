#!/usr/bin/env bash
# Restore verification: proves each share's backups are actually
# readable/restorable, not just "present" - `restic check` alone only
# validates metadata, never the archived pack data itself.
#
# For each configured share, this takes its latest snapshot, samples a
# handful of files from it, and runs `restic dump` on each (streams
# the file's content back out, exercising exactly the same data-read
# path a real `restic restore` would use) under a timeout. It does
# NOT restore a whole snapshot - only a small sample - to keep this
# safe and cheap to run regularly rather than pulling potentially
# huge amounts of data every time.
#
# IMPORTANT - read this before scheduling it: this repository's data
# sits behind S3 Glacier / tape (see docs/glacier-notes.md). If your
# specific destination requires an explicit restore/thaw step before
# archived objects become readable (true of AWS Glacier and Glacier
# Deep Archive; NOT necessarily true of an on-prem S3-compatible
# gateway that serves reads transparently), `restic dump` here will
# simply fail or hang until RESTIC_VERIFY_TIMEOUT - and that failure
# IS the useful signal telling you this can't run unattended as-is.
# Run this manually first and see what actually happens against your
# real repository before enabling restic-verify.timer.
#
# Usage: restic-verify.sh [share-path]
#   With no argument, verifies every configured share. With a path
#   (must match an entry in shares.conf), verifies only that one.

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/restic-common.sh"

command -v jq >/dev/null 2>&1 || die "restic-verify.sh requires jq to be installed"
command -v shuf >/dev/null 2>&1 || die "restic-verify.sh requires shuf (coreutils) to be installed"

LOG_FILE="${VERIFY_LOG_FILE:-${LOG_DIR}/verify.log}"
RESTIC_VERIFY_SAMPLE_FILES="${RESTIC_VERIFY_SAMPLE_FILES:-3}"
RESTIC_VERIFY_TIMEOUT="${RESTIC_VERIFY_TIMEOUT:-300}"

START_TS=$(date +%s)
log_info "===== restic verify starting (repo: ${RESTIC_REPOSITORY}, sample=${RESTIC_VERIFY_SAMPLE_FILES} files/share, timeout=${RESTIC_VERIFY_TIMEOUT}s/file) ====="

parse_shares_file

ONLY_PATH="${1:-}"
if [[ -n "$ONLY_PATH" ]]; then
    ONLY_PATH="${ONLY_PATH%/}"
fi

TOTAL_FAILED=0
FAILED_SHARES=()
CHECKED_SHARES=0

for i in "${!SHARE_PATHS[@]}"; do
    path="${SHARE_PATHS[$i]}"
    share_name="$(basename "$path")"

    if [[ -n "$ONLY_PATH" && "$path" != "$ONLY_PATH" ]]; then
        continue
    fi
    CHECKED_SHARES=$((CHECKED_SHARES + 1))

    log_info "share '$share_name' ($path): looking up latest snapshot"
    snapshot_id="$(restic snapshots "${RESTIC_GLOBAL_ARGS[@]}" --path "$path" --json --latest 1 \
        | jq -r '.[0].short_id // empty' 2>>"$LOG_FILE")"

    if [[ -z "$snapshot_id" ]]; then
        log_error "share '$share_name': no snapshots found - nothing to verify (has it ever backed up successfully?)"
        TOTAL_FAILED=$((TOTAL_FAILED + 1))
        FAILED_SHARES+=("${share_name} (no snapshots)")
        continue
    fi
    log_info "share '$share_name': verifying against snapshot $snapshot_id"

    mapfile -t files < <(restic ls "${RESTIC_GLOBAL_ARGS[@]}" "$snapshot_id" --json 2>>"$LOG_FILE" \
        | jq -r 'select(.type=="file") | .path' \
        | shuf -n "$RESTIC_VERIFY_SAMPLE_FILES")

    if [[ ${#files[@]} -eq 0 ]]; then
        log_warn "share '$share_name': snapshot $snapshot_id has no files to sample (empty share?) - skipping"
        continue
    fi

    share_failed=0
    for f in "${files[@]}"; do
        log_info "share '$share_name': dumping '$f' from $snapshot_id (timeout ${RESTIC_VERIFY_TIMEOUT}s)"
        timeout "${RESTIC_VERIFY_TIMEOUT}" restic dump "${RESTIC_GLOBAL_ARGS[@]}" "$snapshot_id" "$f" 2>>"$LOG_FILE" \
            | sha256sum >>"$LOG_FILE"
        rc=${PIPESTATUS[0]}

        if [[ $rc -eq 0 ]]; then
            log_info "share '$share_name': OK - '$f' read back successfully"
        elif [[ $rc -eq 124 ]]; then
            log_error "share '$share_name': TIMEOUT reading '$f' back after ${RESTIC_VERIFY_TIMEOUT}s - this share's data may not be readable without an explicit Glacier restore step; see docs/glacier-notes.md"
            share_failed=1
        else
            log_error "share '$share_name': FAILED to read '$f' back (exit $rc)"
            share_failed=1
        fi
    done

    if [[ $share_failed -eq 1 ]]; then
        TOTAL_FAILED=$((TOTAL_FAILED + 1))
        FAILED_SHARES+=("$share_name")
    fi
done

if [[ -n "$ONLY_PATH" && $CHECKED_SHARES -eq 0 ]]; then
    die "no share matching '$ONLY_PATH' found in shares.conf"
fi

END_TS=$(date +%s)
DURATION=$((END_TS - START_TS))
host="$(hostname -f 2>/dev/null || hostname)"

if [[ $TOTAL_FAILED -gt 0 ]]; then
    log_error "===== restic verify finished in ${DURATION}s: ${TOTAL_FAILED} share(s) FAILED verification ====="
    notify verify failure "restic restore verification on ${host} FAILED for share(s): ${FAILED_SHARES[*]} (after ${DURATION}s). See ${LOG_FILE}."
    exit 1
fi

log_info "===== restic verify finished successfully in ${DURATION}s (${CHECKED_SHARES} share(s) checked) ====="
notify verify success "restic restore verification on ${host} completed successfully in ${DURATION}s (${CHECKED_SHARES} share(s), ${RESTIC_VERIFY_SAMPLE_FILES} sampled files each)."
exit 0
