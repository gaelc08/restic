#!/usr/bin/env bash
# NetApp ONTAP REST API helpers for the snapshot-then-backup flow (see
# "Backing up from a NetApp snapshot" in README.md). Sourced only by
# restic-backup.sh, and only exercised for shares actually listed in
# NETAPP_VOLUMES_FILE - every other script, and any share not listed
# there, never touches this file or needs any of its config.
#
# Needs (see config/secrets.env.example): NETAPP_API_URL,
# NETAPP_API_USER, NETAPP_API_PASSWORD (or NETAPP_API_PASSWORD_FILE),
# NETAPP_API_CACERT. Uses curl + jq (already a dependency).
#
# Not meant to be executed directly - like restic-common.sh, this is
# a function library only.

set -uo pipefail

# --- NETAPP_VOLUMES_FILE parsing ------------------------------------------
#
# Populates the associative arrays NETAPP_SVM/NETAPP_VOLUME, keyed by
# share mount point (exactly as it appears in shares.conf), from
# NETAPP_VOLUMES_FILE. A share with no entry there is simply absent
# from both arrays - callers check with [[ -v "NETAPP_SVM[$path]" ]]
# before doing anything NetApp-specific, so a missing or entirely
# unset NETAPP_VOLUMES_FILE is never an error, just "no shares use
# this feature".
netapp_load_mapping() {
    declare -gA NETAPP_SVM=()
    declare -gA NETAPP_VOLUME=()

    local file="${NETAPP_VOLUMES_FILE:-}"
    [[ -n "$file" && -r "$file" ]] || return 0

    local line path svm volume
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%$'\r'}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" || "$line" =~ ^# ]] && continue

        read -r path svm volume <<< "$line"
        if [[ -z "$path" || -z "$svm" || -z "$volume" ]]; then
            die "malformed line in $file (expected: <path> <svm> <volume>): $line"
        fi
        path="${path%/}"
        # shellcheck disable=SC2034  # used by restic-backup.sh, which sources this file
        NETAPP_SVM["$path"]="$svm"
        # shellcheck disable=SC2034  # used by restic-backup.sh, which sources this file
        NETAPP_VOLUME["$path"]="$volume"
    done < "$file"
}

# --- Credentials -----------------------------------------------------------

_netapp_password() {
    if [[ -n "${NETAPP_API_PASSWORD:-}" ]]; then
        printf '%s' "$NETAPP_API_PASSWORD"
    elif [[ -n "${NETAPP_API_PASSWORD_FILE:-}" ]]; then
        cat "$NETAPP_API_PASSWORD_FILE"
    else
        die "one of NETAPP_API_PASSWORD or NETAPP_API_PASSWORD_FILE must be set to use NetApp snapshots"
    fi
}

_netapp_require_config() {
    : "${NETAPP_API_URL:?NETAPP_API_URL must be set to use NetApp snapshots}"
    : "${NETAPP_API_USER:?NETAPP_API_USER must be set to use NetApp snapshots}"
    : "${NETAPP_API_CACERT:?NETAPP_API_CACERT must be set to use NetApp snapshots - this project never disables TLS verification}"
    [[ -r "$NETAPP_API_CACERT" ]] || die "NETAPP_API_CACERT not readable: $NETAPP_API_CACERT"
}

# --- Low-level REST call ----------------------------------------------------
#
# netapp_api <method> <path> [json-body] -> response body on stdout.
# <path> is relative to NETAPP_API_URL (e.g. "/api/storage/volumes").
# Returns non-zero (and logs the response) on anything other than a
# 2xx status.
netapp_api() {
    local method="$1" path="$2" body="${3:-}"
    _netapp_require_config
    local password
    password="$(_netapp_password)"

    local -a curl_args=(
        -sS -w '\n%{http_code}'
        --cacert "$NETAPP_API_CACERT"
        -u "${NETAPP_API_USER}:${password}"
        -H 'Accept: application/json'
        -X "$method"
    )
    if [[ -n "$body" ]]; then
        curl_args+=(-H 'Content-Type: application/json' -d "$body")
    fi

    local raw http_code response
    raw="$(curl "${curl_args[@]}" "${NETAPP_API_URL}${path}" 2>>"$LOG_FILE")"
    http_code="${raw##*$'\n'}"
    response="${raw%$'\n'*}"

    if [[ ! "$http_code" =~ ^[0-9]+$ ]] || ((http_code < 200 || http_code >= 300)); then
        log_error "NetApp API ${method} ${path} -> HTTP ${http_code}: ${response}"
        return 1
    fi
    printf '%s' "$response"
}

# netapp_wait_job <job-uuid> - polls a ONTAP REST async job until it
# reports success or failure (snapshot create/delete are near-instant
# on the storage side, but ONTAP REST still wraps them as jobs) -
# timeout after 60s, generous for an operation that normally
# completes in well under a second.
netapp_wait_job() {
    local job_uuid="$1" tries=60 state
    while (( tries-- > 0 )); do
        state="$(netapp_api GET "/api/cluster/jobs/${job_uuid}" | jq -r '.state // empty')" || return 1
        case "$state" in
            success) return 0 ;;
            failure|error)
                log_error "NetApp job ${job_uuid} failed"
                return 1
                ;;
        esac
        sleep 1
    done
    log_error "NetApp job ${job_uuid} did not finish within 60s"
    return 1
}

# netapp_get_volume_uuid <svm> <volume> -> uuid on stdout, or non-zero
# if not found/ambiguous.
netapp_get_volume_uuid() {
    local svm="$1" volume="$2" response count uuid
    response="$(netapp_api GET "/api/storage/volumes?name=${volume}&svm.name=${svm}&fields=uuid")" || return 1
    count="$(jq -r '.num_records' <<<"$response")"
    if [[ "$count" != "1" ]]; then
        log_error "NetApp volume lookup for svm=${svm} volume=${volume} returned ${count} result(s), expected exactly 1"
        return 1
    fi
    uuid="$(jq -r '.records[0].uuid' <<<"$response")"
    [[ -n "$uuid" && "$uuid" != "null" ]] || return 1
    printf '%s' "$uuid"
}

# netapp_create_snapshot <svm> <volume> <name> - idempotent: deletes
# any existing snapshot with the same name first (leftover from a
# previous run that crashed before cleanup), then creates fresh.
netapp_create_snapshot() {
    local svm="$1" volume="$2" name="$3"
    local uuid response job_uuid

    uuid="$(netapp_get_volume_uuid "$svm" "$volume")" || return 1

    netapp_delete_snapshot "$svm" "$volume" "$name" || true

    response="$(netapp_api POST "/api/storage/volumes/${uuid}/snapshots" "{\"name\":\"${name}\"}")" || return 1
    job_uuid="$(jq -r '.job.uuid // empty' <<<"$response")"
    if [[ -n "$job_uuid" ]]; then
        netapp_wait_job "$job_uuid" || return 1
    fi
    log_info "created NetApp snapshot ${name} on ${svm}:${volume}"
}

# netapp_delete_snapshot <svm> <volume> <name> - idempotent: a
# not-found snapshot is not an error (the common case: there was
# nothing left over from a previous run).
netapp_delete_snapshot() {
    local svm="$1" volume="$2" name="$3"
    local uuid response count snap_uuid job_uuid

    uuid="$(netapp_get_volume_uuid "$svm" "$volume")" || return 1

    response="$(netapp_api GET "/api/storage/volumes/${uuid}/snapshots?name=${name}&fields=uuid")" || return 1
    count="$(jq -r '.num_records' <<<"$response")"
    [[ "$count" == "0" ]] && return 0

    snap_uuid="$(jq -r '.records[0].uuid' <<<"$response")"
    response="$(netapp_api DELETE "/api/storage/volumes/${uuid}/snapshots/${snap_uuid}")" || return 1
    job_uuid="$(jq -r '.job.uuid // empty' <<<"$response")"
    if [[ -n "$job_uuid" ]]; then
        netapp_wait_job "$job_uuid" || return 1
    fi
    log_info "deleted NetApp snapshot ${name} on ${svm}:${volume}"
}
