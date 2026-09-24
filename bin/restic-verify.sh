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
#   files, then runs restic's own two-step Glacier-restore sequence to
#   pull just those files into a scratch directory:
#     1. RESTIC_FEATURES=s3-restore restic restore <snapshot> \
#          -o s3.enable-restore=1 -o s3.restore-days=<N> \
#          -o s3.restore-timeout=<duration> --target <scratch> \
#          --include <file> [--include <file> ...]
#        Triggers an S3 RestoreObject for whatever pack objects those
#        files need and waits (up to s3.restore-timeout) for them to
#        thaw.
#     2. restic restore <snapshot> --target <scratch> --include <file> ...
#        Plain restore, now that the objects are warm.
#   All sampled files for a share are restored in ONE call (multiple
#   --include flags) rather than one call per file, so there's one
#   wait for the whole share, not N sequential waits.
#
# It never restores a whole snapshot - only the sampled files - and
# the scratch directory is always removed afterward (trap on exit),
# regardless of success or failure.
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
RESTIC_VERIFY_USE_S3_RESTORE="${RESTIC_VERIFY_USE_S3_RESTORE:-true}"
RESTIC_VERIFY_RESTORE_DAYS="${RESTIC_VERIFY_RESTORE_DAYS:-1}"
RESTIC_VERIFY_RESTORE_TIMEOUT="${RESTIC_VERIFY_RESTORE_TIMEOUT:-24h}"
RESTIC_VERIFY_SCRATCH_DIR="${RESTIC_VERIFY_SCRATCH_DIR:-/opt/restic/restic-verify-scratch}"

# restic's -o s3.restore-timeout takes a Go duration string (e.g.
# "24h", "90m", "1h30m"). This is our own outer safety net around the
# whole two-step sequence, in seconds, so a bug in restic's own
# internal wait can't hang the job forever: it's that duration plus a
# 10-minute buffer. Only a handful of "<number><unit>" segments are
# supported (h/m/s) - that covers every realistic restic duration.
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

if [[ "$RESTIC_VERIFY_USE_S3_RESTORE" == "true" ]]; then
    RESTORE_TIMEOUT_SECONDS=$(_duration_to_seconds "$RESTIC_VERIFY_RESTORE_TIMEOUT")
    [[ "$RESTORE_TIMEOUT_SECONDS" -gt 0 ]] || die "could not parse RESTIC_VERIFY_RESTORE_TIMEOUT='$RESTIC_VERIFY_RESTORE_TIMEOUT' (expected a Go duration like 24h, 90m, 1h30m)"
    OUTER_TIMEOUT_SECONDS=$((RESTORE_TIMEOUT_SECONDS + 600))
    mkdir -p "$RESTIC_VERIFY_SCRATCH_DIR"
else
    RESTIC_VERIFY_TIMEOUT="${RESTIC_VERIFY_TIMEOUT:-300}"
fi

START_TS=$(date +%s)
if [[ "$RESTIC_VERIFY_USE_S3_RESTORE" == "true" ]]; then
    log_info "===== restic verify starting (repo: ${RESTIC_REPOSITORY}, sample=${RESTIC_VERIFY_SAMPLE_FILES} files/share, mode=s3-restore, restore-days=${RESTIC_VERIFY_RESTORE_DAYS}, restore-timeout=${RESTIC_VERIFY_RESTORE_TIMEOUT}) ====="
else
    log_info "===== restic verify starting (repo: ${RESTIC_REPOSITORY}, sample=${RESTIC_VERIFY_SAMPLE_FILES} files/share, mode=dump, timeout=${RESTIC_VERIFY_TIMEOUT}s/file) ====="
fi

parse_shares_file

ONLY_PATH="${1:-}"
if [[ -n "$ONLY_PATH" ]]; then
    ONLY_PATH="${ONLY_PATH%/}"
fi

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
    scratch_dir="$(mktemp -d -p "$RESTIC_VERIFY_SCRATCH_DIR" "verify-${share_name}-XXXXXX")"

    # Single exit point (falls through to "done" at the bottom) so the
    # scratch dir is always cleaned up on every path - no early
    # `return`, since a function-local RETURN trap isn't reliably
    # scoped to just this invocation in bash.
    local failed=0 rc

    log_info "share '$share_name': triggering S3 restore for ${#files[@]} sampled file(s) from $snapshot_id (restore-days=${RESTIC_VERIFY_RESTORE_DAYS}, restore-timeout=${RESTIC_VERIFY_RESTORE_TIMEOUT}, outer timeout ${OUTER_TIMEOUT_SECONDS}s)"
    timeout "${OUTER_TIMEOUT_SECONDS}" env RESTIC_FEATURES=s3-restore restic restore \
        "${RESTIC_GLOBAL_ARGS[@]}" "$snapshot_id" \
        -o "s3.enable-restore=1" \
        -o "s3.restore-days=${RESTIC_VERIFY_RESTORE_DAYS}" \
        -o "s3.restore-timeout=${RESTIC_VERIFY_RESTORE_TIMEOUT}" \
        --target "$scratch_dir" \
        "${include_args[@]}" >>"$LOG_FILE" 2>&1
    rc=$?
    if [[ $rc -eq 124 ]]; then
        log_error "share '$share_name': TIMEOUT waiting for S3 restore after ${OUTER_TIMEOUT_SECONDS}s (outer safety net - restic's own s3.restore-timeout=${RESTIC_VERIFY_RESTORE_TIMEOUT} should have given up first)"
        failed=1
    elif [[ $rc -ne 0 ]]; then
        log_error "share '$share_name': S3 restore trigger step FAILED (exit $rc)"
        failed=1
    else
        log_info "share '$share_name': S3 restore step completed, running the plain restore now that objects should be warm"

        timeout "${OUTER_TIMEOUT_SECONDS}" restic restore \
            "${RESTIC_GLOBAL_ARGS[@]}" "$snapshot_id" \
            --target "$scratch_dir" \
            "${include_args[@]}" >>"$LOG_FILE" 2>&1
        rc=$?
        if [[ $rc -ne 0 ]]; then
            log_error "share '$share_name': plain restore step FAILED (exit $rc) after the S3 restore step succeeded"
            failed=1
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
