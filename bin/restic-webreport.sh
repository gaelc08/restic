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

# format_duration_hm <seconds-or-empty> -> "1h23m" / "4m05s" / "17s" / "—"
format_duration_hm() {
    local secs="$1" h m s
    if [[ -z "$secs" ]]; then
        printf '\xe2\x80\x94'   # em dash: no backup_start/backup_end on this snapshot
        return
    fi
    h=$(( secs / 3600 ))
    m=$(( (secs % 3600) / 60 ))
    s=$(( secs % 60 ))
    if (( h > 0 )); then
        printf '%dh%02dm' "$h" "$m"
    elif (( m > 0 )); then
        printf '%dm%02ds' "$m" "$s"
    else
        printf '%ds' "$s"
    fi
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

# share_snapshot_durations <path> - short_id -> backup duration in
# seconds, one "id<TAB>seconds" line per snapshot that actually has
# the data. Needs --json: the plain text table has no duration
# column at all. Only backup_start/backup_end (restic's own "snapshot
# summary", not on every historical snapshot - same gap as the Size
# column above, which comes from the same summary) are used; jq's own
# date parsing can't handle RFC3339 offsets/fractional seconds
# reliably, so the two timestamps are handed to `date -d` instead,
# which does.
share_snapshot_durations() {
    local path="$1" short_id start end start_epoch end_epoch
    while IFS=$'\t' read -r short_id start end; do
        [[ -z "$short_id" || -z "$start" || -z "$end" ]] && continue
        start_epoch="$(date -d "$start" +%s 2>/dev/null)" || continue
        end_epoch="$(date -d "$end" +%s 2>/dev/null)" || continue
        printf '%s\t%d\n' "$short_id" "$(( end_epoch - start_epoch ))"
    done < <(restic snapshots "${RESTIC_GLOBAL_ARGS[@]}" --path "$path" --json 2>>"$LOG_FILE" \
        | jq -r '.[]? | [.short_id, (.summary.backup_start // ""), (.summary.backup_end // "")] | @tsv' 2>>"$LOG_FILE")
}

parse_shares_file

SECTIONS=""
for i in "${!SHARE_PATHS[@]}"; do
    path="${SHARE_PATHS[$i]}"
    policy="${SHARE_POLICIES[$i]}"
    share_name="$(basename "$path")"

    table="$(share_snapshots_table "$path")"
    rows="$(share_table_to_rows "$table")"

    declare -A DURATIONS=()
    while IFS=$'\t' read -r dur_id dur_secs; do
        [[ -n "$dur_id" ]] && DURATIONS["$dur_id"]="$dur_secs"
    done < <(share_snapshot_durations "$path")

    if [[ -z "$rows" ]]; then
        body="<p class=\"empty\">No snapshots found for this share.</p>"
    else
        body='<table><thead><tr><th>Date</th><th>ID</th><th>Tags</th><th>Size</th><th>Duration</th></tr></thead><tbody>'
        while IFS=$'\t' read -r id time tags size; do
            dur_secs="${DURATIONS[$id]:-}"
            dur_display="$(format_duration_hm "$dur_secs")"
            id="$(printf '%s' "$id" | html_escape)"
            time="$(printf '%s' "$time" | html_escape)"
            tags="$(printf '%s' "$tags" | html_escape)"
            size="$(printf '%s' "$size" | html_escape)"
            body+="<tr><td>${time}</td><td class=\"id\">${id}</td><td class=\"tags\">${tags}</td><td class=\"size\">${size}</td><td class=\"duration\" data-seconds=\"${dur_secs}\">${dur_display}</td></tr>"
        done <<<"$rows"
        body+='</tbody></table>'
    fi

    count="$(printf '%s\n' "$rows" | grep -c . || true)"
    # rows are newest-first (share_table_to_rows reverses restic's own
    # oldest-first output), so the first row's time is the latest backup.
    latest_time=""
    [[ -n "$rows" ]] && latest_time="$(printf '%s\n' "$rows" | head -n1 | cut -f2)"

    SECTIONS+="<section data-name=\"$(printf '%s' "$share_name" | html_escape)\" data-count=\"${count}\" data-latest=\"$(printf '%s' "$latest_time" | html_escape)\"><h2>$(printf '%s' "$share_name" | html_escape) <span class=\"meta\">policy: $(printf '%s' "$policy" | html_escape) &middot; ${count} snapshot(s) &middot; $(printf '%s' "$path" | html_escape)</span></h2>${body}</section>"
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
  .sub { color: #777; font-size: .85rem; margin-bottom: 1rem; }
  .toolbar { display: flex; flex-wrap: wrap; align-items: center; gap: .75rem; margin-bottom: 1.5rem; }
  .toolbar input[type="search"] { flex: 1 1 16rem; padding: .45rem .6rem; font-size: .9rem; border: 1px solid #ccc; border-radius: 6px; background: white; color: inherit; }
  .toolbar label { font-size: .85rem; color: #666; display: flex; align-items: center; gap: .4rem; }
  .toolbar select { padding: .35rem .5rem; font-size: .85rem; border: 1px solid #ccc; border-radius: 6px; background: white; color: inherit; }
  @media (prefers-color-scheme: dark) {
    .toolbar input[type="search"], .toolbar select { background: #262626; border-color: #3a3a3a; }
    .toolbar label { color: #999; }
  }
  section { background: white; border-radius: 8px; padding: 1rem 1.25rem; margin-bottom: 1rem; box-shadow: 0 1px 3px rgba(0,0,0,.1); }
  @media (prefers-color-scheme: dark) { section { background: #262626; box-shadow: none; border: 1px solid #3a3a3a; } }
  section.hidden { display: none; }
  h2 { font-size: 1.05rem; margin: 0 0 .75rem; display: flex; flex-wrap: wrap; align-items: baseline; gap: .5rem; }
  .meta { font-size: .8rem; font-weight: normal; color: #888; }
  table { border-collapse: collapse; width: 100%; font-size: .85rem; }
  th, td { text-align: left; padding: .3rem .6rem; border-bottom: 1px solid #e0e0e0; }
  @media (prefers-color-scheme: dark) { th, td { border-bottom: 1px solid #3a3a3a; } }
  th { color: #888; font-weight: 600; font-size: .75rem; text-transform: uppercase; cursor: pointer; user-select: none; white-space: nowrap; }
  th:hover { color: #555; }
  @media (prefers-color-scheme: dark) { th:hover { color: #ccc; } }
  th.sort-asc::after { content: " \25B2"; }
  th.sort-desc::after { content: " \25BC"; }
  td.id, td.tags { font-family: ui-monospace, SFMono-Regular, Consolas, monospace; font-size: .8rem; color: #555; }
  @media (prefers-color-scheme: dark) { td.id, td.tags { color: #aaa; } }
  td.size, td.duration { text-align: right; white-space: nowrap; }
  tr.hidden { display: none; }
  .empty { color: #999; font-style: italic; margin: 0; }
  footer { color: #999; font-size: .75rem; margin-top: 1.5rem; }
</style>
</head>
<body>
<h1>restic snapshots - $(printf '%s' "$host" | html_escape)</h1>
<p class="sub">Generated ${generated_at} - refreshes automatically on a timer, reload to see the latest</p>
<div class="toolbar">
  <input type="search" id="search" placeholder="Rechercher (share, tag, date, ID)..." autocomplete="off">
  <label>Trier les shares par
    <select id="shareSort">
      <option value="name">nom</option>
      <option value="count">nombre de snapshots</option>
      <option value="latest">dernier backup</option>
    </select>
  </label>
</div>
<main id="shares">
${SECTIONS}
</main>
<footer>Metadata only - never reads archived Glacier pack data. Generated by restic-webreport.sh.</footer>
<script>
(function () {
  "use strict";

  var SIZE_UNITS = { "B": 1, "KiB": 1024, "MiB": 1024 * 1024, "GiB": 1024 * 1024 * 1024, "TiB": Math.pow(1024, 4), "PiB": Math.pow(1024, 5) };

  function parseSize(text) {
    var m = /^([\d.]+)\s*([KMGTP]?iB|B)$/.exec(text.trim());
    if (!m) { return 0; }
    return parseFloat(m[1]) * (SIZE_UNITS[m[2]] || 1);
  }

  // Duration cells carry the exact seconds in data-seconds (restic's
  // own "1h23m"/"4m05s" text isn't reliably sortable as a string -
  // same reasoning as Size's byte parsing below, simpler here since
  // the number is already computed server-side).
  function cellSortValue(cell, mode) {
    if (mode === "size") { return parseSize(cell.textContent.trim()); }
    if (mode === "duration") { return parseFloat(cell.dataset.seconds || "0") || 0; }
    return cell.textContent.trim();
  }

  function sortRowsByColumn(table, colIndex, mode, ascending) {
    var tbody = table.tBodies[0];
    if (!tbody) { return; }
    var rows = Array.prototype.slice.call(tbody.rows);
    rows.sort(function (a, b) {
      var av = cellSortValue(a.cells[colIndex], mode);
      var bv = cellSortValue(b.cells[colIndex], mode);
      var cmp = (mode === "size" || mode === "duration")
        ? av - bv
        : av.localeCompare(bv, undefined, { numeric: true, sensitivity: "base" });
      return ascending ? cmp : -cmp;
    });
    rows.forEach(function (row) { tbody.appendChild(row); });
  }

  Array.prototype.forEach.call(document.querySelectorAll("table"), function (table) {
    var ths = Array.prototype.slice.call(table.querySelectorAll("th"));
    ths.forEach(function (th, colIndex) {
      th.addEventListener("click", function () {
        var ascending = th.dataset.sortDir !== "asc";
        ths.forEach(function (other) { other.classList.remove("sort-asc", "sort-desc"); other.dataset.sortDir = ""; });
        th.dataset.sortDir = ascending ? "asc" : "desc";
        th.classList.add(ascending ? "sort-asc" : "sort-desc");
        var headerText = th.textContent.trim().toLowerCase();
        var mode = headerText.indexOf("size") !== -1
          ? "size"
          : (headerText.indexOf("duration") !== -1 ? "duration" : "text");
        sortRowsByColumn(table, colIndex, mode, ascending);
      });
    });
  });

  var searchInput = document.getElementById("search");
  if (searchInput) {
    searchInput.addEventListener("input", function () {
      var q = searchInput.value.trim().toLowerCase();
      Array.prototype.forEach.call(document.querySelectorAll("#shares > section"), function (section) {
        var shareNameMatches = (section.dataset.name || "").toLowerCase().indexOf(q) !== -1;
        var anyRowVisible = false;
        Array.prototype.forEach.call(section.querySelectorAll("tbody tr"), function (row) {
          var match = q === "" || shareNameMatches || row.textContent.toLowerCase().indexOf(q) !== -1;
          row.classList.toggle("hidden", !match);
          if (match) { anyRowVisible = true; }
        });
        section.classList.toggle("hidden", !(q === "" || shareNameMatches || anyRowVisible));
      });
    });
  }

  var shareSort = document.getElementById("shareSort");
  var sharesContainer = document.getElementById("shares");
  if (shareSort && sharesContainer) {
    shareSort.addEventListener("change", function () {
      var key = shareSort.value;
      var sections = Array.prototype.slice.call(sharesContainer.querySelectorAll("section"));
      sections.sort(function (a, b) {
        if (key === "count") {
          return (parseInt(b.dataset.count, 10) || 0) - (parseInt(a.dataset.count, 10) || 0);
        }
        if (key === "latest") {
          return (b.dataset.latest || "").localeCompare(a.dataset.latest || "");
        }
        return (a.dataset.name || "").localeCompare(b.dataset.name || "", undefined, { sensitivity: "base" });
      });
      sections.forEach(function (section) { sharesContainer.appendChild(section); });
    });
  }
})();
</script>
</body>
</html>
REPORTEOF

mv "$OUTPUT_FILE" "${OUTPUT_DIR}/index.html"
chmod 644 "${OUTPUT_DIR}/index.html"

log_info "===== restic web report finished (${#SHARE_PATHS[@]} share(s)) ====="
