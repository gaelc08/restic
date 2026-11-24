#!/usr/bin/env bash
# End-to-end test of bin/restic-capacity-metrics.sh, without a
# repository: a fake `restic` (snapshots --json) and a fake `curl`
# (records what is pushed) on PATH, maintenance logs written by hand.
# Needs bash, jq, gzip, GNU date. Run: tests/test-capacity-metrics.sh

set -uo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." &>/dev/null && pwd)"
SCRIPT="${REPO_DIR}/bin/restic-capacity-metrics.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FAILURES=0
check() {   # check <description> <command...>
    local what="$1"; shift
    if "$@"; then
        echo "ok   - $what"
    else
        echo "FAIL - $what"
        FAILURES=$((FAILURES + 1))
    fi
}
has() { grep -qxF -- "$2" <<<"$1"; }
lacks() { ! grep -qF -- "$2" <<<"$1"; }

mkdir -p "$WORK/bin" "$WORK/log" "$WORK/etc"
cat > "$WORK/etc/restic.env" <<EOF
RESTIC_REPOSITORY="s3:https://scrat-1.ctie.etat.lu/backup/shares"
RESTIC_SECRETS_FILE="$WORK/etc/secrets.env"
RESTIC_CACHE_DIR="$WORK/cache"
RESTIC_TMP_DIR="$WORK/tmp"
LOG_DIR="$WORK/log"
RESTIC_LOCK_FILE="$WORK/run/restic.lock"
RESTIC_STATUS_DIR="$WORK/status"
SHARES_FILE="$WORK/etc/shares.conf"
RETENTION_POLICIES_FILE="$WORK/etc/retention-policies.conf"
RESTIC_CAPACITY_BYTES="500TB"
EOF
echo 'RESTIC_PASSWORD=x' > "$WORK/etc/secrets.env"
printf '%s\n' "/mnt/act_geoportal   long" "/mnt/ctie_sap        short" "/mnt/new-share       short" > "$WORK/etc/shares.conf"
printf '%s\n' "short 30 0 0 0" "long 7 8 24 7" > "$WORK/etc/retention-policies.conf"

# Fake restic: snapshots of two shares (one without a summary, as
# snapshots made before restic 0.17), and one of a share no longer configured.
cat > "$WORK/bin/restic" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == snapshots && " $* " == *" --no-lock "* && " $* " == *" --json "* ]] || { echo "unexpected: restic $*" >&2; exit 3; }
[[ -n "${FAKE_RESTIC_FAIL:-}" ]] && exit 1
cat <<'JSON'
[
 {"short_id":"a1","time":"2026-11-20T01:00:05.123456789+01:00","paths":["/mnt/act_geoportal"],
  "summary":{"total_bytes_processed":1000,"data_added_packed":10}},
 {"short_id":"a2","time":"2026-11-21T01:00:05+01:00","paths":["/mnt/act_geoportal"],
  "summary":{"total_bytes_processed":1100,"data_added_packed":20,"data_added":40}},
 {"short_id":"a0","time":"2026-11-19T01:00:05+01:00","paths":["/mnt/act_geoportal"]},
 {"short_id":"b1","time":"2026-11-21T02:00:00+01:00","paths":["/mnt/ctie_sap"],
  "summary":{"total_bytes_processed":5000,"data_added":70}},
 {"short_id":"c1","time":"2026-11-21T02:00:00+01:00","paths":["/mnt/gone"],
  "summary":{"total_bytes_processed":9,"data_added_packed":9}}
]
JSON
EOF
# Fake curl: stores the pushed body and the URL.
cat > "$WORK/bin/curl" <<EOF
#!/usr/bin/env bash
cat > "$WORK/pushed"
printf '%s\n' "\${@: -1}" > "$WORK/pushed-url"
EOF
chmod +x "$WORK/bin/restic" "$WORK/bin/curl"

prune_run() {   # prune_run <log timestamp> <remaining> <unused>
    printf '[%s] [INFO] running: restic prune --pack-size 64\nloading indexes...\n\nto repack:            0 blobs / 0 B\nremaining:         1234 blobs / %s\nunused size after prune: %s (0.01%% of remaining size)\n[%s] [INFO] prune completed successfully\n' \
        "$1" "$2" "$3" "$1"
}
prune_run "2026-11-19 18:00:05+0100" "100.000 TiB" "1.000 GiB" | gzip > "$WORK/log/maintenance.log.2.gz"
prune_run "2026-11-20 18:00:05+0100" "101.000 TiB" "2.000 GiB" > "$WORK/log/maintenance.log.1"
{ prune_run "2026-11-21 18:00:05+0100" "102.500 TiB" "0 B"
  printf '[2026-11-22 18:00:05+0100] [INFO] running: restic prune\n[2026-11-22 18:00:09+0100] [ERROR] prune FAILED (exit 1)\n'
} > "$WORK/log/maintenance.log"

run() { env PATH="$WORK/bin:$PATH" RESTIC_ENV_FILE="$WORK/etc/restic.env" "$@" "$SCRIPT" "${ARGS[@]}"; }

# --- print -------------------------------------------------------------------
ARGS=(--print)
out="$(run 2>"$WORK/stderr")"; rc=$?
R='repository="scrat-1.ctie.etat.lu/backup/shares"'
check "print exits 0" test "$rc" -eq 0
check "capacity from RESTIC_CAPACITY_BYTES (decimal TB)" has "$out" "restic_repository_capacity_bytes{$R} 500000000000000"
check "repository size = remaining + unused of the last successful prune" \
    has "$out" "restic_repository_stored_bytes{$R} $(( 1025 * 1024 ** 4 / 10 ))"
check "measured at that prune" has "$out" "restic_repository_measured_timestamp_seconds{$R} $(date -d '2026-11-21 18:00:05+0100' +%s)"
check "latest snapshot of a share" has "$out" "restic_share_size_bytes{$R,share=\"act_geoportal\",policy=\"long\"} 1100"
check "data_added_packed preferred" has "$out" "restic_share_added_bytes{$R,share=\"act_geoportal\",policy=\"long\"} 20"
check "data_added when no packed size" has "$out" "restic_share_added_bytes{$R,share=\"ctie_sap\",policy=\"short\"} 70"
check "snapshot time" has "$out" "restic_share_last_snapshot_timestamp_seconds{$R,share=\"ctie_sap\",policy=\"short\"} $(date -d '2026-11-21T02:00:00+01:00' +%s)"
check "share no longer configured left out" lacks "$out" 'share="gone"'
check "HELP and TYPE" has "$out" "# TYPE restic_share_size_bytes gauge"
check "no timestamps outside --history" lacks "$out" "} 1100 "
check "logs on stderr, not in the metrics" lacks "$out" "[INFO]"
check "share without snapshot reported" grep -q "share /mnt/new-share: no snapshot with a summary yet" "$WORK/stderr"
check "status file" grep -q "STATUS=success" "$WORK/status/capacity-metrics.status"

# --- daily change: the last 24 hours --------------------------------------------
ARGS=(--print)
out="$(run RESTIC_CAPACITY_NOW="$(date -d '2026-11-21T12:00:00+01:00' +%s)" 2>/dev/null)"
check "change: data_added of the snapshots of the last 24 hours" \
    has "$out" "restic_share_changed_bytes{$R,share=\"act_geoportal\",policy=\"long\"} 40"
check "change: against the size at the latest of them" \
    has "$out" "restic_share_protected_bytes{$R,share=\"act_geoportal\",policy=\"long\"} 1100"
check "change: every share with a snapshot in the window" \
    has "$out" "restic_share_changed_bytes{$R,share=\"ctie_sap\",policy=\"short\"} 70"
check "change: no timestamp now" lacks "$out" "restic_share_changed_bytes{$R,share=\"ctie_sap\",policy=\"short\"} 70 "
out="$(run RESTIC_CAPACITY_NOW="$(date -d '2026-11-25T12:00:00+01:00' +%s)" 2>/dev/null)"
check "change: nothing when no snapshot in the last 24 hours" lacks "$out" "restic_share_changed_bytes"

# --- history (push) ----------------------------------------------------------
ARGS=(--history)
run RESTIC_METRICS_PUSH_URL="http://127.0.0.1:8428/" 2>/dev/null; rc=$?
pushed="$(cat "$WORK/pushed")"
check "history push exits 0" test "$rc" -eq 0
check "pushed to the import endpoint" grep -qxF "http://127.0.0.1:8428/api/v1/import/prometheus" "$WORK/pushed-url"
check "no comments pushed" lacks "$pushed" "# "
check "every prune, rotated and compressed logs included" \
    test "$(grep -c '^restic_repository_stored_bytes{' <<<"$pushed")" -eq 3
check "oldest prune, with its timestamp in ms" \
    has "$pushed" "restic_repository_stored_bytes{$R} $(( 100 * 1024 ** 4 + 1024 ** 3 )) $(( $(date -d '2026-11-19 18:00:05+0100' +%s) * 1000 ))"
check "every snapshot with a summary" test "$(grep -c '^restic_share_size_bytes{' <<<"$pushed")" -eq 3
check "history: the daily change of a day, stamped at its noon" \
    has "$pushed" "restic_share_changed_bytes{$R,share=\"ctie_sap\",policy=\"short\"} 70 $(( $(date -d '2026-11-21 12:00' +%s) * 1000 ))"
check "history: a snapshot without data_added gives no change" \
    test "$(grep -c '^restic_share_changed_bytes{.*act_geoportal' <<<"$pushed")" -eq 1
check "fractional seconds in the snapshot time" \
    has "$pushed" "restic_share_size_bytes{$R,share=\"act_geoportal\",policy=\"long\"} 1000 $(( $(date -d '2026-11-20T01:00:05+01:00' +%s) * 1000 ))"

# --- errors ------------------------------------------------------------------
ARGS=(--print)
out="$(run FAKE_RESTIC_FAIL=1 2>/dev/null)"; rc=$?
check "failing restic snapshots: exit 1" test "$rc" -eq 1
check "...the repository size is still exported" grep -q "^restic_repository_stored_bytes{" <<<"$out"
check "...status failure" grep -q "STATUS=failure" "$WORK/status/capacity-metrics.status"
ARGS=(--history)
run RESTIC_METRICS_TEXTFILE="$WORK/x.prom" >/dev/null 2>&1; rc=$?
check "--history refuses the textfile collector" test "$rc" -eq 1
ARGS=()
run RESTIC_METRICS_TEXTFILE="$WORK/restic.prom" 2>/dev/null; rc=$?
check "textfile written" grep -q "^restic_share_size_bytes{" "$WORK/restic.prom"

# --- logrotate's dateext (RHEL's default): maintenance.log-YYYYMMDD[.gz] ------
mv "$WORK/log/maintenance.log.2.gz" "$WORK/log/maintenance.log-20261120.gz"
mv "$WORK/log/maintenance.log.1" "$WORK/log/maintenance.log-20261121"
touch -d '2026-11-20 03:00' "$WORK/log/maintenance.log-20261120.gz"
touch -d '2026-11-21 03:00' "$WORK/log/maintenance.log-20261121"
prune_run "2026-11-21 18:00:05+0100" "102.500 TiB" "0 B" >> "$WORK/log/maintenance.log-20261121"
printf '[2026-11-22 10:00:00+0100] [INFO] no prune yet today\n' > "$WORK/log/maintenance.log"
ARGS=(--print)
out="$(run 2>/dev/null)"
check "dateext: the latest prune found in a rotated log" \
    has "$out" "restic_repository_stored_bytes{$R} $(( 1025 * 1024 ** 4 / 10 ))"
ARGS=(--history)
run RESTIC_METRICS_PUSH_URL="http://127.0.0.1:8428" 2>/dev/null
check "dateext: every prune, oldest compressed log included" \
    test "$(grep -c '^restic_repository_stored_bytes{' "$WORK/pushed")" -eq 3

echo
if (( FAILURES )); then
    echo "$FAILURES test(s) failed"
    exit 1
fi
echo "all tests passed"
