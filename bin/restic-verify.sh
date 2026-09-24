#!/usr/bin/env bash
# Restore verification: proves each share's backups are actually
# readable/restorable, not just "present" - `restic check` alone only
# validates metadata, never the archived pack data itself.
#
# Two modes, controlled by RESTIC_VERIFY_USE_S3_RESTORE:
#
# - false (transparent-read destinations): samples a handful of files
#   per share and streams each straight back with `restic dump` under
#   a timeout. Cheap, no scratch disk needed.
#
# - true (default - this repository's destination needs it, confirmed
#   against the real scrat-1.ctie.etat.lu repo): samples a handful of
#   files, then:
#     1. RESTIC_FEATURES=s3-restore restic restore <snapshot> \
#          -o s3.enable-restore=1 -o s3.restore-days=<N> \
#          -o s3.restore-timeout=<duration> --target <scratch> \
#          --include <file> [--include <file> ...]
#        Triggers the tape recall. On this destination this call
#        itself reliably FAILS (confirmed) even though the recall
#        proceeds in the background on the gateway's own tape cache -
#        so its exit code is logged but never treated as fatal; its
#        only job is to kick off the recall.
#     2. restic restore <snapshot> --target <scratch> --include <file> ...
#        Plain restore - retried on a poll interval
#        (RESTIC_VERIFY_POLL_INTERVAL) until it succeeds or the overall
#        RESTIC_VERIFY_RESTORE_TIMEOUT budget is used up, since there is
#        no other signal for "the tape has finished mounting/seeking
#        and the data is now in the gateway's cache" than trying again.
#   All sampled files for a share are restored in ONE pair of calls
#   (multiple --include flags), not one pair per file, so there's one
#   wait for the whole share, not N sequential waits.
#
# It never restores a whole snapshot - only the sampled files - and
# the target directory's contents are always removed afterward,
# regardless of success or failure - only this run's restored sample
# files, nothing that was already there.
#
# Usage: restic-verify.sh --target <path> [share-path]
#   --target <path> is REQUIRED when RESTIC_VERIFY_USE_S3_RESTORE=true
#   (the default) - there is deliberately no configured/default
#   location: this is a manual, deliberate restore test, and you must
#   say explicitly, every time, where there is real free disk space to
#   restore into (NOT /opt/restic - not enough room there). Not needed
#   in dump mode (RESTIC_VERIFY_USE_S3_RESTORE=false).
#
#   With no share-path, verifies every configured share. With a path
#   (must match an entry in shares.conf), verifies only that one.

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/restic-common.sh"

command -v jq >/dev/null 2>&1 || die "restic-verify.sh requires jq to be installed"
command -v shuf >/dev/null 2>&1 || die "restic-verify.sh requires shuf (coreutils) to be installed"

LOG_FILE="${VERIFY_LOG_FILE:-${LOG_DIR}/verify.log}"
RESTIC_VERIFY_SAMPLE_FILES="${RESTIC_VERIFY_SAMPLE_FILES:-3}"
RESTIC_VERIFY_USE_S3_RESTORE="${RESTIC_VERIFY_USE_S3_RESTORE:-true}"
RESTIC_VERIFY_RESTORE_DAYS="${RESTIC_VERIFY_RESTORE_DAYS:-1}"
RESTIC_VERIFY_RESTORE_TIMEOUT="${RESTIC_VERIFY_RESTORE_TIMEOUT:-24h}"
RESTIC_VERIFY_POLL_INTERVAL="${RESTIC_VERIFY_POLL_INTERVAL:-60}"
RESTIC_VERIFY_ATTEMPT_TIMEOUT="${RESTIC_VERIFY_ATTEMPT_TIMEOUT:-120}"

# restic's -o s3.restore-timeout takes a Go duration string (e.g.
# "24h", "90m", "1h30m"). We also use it, parsed to seconds, as the
# overall budget for how long we keep retrying the plain restore step
# below. Only a handful of "<number><unit>" segments are supported
# (h/m/s) - that covers every realistic restic duration.
_duration_to_seconds() {
    local dur="$1" total=0 num unit
    while [[ "$dur" =~ ^([0-9]+)(h|m|s)(.*)$ ]]; do
        num="${BASH_REMATCH[1]}"
        unit="${BASH_REMATCH[2]}"
        dur="${BASH_REMATCH[3]}"
        case "$unit" in
            h) total=$((total + num * 3600)) ;;
            m) total=$((total + num * 60)) ;;
            s) total=$((total + num)) ;;
        esac
    done
    echo "$total"
}

# --- argument parsing ---------------------------------------------------

TARGET_DIR=""
ONLY_PATH=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --target)
            [[ $# -ge 2 ]] || die "--target requires a path argument"
            TARGET_DIR="${2%/}"
            shift 2
            ;;
        --target=*)
            TARGET_DIR="${1#--target=}"
            TARGET_DIR="${TARGET_DIR%/}"
            shift
            ;;
        *)
            ONLY_PATH="${1%/}"
            shift
            ;;
    esac
done

if [[ "$RESTIC_VERIFY_USE_S3_RESTORE" == "true" ]]; then
    if [[ -z "$TARGET_DIR" ]]; then
        die "usage: restic-verify.sh --target <path-with-free-space> [share-path] (--target is required in s3-restore mode - see the header comment for why)"
    fi
    [[ -d "$TARGET_DIR" ]] || die "--target directory does not exist: $TARGET_DIR"
    RESTORE_TIMEOUT_SECONDS=$(_duration_to_seconds "$RESTIC_VERIFY_RESTORE_TIMEOUT")
    [[ "$RESTORE_TIMEOUT_SECONDS" -gt 0 ]] || die "could not parse RESTIC_VERIFY_RESTORE_TIMEOUT='$RESTIC_VERIFY_RESTORE_TIMEOUT' (expected a Go duration like 24h, 90m, 1h30m)"
else
    RESTIC_VERIFY_TIMEOUT="${RESTIC_VERIFY_TIMEOUT:-300}"
fi

START_TS=$(date +%s)
if [[ "$RESTIC_VERIFY_USE_S3_RESTORE" == "true" ]]; then
    log_info "===== restic verify starting (repo: ${RESTIC_REPOSITORY}, sample=${RESTIC_VERIFY_SAMPLE_FILES} files/share, mode=s3-restore, target=${TARGET_DIR}, restore-days=${RESTIC_VERIFY_RESTORE_DAYS}, restore-timeout=${RESTIC_VERIFY_RESTORE_TIMEOUT}) ====="
else
    log_info "===== restic verify starting (repo: ${RESTIC_REPOSITORY}, sample=${RESTIC_VERIFY_SAMPLE_FILES} files/share, mode=dump, timeout=${RESTIC_VERIFY_TIMEOUT}s/file) ====="
fi

parse_shares_file

TOTAL_FAILED=0
FAILED_SHARES=()
CHECKED_SHARES=0

# verify_share_via_dump <share_name> <snapshot_id> <file...>
verify_share_via_dump() {
    local share_name="$1" snapshot_id="$2"
    shift 2
    local rc failed=0
    for f in "$@"; do
        log_info "share '$share_name': dumping '$f' from $snapshot_id (timeout ${RESTIC_VERIFY_TIMEOUT}s)"
        timeout "${RESTIC_VERIFY_TIMEOUT}" restic dump "${RESTIC_GLOBAL_ARGS[@]}" "$snapshot_id" "$f" 2>>"$LOG_FILE" \
            | sha256sum >>"$LOG_FILE"
        rc=${PIPESTATUS[0]}

        if [[ $rc -eq 0 ]]; then
            log_info "share '$share_name': OK - '$f' read back successfully"
        elif [[ $rc -eq 124 ]]; then
            log_error "share '$share_name': TIMEOUT reading '$f' back after ${RESTIC_VERIFY_TIMEOUT}s - this share's data may not be readable without an explicit Glacier restore step; see docs/glacier-notes.md"
            failed=1
        else
            log_error "share '$share_name': FAILED to read '$f' back (exit $rc)"
            failed=1
        fi
    done
    return $failed
}

# verify_share_via_s3_restore <share_name> <snapshot_id> <file...>
verify_share_via_s3_restore() {
    local share_name="$1" snapshot_id="$2"
    shift 2
    local files=("$@")
    local include_args=()
    for f in "${files[@]}"; do
        include_args+=(--include "$f")
    done

    local scratch_dir
    scratch_dir="$(mktemp -d -p "$TARGET_DIR" "verify-${share_name}-XXXXXX")"

    # Single exit point (falls through to "done" at the bottom) so the
    # scratch dir is always cleaned up on every path - no early
    # `return`, since a function-local RETURN trap isn't reliably
    # scoped to just this invocation in bash.
    local failed=1 rc

    log_info "share '$share_name': triggering tape recall for ${#files[@]} sampled file(s) from $snapshot_id (restore-days=${RESTIC_VERIFY_RESTORE_DAYS}, restore-timeout=${RESTIC_VERIFY_RESTORE_TIMEOUT})"
    timeout "${RESTIC_VERIFY_ATTEMPT_TIMEOUT}" env RESTIC_FEATURES=s3-restore restic restore \
        "${RESTIC_GLOBAL_ARGS[@]}" "$snapshot_id" \
        -o "s3.enable-restore=1" \
        -o "s3.restore-days=${RESTIC_VERIFY_RESTORE_DAYS}" \
        -o "s3.restore-timeout=${RESTIC_VERIFY_RESTORE_TIMEOUT}" \
        --target "$scratch_dir" \
        "${include_args[@]}" >>"$LOG_FILE" 2>&1
    rc=$?
    # This call is EXPECTED to fail on this destination (confirmed):
    # the recall still proceeds on the tape gateway's own cache in the
    # background regardless of this process's exit code. Its only job
    # is to have kicked off that recall - never treated as fatal here.
    log_info "share '$share_name': recall trigger exited $rc (non-zero is normal on this destination - not treated as an error); polling for the data to land"

    local elapsed=0
    while [[ $elapsed -lt $RESTORE_TIMEOUT_SECONDS ]]; do
        timeout "${RESTIC_VERIFY_ATTEMPT_TIMEOUT}" restic restore \
            "${RESTIC_GLOBAL_ARGS[@]}" "$snapshot_id" \
            --target "$scratch_dir" \
            "${include_args[@]}" >>"$LOG_FILE" 2>&1
        rc=$?
        if [[ $rc -eq 0 ]]; then
            log_info "share '$share_name': plain restore succeeded after ~${elapsed}s of waiting"
            failed=0
            break
        fi
        log_info "share '$share_name': data not ready yet (plain restore exit $rc) - retrying in ${RESTIC_VERIFY_POLL_INTERVAL}s (waited ${elapsed}s/${RESTORE_TIMEOUT_SECONDS}s so far)"
        sleep "$RESTIC_VERIFY_POLL_INTERVAL"
        elapsed=$((elapsed + RESTIC_VERIFY_POLL_INTERVAL))
    done

    if [[ $failed -eq 1 ]]; then
        log_error "share '$share_name': data never became available within ${RESTIC_VERIFY_RESTORE_TIMEOUT} (RESTIC_VERIFY_RESTORE_TIMEOUT) - giving up"
    else
        for f in "${files[@]}"; do
            local restored="${scratch_dir}${f}"
            if [[ ! -s "$restored" ]]; then
                log_error "share '$share_name': '$f' did not land in the restored output (missing or empty at $restored)"
                failed=1
            else
                log_info "share '$share_name': OK - '$f' restored successfully ($(stat -c%s "$restored" 2>/dev/null || echo '?') bytes)"
            fi
        done
    fi

    rm -rf "$scratch_dir"
    return $failed
}

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

    if [[ "$RESTIC_VERIFY_USE_S3_RESTORE" == "true" ]]; then
        verify_share_via_s3_restore "$share_name" "$snapshot_id" "${files[@]}"
    else
        verify_share_via_dump "$share_name" "$snapshot_id" "${files[@]}"
    fi
    share_failed=$?

    if [[ $share_failed -ne 0 ]]; then
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
