#!/usr/bin/env bash
# Daily backup report: one HTML table with the latest snapshot of
# every configured share, emailed out.
#
# This is a backup report, not a server-health digest - it does not
# cover backup/maintenance/verify job status (that's what the
# RESTIC_NOTIFY_* failure alerts and RESTIC_STATUS_DIR status files
# are for; see README.md). It only reads fast repository metadata
# (`restic snapshots`) - never archived pack data - so it's safe to
# run on a daily schedule (see systemd/restic-report.timer).
#
# The table is sent as HTML, not plain text with space-padded columns:
# most mail clients don't render plain text in a monospace font, so a
# space-aligned table looks fine in a terminal (or in this script's
# own log file) but skewed in an inbox. A real <table> aligns
# correctly regardless of font. The Host column is left out of the
# email - this report only ever covers one host, so repeating it on
# every row is noise (see the log file / report heading instead).
#
# Recipient: RESTIC_REPORT_EMAIL, falling back to RESTIC_NOTIFY_EMAIL
# if unset. If neither is set, the report is still generated and
# logged, just not emailed.

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/restic-common.sh"

LOG_FILE="${REPORT_LOG_FILE:-${LOG_DIR}/report.log}"
RECIPIENT="${RESTIC_REPORT_EMAIL:-${RESTIC_NOTIFY_EMAIL:-}}"

log_info "===== restic daily report starting ====="

host="$(hostname -f 2>/dev/null || hostname)"
today="$(date '+%Y-%m-%d %H:%M %Z')"

# build_shares_table - one flat, aligned table with the latest snapshot
# of each configured share, in restic's native ungrouped format (ID,
# Time, Host, Tags, Paths, Size columns). --group-by can't give us this
# directly (it never prints a Paths column), so instead we look up each
# share's latest snapshot ID individually, then pass all of those IDs
# to a single `restic snapshots <id1> <id2> ...` call - restic renders
# them as one properly-aligned table, with correctly computed/formatted
# sizes we don't have to reimplement.
#
# Runs in a subshell via the caller's $(...): if parse_shares_file hits
# a config error it calls die() (log + exit 1), which only unwinds this
# subshell, so a bad shares.conf can't take down the whole report.
#
# restic's own table has a header, a footer ("N snapshots", "Timestamps
# shown in ...") and (on newer restic) separator rules around the rows -
# not something we want to forward. We grep down to just the header
# line and the data rows, each of which starts with an 8-hex-digit
# short ID; shares_table_to_html() below then reads this text table
# (not restic's JSON - its exact field names/units for "size" aren't
# something to depend on) to build the HTML rows.
build_shares_table() {
    if ! command -v jq >/dev/null 2>&1; then
        echo "jq is not installed - cannot build the per-share snapshot table."
        return
    fi

    parse_shares_file

    local ids=() path id
    for path in "${SHARE_PATHS[@]}"; do
        id="$(restic snapshots "${RESTIC_GLOBAL_ARGS[@]}" --path "$path" --json --latest 1 2>>"$LOG_FILE" \
            | jq -r '.[0].short_id // empty')"
        [[ -n "$id" ]] && ids+=("$id")
    done

    if [[ ${#ids[@]} -eq 0 ]]; then
        echo "No snapshots found for any configured share."
        return
    fi

    restic snapshots "${RESTIC_GLOBAL_ARGS[@]}" "${ids[@]}" 2>>"$LOG_FILE" \
        | grep -E '^(ID[[:space:]]|[0-9a-f]{8}[[:space:]])'
}

# html_escape - minimal &/</> escaping for values dropped into HTML.
html_escape() {
    sed -e 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'
}

# shares_table_to_html <table> - renders build_shares_table's output
# (ID, Time, Host, Tags, Paths, Size columns, restic's own fixed-width
# alignment) as an HTML <table>, dropping the Host column. Splits each
# line on runs of 2+ spaces, which is safe here: none of ID/Time/Tags/
# Paths/Size ever contain two consecutive spaces themselves, only
# restic's inter-column padding does. If the input isn't a real table
# (e.g. the "jq is not installed"/"no snapshots" fallback lines from
# build_shares_table, or a share with no tags shifting the column
# count), falls back to showing it as plain escaped text.
shares_table_to_html() {
    local table="$1"
    local rows
    rows="$(printf '%s\n' "$table" | awk -F'  +' 'NR==1{next} NF>=6{print $1"\t"$2"\t"$4"\t"$5"\t"$6}')"

    if [[ -z "$rows" ]]; then
        printf '<p>%s</p>\n' "$(printf '%s' "$table" | html_escape)"
        return
    fi

    cat <<'HTMLHEAD'
<table cellspacing="0" cellpadding="6" style="border-collapse:collapse;font-family:monospace,monospace;font-size:13px;">
<tr style="background:#eeeeee;text-align:left;">
<th style="border:1px solid #cccccc;">ID</th>
<th style="border:1px solid #cccccc;">Time</th>
<th style="border:1px solid #cccccc;">Tags</th>
<th style="border:1px solid #cccccc;">Paths</th>
<th style="border:1px solid #cccccc;">Size</th>
</tr>
HTMLHEAD

    local id time tags paths size
    while IFS=$'\t' read -r id time tags paths size; do
        id="$(printf '%s' "$id" | html_escape)"
        time="$(printf '%s' "$time" | html_escape)"
        tags="$(printf '%s' "$tags" | html_escape)"
        paths="$(printf '%s' "$paths" | html_escape)"
        size="$(printf '%s' "$size" | html_escape)"
        cat <<HTMLROW
<tr>
<td style="border:1px solid #cccccc;">${id}</td>
<td style="border:1px solid #cccccc;">${time}</td>
<td style="border:1px solid #cccccc;">${tags}</td>
<td style="border:1px solid #cccccc;">${paths}</td>
<td style="border:1px solid #cccccc;">${size}</td>
</tr>
HTMLROW
    done <<<"$rows"

    echo "</table>"
}

SHARES_TABLE="$(build_shares_table)"
[[ -z "$SHARES_TABLE" ]] && SHARES_TABLE="Unable to read shares.conf, or no snapshots found - see ${LOG_FILE}."
SHARES_HTML="$(shares_table_to_html "$SHARES_TABLE")"

# Logged as plain text (readable with tail/less), independent of the
# HTML actually emailed.
printf 'Daily restic report - %s - %s\n\nLatest snapshot per share:\n\n%s\n' \
    "$host" "$today" "$SHARES_TABLE" >>"$LOG_FILE"

BODY_HTML="$(cat <<REPORTEOF
<html><body style="font-family:Arial,Helvetica,sans-serif;font-size:14px;color:#222222;">
<p>Daily restic report - <b>$(printf '%s' "$host" | html_escape)</b> - $(printf '%s' "$today" | html_escape)</p>
<p>Latest snapshot per share:</p>
${SHARES_HTML}
<p style="color:#888888;font-size:12px;">Automatically generated by restic-report.sh on $(printf '%s' "$host" | html_escape).</p>
</body></html>
REPORTEOF
)"

if [[ -n "$RECIPIENT" ]]; then
    if send_email "$RECIPIENT" "[restic] daily report - ${host}" "$BODY_HTML" "text/html; charset=utf-8"; then
        log_info "report emailed to $RECIPIENT"
    else
        log_error "===== restic daily report finished with an email delivery failure ====="
        exit 1
    fi
else
    log_info "no RESTIC_REPORT_EMAIL or RESTIC_NOTIFY_EMAIL configured - report generated but not emailed"
fi

log_info "===== restic daily report finished ====="
exit 0
