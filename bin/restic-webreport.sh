#!/usr/bin/env bash
# Regenerates a single static HTML page listing every configured
# share's snapshot history, grouped by share - a live web page, not a
# file to download. bin/install-webreport.sh (or install.sh) installs
# a tiny unprivileged web server (systemd/restic-webserver.service)
# that just serves whatever this script last wrote; this script itself
# runs as root, on a timer (systemd/restic-webreport.timer), the same
# way restic-report.sh does, and never needs to be network-reachable
# itself.
#
# Why this exists instead of just using Backrest's own snapshot
# browser: Backrest can only group/display snapshots it created itself
# through one of its own "Plans" - it has no way to retroactively
# associate the snapshots this automation already created (confirmed
# empirically: a schedule-disabled Plan with a matching path still
# showed "No backups yet"). This script instead reuses the exact same
# `restic snapshots --path <share>` grouping `resticctl list` already
# does correctly, just rendered as HTML instead of a terminal table.
#
# Only reads fast repository metadata (`restic snapshots`), never
# archived pack data - safe to run frequently.

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/restic-common.sh"

LOG_FILE="${WEBREPORT_LOG_FILE:-${LOG_DIR}/webreport.log}"
OUTPUT_DIR="${RESTIC_WEBREPORT_DIR:-/var/lib/restic-webreport}"

log_info "===== restic web report starting ====="

mkdir -p "$OUTPUT_DIR"

host="$(hostname -f 2>/dev/null || hostname)"
generated_at="$(date '+%Y-%m-%d %H:%M %Z')"

# html_escape - minimal &/</> escaping for values dropped into HTML.
html_escape() {
    sed -e 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'
}

# share_snapshots_table <path> - this share's full snapshot history, in
# restic's own fixed-width table (ID, Time, Host, Tags, Paths, Size
# columns), newest first. Same approach as restic-report.sh's
# build_shares_table: read restic's own formatted text table rather
# than --json, since not every historical snapshot necessarily has the
# newer JSON "summary" stats populated, while the formatted Size
# column is always there.
share_snapshots_table() {
    local path="$1"
    restic snapshots "${RESTIC_GLOBAL_ARGS[@]}" --path "$path" 2>>"$LOG_FILE" \
        | grep -E '^(ID[[:space:]]|[0-9a-f]{8}[[:space:]])'
}

# share_table_to_rows <table> - restic's text table -> tab-separated
# (id, time, tags, size) rows, newest first. Mirrors restic-report.sh's
# column-splitting (safe here: none of these fields ever contain two
# consecutive spaces, only restic's own inter-column padding does).
share_table_to_rows() {
    local table="$1"
    printf '%s\n' "$table" \
        | awk -F'  +' 'NR==1{next} NF>=6{print $1"\t"$2"\t"$4"\t"$6}' \
        | tac
}

parse_shares_file

SECTIONS=""
for i in "${!SHARE_PATHS[@]}"; do
    path="${SHARE_PATHS[$i]}"
    policy="${SHARE_POLICIES[$i]}"
    share_name="$(basename "$path")"

    table="$(share_snapshots_table "$path")"
    rows="$(share_table_to_rows "$table")"

    if [[ -z "$rows" ]]; then
        body="<p class=\"empty\">No snapshots found for this share.</p>"
    else
        body='<table><thead><tr><th>Date</th><th>ID</th><th>Tags</th><th>Size</th></tr></thead><tbody>'
        while IFS=$'\t' read -r id time tags size; do
            id="$(printf '%s' "$id" | html_escape)"
            time="$(printf '%s' "$time" | html_escape)"
            tags="$(printf '%s' "$tags" | html_escape)"
            size="$(printf '%s' "$size" | html_escape)"
            body+="<tr><td>${time}</td><td class=\"id\">${id}</td><td class=\"tags\">${tags}</td><td class=\"size\">${size}</td></tr>"
        done <<<"$rows"
        body+='</tbody></table>'
    fi

    count="$(printf '%s\n' "$rows" | grep -c . || true)"
    SECTIONS+="<section><h2>$(printf '%s' "$share_name" | html_escape) <span class=\"meta\">policy: $(printf '%s' "$policy" | html_escape) &middot; ${count} snapshot(s) &middot; $(printf '%s' "$path" | html_escape)</span></h2>${body}</section>"
done

if [[ -z "$SECTIONS" ]]; then
    SECTIONS="<p>No shares configured, or shares.conf could not be read - see ${LOG_FILE}.</p>"
fi

OUTPUT_FILE="${OUTPUT_DIR}/index.html.tmp"
cat > "$OUTPUT_FILE" <<REPORTEOF
<!doctype html>
<html lang="fr">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>restic snapshots - $(printf '%s' "$host" | html_escape)</title>
<style>
  :root { color-scheme: light dark; }
  body { font-family: -apple-system, Segoe UI, Helvetica, Arial, sans-serif; margin: 0; padding: 1.5rem; background: #f5f5f5; color: #222; }
  @media (prefers-color-scheme: dark) { body { background: #1a1a1a; color: #e4e4e4; } }
  h1 { font-size: 1.3rem; margin: 0 0 .25rem; }
  .sub { color: #777; font-size: .85rem; margin-bottom: 1.5rem; }
  section { background: white; border-radius: 8px; padding: 1rem 1.25rem; margin-bottom: 1rem; box-shadow: 0 1px 3px rgba(0,0,0,.1); }
  @media (prefers-color-scheme: dark) { section { background: #262626; box-shadow: none; border: 1px solid #3a3a3a; } }
  h2 { font-size: 1.05rem; margin: 0 0 .75rem; display: flex; flex-wrap: wrap; align-items: baseline; gap: .5rem; }
  .meta { font-size: .8rem; font-weight: normal; color: #888; }
  table { border-collapse: collapse; width: 100%; font-size: .85rem; }
  th, td { text-align: left; padding: .3rem .6rem; border-bottom: 1px solid #e0e0e0; }
  @media (prefers-color-scheme: dark) { th, td { border-bottom: 1px solid #3a3a3a; } }
  th { color: #888; font-weight: 600; font-size: .75rem; text-transform: uppercase; }
  td.id, td.tags { font-family: ui-monospace, SFMono-Regular, Consolas, monospace; font-size: .8rem; color: #555; }
  @media (prefers-color-scheme: dark) { td.id, td.tags { color: #aaa; } }
  td.size { text-align: right; white-space: nowrap; }
  .empty { color: #999; font-style: italic; margin: 0; }
  footer { color: #999; font-size: .75rem; margin-top: 1.5rem; }
</style>
</head>
<body>
<h1>restic snapshots - $(printf '%s' "$host" | html_escape)</h1>
<p class="sub">Generated ${generated_at} - refreshes automatically on a timer, reload to see the latest</p>
${SECTIONS}
<footer>Metadata only - never reads archived Glacier pack data. Generated by restic-webreport.sh.</footer>
</body>
</html>
REPORTEOF

mv "$OUTPUT_FILE" "${OUTPUT_DIR}/index.html"
chmod 644 "${OUTPUT_DIR}/index.html"

log_info "===== restic web report finished (${#SHARE_PATHS[@]} share(s)) ====="
