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
RESTIC_NOTIFY_ON="${RESTIC_NOTIFY_ON:-failure}"
RESTIC_STATUS_DIR="${RESTIC_STATUS_DIR:-/var/log/restic/status}"

# restic itself does not read RESTIC_TMP_DIR; it (and the Go runtime)
# use TMPDIR for scratch space. Export it under the standard name so
# operators can keep using the RESTIC_TMP_DIR name in restic.env.
mkdir -p "$RESTIC_CACHE_DIR" "$RESTIC_TMP_DIR" "$LOG_DIR" "$(dirname "$RESTIC_LOCK_FILE")" "$RESTIC_STATUS_DIR"
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
# shellcheck disable=SC2034  # used by the scripts that source this file
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

# --- status file + notifications ------------------------------------------
#
# Every automated job (backup, maintenance, verify) reports its
# outcome two ways:
#   1. A status file any external monitoring (Nagios, Zabbix, a simple
#      cron check, ...) can poll or `source` - always written,
#      regardless of whether notifications are configured.
#   2. An email and/or webhook notification - only for failures and
#      warnings by default (RESTIC_NOTIFY_ON=failure), or always if
#      set to "always". Both channels are opt-in: set
#      RESTIC_NOTIFY_EMAIL and/or RESTIC_NOTIFY_WEBHOOK_URL in
#      restic.env to enable them. Neither is required - the status
#      file alone is useful with zero configuration.

# write_status_file <job> <status> <summary>
#   job: "backup" | "maintenance" | "verify"
#   status: "success" | "warning" | "failure" | "skipped"
write_status_file() {
    local job="$1" status="$2" summary="$3"
    local file="${RESTIC_STATUS_DIR}/${job}.status"
    local host
    host="$(hostname -f 2>/dev/null || hostname)"
    cat > "$file" <<STATUSEOF
JOB=${job}
STATUS=${status}
TIMESTAMP=$(date -Is)
HOST=${host}
SUMMARY=${summary}
STATUSEOF
}

# Minimal JSON string escaping (quotes, backslashes, newlines) so a
# one-field webhook payload can be built without depending on jq.
_notify_json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    printf '%s' "$s"
}

# notify <job> <status> <summary>
#
# Always updates the status file (see write_status_file). Sends
# email/webhook notifications too, unless status is "success" and
# RESTIC_NOTIFY_ON is not "always" - so by default you hear about
# failures and warnings, not a confirmation every single day.
# "skipped" (e.g. maintenance finding a backup still running) never
# notifies, only updates the status file - it isn't a failure.
notify() {
    local job="$1" status="$2" summary="$3"

    write_status_file "$job" "$status" "$summary"

    if [[ "$status" == "skipped" ]]; then
        return 0
    fi
    if [[ "$status" == "success" && "${RESTIC_NOTIFY_ON}" != "always" ]]; then
        return 0
    fi

    local host subject
    host="$(hostname -f 2>/dev/null || hostname)"
    subject="[restic] ${job} ${status} on ${host}"

    if [[ -n "${RESTIC_NOTIFY_EMAIL:-}" ]]; then
        if command -v mail >/dev/null 2>&1; then
            printf '%s\n' "$summary" | mail -s "$subject" "$RESTIC_NOTIFY_EMAIL" \
                || log_error "notify: 'mail' failed to send to $RESTIC_NOTIFY_EMAIL"
        elif command -v sendmail >/dev/null 2>&1; then
            printf 'To: %s\nSubject: %s\n\n%s\n' "$RESTIC_NOTIFY_EMAIL" "$subject" "$summary" \
                | sendmail -t \
                || log_error "notify: 'sendmail' failed to send to $RESTIC_NOTIFY_EMAIL"
        else
            log_error "notify: RESTIC_NOTIFY_EMAIL is set but neither 'mail' nor 'sendmail' is installed"
        fi
    fi

    if [[ -n "${RESTIC_NOTIFY_WEBHOOK_URL:-}" ]]; then
        if command -v curl >/dev/null 2>&1; then
            local escaped
            escaped="$(_notify_json_escape "${subject}: ${summary}")"
            curl -fsS -m 10 -X POST -H 'Content-Type: application/json' \
                -d "{\"text\": \"${escaped}\"}" "$RESTIC_NOTIFY_WEBHOOK_URL" >/dev/null \
                || log_error "notify: webhook POST to $RESTIC_NOTIFY_WEBHOOK_URL failed"
        else
            log_error "notify: RESTIC_NOTIFY_WEBHOOK_URL is set but curl is not installed"
        fi
    fi
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

# --- retention policies + per-share config --------------------------------
#
# Each share in SHARES_FILE names a retention policy defined in
# RETENTION_POLICIES_FILE, so different shares can keep short/mid/long
# history independently. This only works because restic-backup.sh
# backs up each share as its own `restic backup <path>` call (one
# snapshot per share, per run) rather than combining every share into
# a single multi-path snapshot: `restic forget`/`prune` operate on
# whole snapshots, so distinct retention per share requires each share
# to own distinct snapshots that `restic forget --path <share>` can
# select independently.

# Populates the associative arrays POLICY_KEEP_DAILY/WEEKLY/MONTHLY/YEARLY,
# keyed by policy name, from RETENTION_POLICIES_FILE.
load_retention_policies() {
    : "${RETENTION_POLICIES_FILE:?RETENTION_POLICIES_FILE must be set in $RESTIC_ENV_FILE}"
    [[ -r "$RETENTION_POLICIES_FILE" ]] || die "cannot read RETENTION_POLICIES_FILE: $RETENTION_POLICIES_FILE"

    declare -gA POLICY_KEEP_DAILY=()
    declare -gA POLICY_KEEP_WEEKLY=()
    declare -gA POLICY_KEEP_MONTHLY=()
    declare -gA POLICY_KEEP_YEARLY=()

    local line name daily weekly monthly yearly
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%$'\r'}"
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        read -r name daily weekly monthly yearly <<< "$line"
        [[ -z "$name" ]] && continue

        if [[ -z "$daily" || -z "$weekly" || -z "$monthly" || -z "$yearly" ]]; then
            die "malformed line in $RETENTION_POLICIES_FILE (expected: name keep_daily keep_weekly keep_monthly keep_yearly): $line"
        fi

        # WEEKLY/MONTHLY/YEARLY are only read by the scripts that source
        # this file (restic-maintenance.sh).
        POLICY_KEEP_DAILY["$name"]="$daily"
        # shellcheck disable=SC2034
        POLICY_KEEP_WEEKLY["$name"]="$weekly"
        # shellcheck disable=SC2034
        POLICY_KEEP_MONTHLY["$name"]="$monthly"
        # shellcheck disable=SC2034
        POLICY_KEEP_YEARLY["$name"]="$yearly"
    done < "$RETENTION_POLICIES_FILE"

    if [[ ${#POLICY_KEEP_DAILY[@]} -eq 0 ]]; then
        die "no retention policies found in $RETENTION_POLICIES_FILE"
    fi
}

# Parses SHARES_FILE ("<path> <policy-name>" per line) into the
# index-aligned arrays SHARE_PATHS / SHARE_POLICIES, covering every
# configured share regardless of its current mount state. Calls
# load_retention_policies itself and aborts (die) if a share names a
# policy that doesn't exist - a bad retention policy name is a config
# error, not something to silently fall back on.
parse_shares_file() {
    : "${SHARES_FILE:?SHARES_FILE must be set in $RESTIC_ENV_FILE}"
    [[ -r "$SHARES_FILE" ]] || die "cannot read SHARES_FILE: $SHARES_FILE"

    load_retention_policies

    SHARE_PATHS=()
    SHARE_POLICIES=()

    local line path policy
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%$'\r'}"
        line="${line#"${line%%[![:space:]]*}"}"   # trim leading whitespace
        line="${line%"${line##*[![:space:]]}"}"   # trim trailing whitespace
        [[ -z "$line" || "$line" =~ ^# ]] && continue

        policy="${line##* }"
        path="${line% *}"
        path="${path%"${path##*[![:space:]]}"}"    # trim whitespace left over between columns
        path="${path%/}"

        if [[ -z "${POLICY_KEEP_DAILY[$policy]+x}" ]]; then
            die "unknown retention policy '$policy' for share '$path' in $SHARES_FILE (check $RETENTION_POLICIES_FILE)"
        fi

        SHARE_PATHS+=("$path")
        SHARE_POLICIES+=("$policy")
    done < "$SHARES_FILE"

    if [[ ${#SHARE_PATHS[@]} -eq 0 ]]; then
        die "no shares found in $SHARES_FILE"
    fi
}

# Must be called after parse_shares_file. Verifies every entry in
# SHARE_PATHS is an active mount point, populating the index-aligned
# arrays VALID_SHARE_PATHS / VALID_SHARE_POLICIES. Missing/unmounted
# shares are logged and, if REQUIRE_MOUNTED=true, cause the caller to
# abort (via return 1); a per-share failure is never silently ignored.
# Only used by backup - maintenance applies retention to every
# configured share regardless of whether it's currently mounted.
check_shares_mounted() {
    VALID_SHARE_PATHS=()
    VALID_SHARE_POLICIES=()
    local i path missing=0

    for i in "${!SHARE_PATHS[@]}"; do
        path="${SHARE_PATHS[$i]}"

        if [[ ! -d "$path" ]]; then
            log_error "share path does not exist: $path"
            missing=1
            continue
        fi

        if [[ "$REQUIRE_MOUNTED" == "true" ]]; then
            if ! mountpoint -q "$path"; then
                log_error "share path is not an active mount point: $path"
                missing=1
                continue
            fi
        fi

        VALID_SHARE_PATHS+=("$path")
        VALID_SHARE_POLICIES+=("${SHARE_POLICIES[$i]}")
    done

    if [[ ${#VALID_SHARE_PATHS[@]} -eq 0 ]]; then
        log_error "no valid shares found in $SHARES_FILE"
        return 1
    fi

    if [[ $missing -eq 1 ]]; then
        log_error "one or more configured shares are missing/unmounted; aborting to avoid a partial or empty backup"
        return 1
    fi

    return 0
}
