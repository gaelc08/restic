#!/usr/bin/env bash
# Shared functions for the restic-backup automation scripts.
# Sourced by restic-backup.sh, restic-maintenance.sh and restic-snapshots.sh.
# Not meant to be executed directly.

set -uo pipefail

RESTIC_ENV_FILE="${RESTIC_ENV_FILE:-/etc/restic/restic.env}"

if [[ ! -r "$RESTIC_ENV_FILE" ]]; then
    echo "FATAL: cannot read config file $RESTIC_ENV_FILE" >&2
    exit 1
fi
# shellcheck disable=SC1090
source "$RESTIC_ENV_FILE"

: "${RESTIC_SECRETS_FILE:?RESTIC_SECRETS_FILE must be set in $RESTIC_ENV_FILE}"
if [[ ! -r "$RESTIC_SECRETS_FILE" ]]; then
    echo "FATAL: cannot read secrets file $RESTIC_SECRETS_FILE" >&2
    exit 1
fi
# shellcheck disable=SC1090
source "$RESTIC_SECRETS_FILE"

: "${RESTIC_REPOSITORY:?RESTIC_REPOSITORY must be set in $RESTIC_ENV_FILE}"
: "${RESTIC_PASSWORD:?RESTIC_PASSWORD must be set in $RESTIC_SECRETS_FILE}"
: "${RESTIC_CACHE_DIR:?RESTIC_CACHE_DIR must be set in $RESTIC_ENV_FILE}"
: "${RESTIC_TMP_DIR:?RESTIC_TMP_DIR must be set in $RESTIC_ENV_FILE}"
: "${LOG_DIR:?LOG_DIR must be set in $RESTIC_ENV_FILE}"

RESTIC_PACK_SIZE="${RESTIC_PACK_SIZE:-64}"
RESTIC_READ_CONCURRENCY="${RESTIC_READ_CONCURRENCY:-4}"
RESTIC_S3_CONNECTIONS="${RESTIC_S3_CONNECTIONS:-10}"
RESTIC_S3_STORAGE_CLASS="${RESTIC_S3_STORAGE_CLASS:-GLACIER}"
RESTIC_JSON_LOG="${RESTIC_JSON_LOG:-true}"
REQUIRE_MOUNTED="${REQUIRE_MOUNTED:-true}"
RESTIC_LOCK_FILE="${RESTIC_LOCK_FILE:-/run/restic/restic.lock}"

# restic itself does not read RESTIC_TMP_DIR; it (and the Go runtime)
# use TMPDIR for scratch space. Export it under the standard name so
# operators can keep using the RESTIC_TMP_DIR name in restic.env.
mkdir -p "$RESTIC_CACHE_DIR" "$RESTIC_TMP_DIR" "$LOG_DIR" "$(dirname "$RESTIC_LOCK_FILE")"
export TMPDIR="$RESTIC_TMP_DIR"
export RESTIC_CACHE_DIR
export RESTIC_REPOSITORY
export RESTIC_PASSWORD
export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-}"

# Global restic flags shared by every command (backup, forget, prune,
# snapshots, check, ...): pack size and backend connection/storage
# class options.
RESTIC_GLOBAL_ARGS=(
    --pack-size "$RESTIC_PACK_SIZE"
    -o "s3.connections=${RESTIC_S3_CONNECTIONS}"
    -o "s3.storage-class=${RESTIC_S3_STORAGE_CLASS}"
)

# --- logging -----------------------------------------------------------
#
# LOG_FILE must be set by the calling script before log()/die() is used.

log() {
    local level="$1"; shift
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S%z')"
    local line="[$ts] [$level] $*"
    echo "$line"
    if [[ -n "${LOG_FILE:-}" ]]; then
        echo "$line" >> "$LOG_FILE"
    fi
}

log_info()  { log "INFO"  "$@"; }
log_warn()  { log "WARN"  "$@"; }
log_error() { log "ERROR" "$@" >&2; }

die() {
    log_error "$@"
    exit 1
}

# --- locking -------------------------------------------------------------
#
# Backup and maintenance must never run at the same time against the
# same repository (maintenance prunes/rewrites the same pack files a
# concurrent backup might be writing). Both jobs take the same
# exclusive lock file before touching the repository.
#
# acquire_lock <timeout_seconds>
#   timeout_seconds = 0  -> try once, return immediately if already held
#   timeout_seconds > 0  -> wait up to that many seconds for the lock
#
# Returns 0 if the lock was acquired (held for the rest of the
# process's lifetime, released automatically on exit), 1 otherwise.
acquire_lock() {
    local timeout="${1:-0}"

    exec {RESTIC_LOCK_FD}>"$RESTIC_LOCK_FILE" || {
        log_error "cannot open lock file $RESTIC_LOCK_FILE"
        return 1
    }

    if [[ "$timeout" -eq 0 ]]; then
        flock -n "$RESTIC_LOCK_FD"
    else
        flock -w "$timeout" "$RESTIC_LOCK_FD"
    fi
}

# Verify every path listed in BACKUP_PATHS_FILE is an active mount
# point. Populates the global array VALID_BACKUP_PATHS. Missing/failed
# mounts are logged and, if REQUIRE_MOUNTED=true, cause the caller to
# abort (via return 1); a per-path failure is never silently ignored.
check_backup_paths() {
    : "${BACKUP_PATHS_FILE:?BACKUP_PATHS_FILE must be set in $RESTIC_ENV_FILE}"
    [[ -r "$BACKUP_PATHS_FILE" ]] || die "cannot read BACKUP_PATHS_FILE: $BACKUP_PATHS_FILE"

    VALID_BACKUP_PATHS=()
    local path missing=0

    while IFS= read -r path || [[ -n "$path" ]]; do
        [[ -z "$path" || "$path" =~ ^[[:space:]]*# ]] && continue
        path="${path%/}"

        if [[ ! -d "$path" ]]; then
            log_error "backup path does not exist: $path"
            missing=1
            continue
        fi

        if [[ "$REQUIRE_MOUNTED" == "true" ]]; then
            if ! mountpoint -q "$path"; then
                log_error "backup path is not an active mount point: $path"
                missing=1
                continue
            fi
        fi

        VALID_BACKUP_PATHS+=("$path")
    done < "$BACKUP_PATHS_FILE"

    if [[ ${#VALID_BACKUP_PATHS[@]} -eq 0 ]]; then
        log_error "no valid backup paths found in $BACKUP_PATHS_FILE"
        return 1
    fi

    if [[ $missing -eq 1 ]]; then
        log_error "one or more configured shares are missing/unmounted; aborting to avoid a partial or empty backup"
        return 1
    fi

    return 0
}
