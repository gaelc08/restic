#!/usr/bin/env bash
# Exports the capacity of the restic repository as Prometheus metrics,
# for the capacity planning tool (storage_capacity_planning), which
# reads everything from Prometheus / VictoriaMetrics:
#
#   restic_repository_capacity_bytes{repository}       RESTIC_CAPACITY_BYTES (restic.env): the space granted
#   restic_repository_stored_bytes{repository}         what the repository takes (prune: remaining + unused)
#   restic_repository_unused_bytes{repository}         of which unreferenced (never repacked: --max-repack-size 0)
#   restic_repository_measured_timestamp_seconds       when that prune ran
#   restic_share_size_bytes{repository,share,policy}   logical size of the share at its latest snapshot
#   restic_share_added_bytes{repository,share,policy}  what that snapshot added to the repository (packed)
#   restic_share_last_snapshot_timestamp_seconds{...}  when that snapshot was taken
#   restic_share_changed_bytes{repository,share,policy}    the daily change: what the snapshots of the last 24
#                                                          hours added (summary.data_added, before compression)
#   restic_share_protected_bytes{repository,share,policy}  ... against the size of the share at the latest of them
#   restic_capacity_timestamp_seconds{repository}      when this script ran
#
# It never reads archived (Glacier / tape) data and takes no repository
# lock:
#   - the repository size comes from the output the daily prune of
#     restic-maintenance.sh already writes to maintenance.log (its
#     "remaining:" and "unused size after prune:" lines). Computing it
#     here (`restic stats --mode raw-data`) would walk every snapshot
#     tree, as costly as `restic check`.
#   - the shares come from `restic snapshots --no-lock --json` (the
#     "summary" restic stores with each snapshot), like restic-webreport.sh.
#
# Usage:
#   restic-capacity-metrics.sh            push to RESTIC_METRICS_PUSH_URL and/or write RESTIC_METRICS_TEXTFILE
#                                         (print them when neither is set)
#   restic-capacity-metrics.sh --print    print only
#   restic-capacity-metrics.sh --history  also every past point: the repository size of every prune still in
#                                         the maintenance logs (90 days of logrotate), the size of every share at
#                                         every snapshot, and the daily change of every day (the 24 hours to noon,
#                                         at noon: when capacity backfill reads a day). Samples carry their
#                                         timestamp: push only (VictoriaMetrics
#                                         keeps it, node_exporter's textfile collector refuses it). Run once.
#
# Run hourly by restic-capacity-metrics.timer.

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/restic-common.sh"

LOG_FILE="${CAPACITY_METRICS_LOG_FILE:-${LOG_DIR}/capacity-metrics.log}"

# The metrics may go to stdout: the log lines go to stderr (and the log file).
log() {
    local level="$1"; shift
    local line
    line="[$(date '+%Y-%m-%d %H:%M:%S%z')] [$level] $*"
    echo "$line" >&2
    [[ -n "${LOG_FILE:-}" ]] && echo "$line" >> "$LOG_FILE"
}
MAINTENANCE_LOG="${MAINTENANCE_LOG_FILE:-${LOG_DIR}/maintenance.log}"

PRINT=0
HISTORY=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --print) PRINT=1 ;;
        --history) HISTORY=1 ;;
        -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown argument: $1 (see --help)" ;;
    esac
    shift
done

PUSH_URL="${RESTIC_METRICS_PUSH_URL:-}"
TEXTFILE="${RESTIC_METRICS_TEXTFILE:-}"
if (( PRINT )); then
    PUSH_URL=""
    TEXTFILE=""
fi
if (( HISTORY )) && [[ -n "$TEXTFILE" && -z "$PUSH_URL" ]]; then
    die "--history needs RESTIC_METRICS_PUSH_URL (or --print): node_exporter's textfile collector refuses timestamps"
fi
(( HISTORY )) && TEXTFILE=""

# The `repository` label: RESTIC_CAPACITY_REPOSITORY_NAME, or the
# repository URL without its "s3:" and scheme.
REPOSITORY_NAME="${RESTIC_CAPACITY_REPOSITORY_NAME:-$(sed -E 's#^s3:##; s#^https?://##' <<<"$RESTIC_REPOSITORY")}"

# to_bytes <size> - "500TB" (decimal), "450TiB" (binary), "1.5 PiB",
# or plain bytes -> bytes. Empty output when it cannot be read.
to_bytes() {
    awk -v s="$1" 'BEGIN {
        gsub(/[[:space:]]/, "", s)
        if (!match(s, /^[0-9]+(\.[0-9]+)?/)) exit
        n = substr(s, 1, RLENGTH); u = toupper(substr(s, RLENGTH + 1))
        split("K M G T P E", p, " ")
        f = (u == "" || u == "B") ? 1 : 0
        for (i = 1; i <= 6; i++) {
            if (u == p[i] "IB") f = 1024 ^ i
            if (u == p[i] "B")  f = 1000 ^ i
        }
        if (f) printf "%.0f\n", n * f
    }'
}

# prune_sizes <log files, oldest first> - one "timestamp<TAB>remaining
# bytes<TAB>unused bytes" line per prune found in the maintenance logs.
# The timestamp is the one of the "running: restic prune" line; the
# sizes are restic's own ("299.123 TiB": binary units).
prune_sizes() {
    local file
    for file in "$@"; do
        [[ -r "$file" ]] && zcat -f -- "$file"
    done | awk '
        function bytes(n, u,   i, units) {
            split("B KiB MiB GiB TiB PiB EiB", units, " ")
            for (i = 1; i <= 7; i++) if (u == units[i]) return n * 1024 ^ (i - 1)
            return -1
        }
        /\] \[INFO\] running: restic prune/ {
            ts = substr($0, 2, index($0, "]") - 2); remaining = ""; next
        }
        ts != "" && /^[[:space:]]*remaining:/ {
            # remaining:   1234 blobs / 299.123 TiB
            split($0, half, "/"); split(half[2], f, " ")
            remaining = bytes(f[1], f[2]); next
        }
        ts != "" && remaining != "" && /^[[:space:]]*unused size after prune:/ {
            sub(/^[[:space:]]*unused size after prune:[[:space:]]*/, "")
            unused = bytes($1, $2)
            if (remaining >= 0 && unused >= 0) printf "%s\t%.0f\t%.0f\n", ts, remaining, unused
            ts = ""; remaining = ""
        }'
}

# maintenance_logs [all] - the maintenance logs, oldest first: the
# rotated ones (maintenance.log.1, .2.gz... or, with logrotate's
# dateext - RHEL's default - maintenance.log-20261123[.gz]), ordered by
# when they were last written, then the current one. Only the last week
# unless "all": enough to find the latest prune even after a few skipped
# maintenance runs.
maintenance_logs() {
    local rotated=()
    mapfile -t rotated < <(find "$(dirname "$MAINTENANCE_LOG")" -maxdepth 1 -type f \
        \( -name "$(basename "$MAINTENANCE_LOG").[0-9]*" -o -name "$(basename "$MAINTENANCE_LOG")-*" \) \
        -printf '%T@\t%p\n' 2>/dev/null | sort -n | cut -f2-)
    if [[ "${1:-}" != all ]] && (( ${#rotated[@]} > 7 )); then
        rotated=("${rotated[@]: -7}")      # (a negative offset past the start gives nothing: hence the test)
    fi
    printf '%s\n' "${rotated[@]}" "$MAINTENANCE_LOG" | grep -v '^$'
}

# to_epochs - one date per line on stdin -> one epoch second per line
# (an unreadable date gives an empty line, keeping the lines aligned).
to_epochs() {
    local line
    while IFS= read -r line; do
        date -d "$line" +%s 2>/dev/null || echo ""
    done
}

label() {
    local v="${1//\\/\\\\}"
    printf '%s' "${v//\"/\\\"}"
}

declare -A SAMPLES=()
METRIC_ORDER=()
# sample <metric> <labels> <value> [timestamp ms]
sample() {
    local name="$1" labels="$2" value="$3" ts="${4:-}"
    [[ -z "${SAMPLES[$name]+x}" ]] && METRIC_ORDER+=("$name") && SAMPLES[$name]=""
    SAMPLES[$name]+="${name}{${labels}} ${value}${ts:+ $ts}"$'\n'
}

declare -A HELP=(
    [restic_repository_capacity_bytes]="Space granted to the repository (RESTIC_CAPACITY_BYTES)."
    [restic_repository_stored_bytes]="Space the repository takes: data still referenced plus unused, after the last prune."
    [restic_repository_unused_bytes]="Unreferenced data left in the repository after the last prune."
    [restic_repository_measured_timestamp_seconds]="When the prune that measured the repository ran."
    [restic_share_size_bytes]="Logical size of the share at its latest snapshot (summary.total_bytes_processed)."
    [restic_share_added_bytes]="Data the latest snapshot of the share added to the repository (summary.data_added_packed)."
    [restic_share_last_snapshot_timestamp_seconds]="When the latest snapshot of the share was taken."
    [restic_share_changed_bytes]="Data the snapshots of the share added in 24 hours (summary.data_added, before compression)."
    [restic_share_protected_bytes]="Size of the share at the latest of those snapshots (the base of the daily change rate)."
    [restic_capacity_timestamp_seconds]="When the capacity metrics were read."
)

render() {
    local name
    for name in "${METRIC_ORDER[@]}"; do
        printf '# HELP %s %s\n# TYPE %s gauge\n%s' "$name" "${HELP[$name]:-$name}" "$name" "${SAMPLES[$name]}"
    done
}

log_info "===== restic capacity metrics starting (repository: ${REPOSITORY_NAME}) ====="
FAILED=0
REPO_LABEL="repository=\"$(label "$REPOSITORY_NAME")\""

# --- the repository ---------------------------------------------------------

if [[ -n "${RESTIC_CAPACITY_BYTES:-}" ]]; then
    capacity="$(to_bytes "$RESTIC_CAPACITY_BYTES")"
    if [[ -n "$capacity" ]]; then
        sample restic_repository_capacity_bytes "$REPO_LABEL" "$capacity"
    else
        log_error "RESTIC_CAPACITY_BYTES='${RESTIC_CAPACITY_BYTES}' is not a size (e.g. 500TB, 450TiB or bytes)"
        FAILED=1
    fi
else
    log_warn "RESTIC_CAPACITY_BYTES is not set: no capacity, capacity planning will only follow the use"
fi

if (( HISTORY )); then
    mapfile -t logs < <(maintenance_logs all)
    mapfile -t prunes < <(prune_sizes "${logs[@]}")
else
    mapfile -t logs < <(maintenance_logs)
    mapfile -t prunes < <(prune_sizes "${logs[@]}" | tail -n 1)
fi
if (( ${#prunes[@]} == 0 )); then
    log_warn "no prune result in ${MAINTENANCE_LOG}* (restic-maintenance.sh has not run yet, or its prune failed): no repository size"
else
    mapfile -t prune_epochs < <(printf '%s\n' "${prunes[@]}" | cut -f1 | to_epochs)
    for i in "${!prunes[@]}"; do
        IFS=$'\t' read -r _ remaining unused <<<"${prunes[$i]}"
        epoch="${prune_epochs[$i]}"
        [[ -z "$epoch" ]] && continue
        ts=""
        (( HISTORY )) && ts="$(( epoch * 1000 ))"
        sample restic_repository_stored_bytes "$REPO_LABEL" "$(( remaining + unused ))" "$ts"
        sample restic_repository_unused_bytes "$REPO_LABEL" "$unused" "$ts"
    done
    sample restic_repository_measured_timestamp_seconds "$REPO_LABEL" "$epoch"
    log_info "repository: $(( remaining + unused )) bytes stored ($unused unused), measured by the prune of $(date -d "@$epoch" '+%F %T')"
fi

# --- the shares --------------------------------------------------------------

parse_shares_file
declare -A POLICY_OF=()
for i in "${!SHARE_PATHS[@]}"; do
    POLICY_OF["${SHARE_PATHS[$i]}"]="${SHARE_POLICIES[$i]}"
done

# path, time, logical size, data added packed, data added before
# compression - for the snapshots that carry a summary (restic 0.17+;
# older ones have none and are skipped).
if snapshots_json="$(restic snapshots --no-lock "${RESTIC_GLOBAL_ARGS[@]}" --json 2>>"$LOG_FILE")"; then
    mapfile -t rows < <(jq -r '.[]? | select(.summary != null and (.paths | length) > 0)
        | [.paths[0], .time, (.summary.total_bytes_processed // ""),
           (.summary.data_added_packed // .summary.data_added // ""), (.summary.data_added // "")] | @tsv' <<<"$snapshots_json")
    mapfile -t row_epochs < <(printf '%s\n' "${rows[@]}" | cut -f2 | to_epochs)
    declare -A LATEST=()          # path -> index in rows of its latest snapshot
    for i in "${!rows[@]}"; do
        IFS=$'\t' read -r path _ size added _ <<<"${rows[$i]}"
        epoch="${row_epochs[$i]:-}"
        [[ -z "${POLICY_OF[$path]+x}" || -z "$epoch" || -z "$size" ]] && continue
        if (( HISTORY )); then
            sample restic_share_size_bytes "${REPO_LABEL},share=\"$(label "$(basename "$path")")\",policy=\"$(label "${POLICY_OF[$path]}")\"" \
                "$size" "$(( epoch * 1000 ))"
        fi
        if [[ -z "${LATEST[$path]+x}" ]] || (( epoch > ${row_epochs[${LATEST[$path]}]} )); then
            LATEST[$path]="$i"
        fi
    done
    for path in "${SHARE_PATHS[@]}"; do
        if [[ -z "${LATEST[$path]+x}" ]]; then
            log_warn "share $path: no snapshot with a summary yet"
            continue
        fi
        i="${LATEST[$path]}"
        IFS=$'\t' read -r _ _ size added _ <<<"${rows[$i]}"
        labels="${REPO_LABEL},share=\"$(label "$(basename "$path")")\",policy=\"$(label "${POLICY_OF[$path]}")\""
        (( HISTORY )) || sample restic_share_size_bytes "$labels" "$size"
        [[ -n "$added" ]] && sample restic_share_added_bytes "$labels" "$added"
        sample restic_share_last_snapshot_timestamp_seconds "$labels" "${row_epochs[$i]}"
    done
    log_info "shares: ${#LATEST[@]} of ${#SHARE_PATHS[@]} with a snapshot summary"

    # The daily change: per share, what its snapshots added in 24 hours
    # against its size at the latest of them. Now: the last 24 hours.
    # --history: every day, the 24 hours to noon, stamped at noon.
    declare -A CHANGED=() PROTECTED=() PROTECTED_AT=() NOON_OF=()
    now="${RESTIC_CAPACITY_NOW:-$(date +%s)}"                  # (fixed by the tests)
    for i in "${!rows[@]}"; do
        IFS=$'\t' read -r path _ size _ added_raw <<<"${rows[$i]}"
        epoch="${row_epochs[$i]:-}"
        [[ -z "${POLICY_OF[$path]+x}" || -z "$epoch" || -z "$size" || -z "$added_raw" ]] && continue
        if (( HISTORY )); then
            day="$(date -d "@$(( epoch + 43199 ))" +%F)"        # (noon the day before, noon] belongs to that day
            [[ -z "${NOON_OF[$day]+x}" ]] && NOON_OF[$day]="$(date -d "$day 12:00" +%s)"
            key="${path}|${NOON_OF[$day]}"
        else
            (( epoch > now - 86400 )) || continue
            key="${path}|"
        fi
        CHANGED[$key]=$(( ${CHANGED[$key]:-0} + added_raw ))
        if [[ -z "${PROTECTED_AT[$key]+x}" ]] || (( epoch > ${PROTECTED_AT[$key]} )); then
            PROTECTED_AT[$key]="$epoch"
            PROTECTED[$key]="$size"
        fi
    done
    for key in "${!CHANGED[@]}"; do
        path="${key%|*}" noon="${key##*|}"
        labels="${REPO_LABEL},share=\"$(label "$(basename "$path")")\",policy=\"$(label "${POLICY_OF[$path]}")\""
        ts=""
        [[ -n "$noon" ]] && ts="$(( noon * 1000 ))"
        sample restic_share_changed_bytes "$labels" "${CHANGED[$key]}" "$ts"
        sample restic_share_protected_bytes "$labels" "${PROTECTED[$key]}" "$ts"
    done
else
    log_error "restic snapshots failed (see ${LOG_FILE}): no share metrics"
    FAILED=1
fi

sample restic_capacity_timestamp_seconds "$REPO_LABEL" "$(date +%s)"

# --- output -------------------------------------------------------------------

text="$(render)"
if [[ -n "$TEXTFILE" ]]; then
    # node_exporter must never read half a file: write next to it, then rename.
    if ! { tmp="$(mktemp "$(dirname "$TEXTFILE")/.restic-capacity.XXXXXX")" \
            && printf '%s\n' "$text" > "$tmp" && chmod 644 "$tmp" && mv -f "$tmp" "$TEXTFILE"; }; then
        log_error "cannot write $TEXTFILE"
        rm -f "${tmp:-}"
        FAILED=1
    fi
fi
if [[ -n "$PUSH_URL" ]]; then
    curl_args=(-fsS -m 60 --data-binary @- -H 'Content-Type: text/plain')
    [[ -n "${RESTIC_METRICS_PUSH_CA:-}" ]] && curl_args+=(--cacert "$RESTIC_METRICS_PUSH_CA")
    if grep -v '^#' <<<"$text" | curl "${curl_args[@]}" "${PUSH_URL%/}/api/v1/import/prometheus" >>"$LOG_FILE" 2>&1; then
        log_info "pushed $(grep -vc '^#' <<<"$text") samples to ${PUSH_URL}"
    else
        log_error "push to ${PUSH_URL} failed"
        FAILED=1
    fi
fi
if [[ -z "$TEXTFILE" && -z "$PUSH_URL" ]]; then
    printf '%s\n' "$text"
fi

if (( FAILED )); then
    write_status_file capacity-metrics failure "restic capacity metrics incomplete, see ${LOG_FILE}"
    log_info "===== restic capacity metrics finished with errors ====="
    exit 1
fi
write_status_file capacity-metrics success "restic capacity metrics exported"
log_info "===== restic capacity metrics finished ====="
exit 0
