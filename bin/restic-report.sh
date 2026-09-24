#!/usr/bin/env bash
# Daily status digest: last backup/maintenance/verify outcomes, plus a
# per-share snapshot summary, emailed as one plain-text report.
#
# Unlike restic-verify.sh, this only reads local status files
# (RESTIC_STATUS_DIR) and fast repository metadata (`restic
# snapshots`) - it never touches archived pack data, so it's safe to
# run on a daily schedule (see systemd/restic-report.timer).
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

# read_status <job> - human-readable summary of a job's last recorded
# run, or a clear "nothing recorded" line if the status file is
# missing (e.g. verify has never been run manually yet).
read_status() {
    local job="$1"
    local file="${RESTIC_STATUS_DIR}/${job}.status"
    if [[ ! -r "$file" ]]; then
        echo "  Aucune execution enregistree."
        return
    fi
    local status timestamp summary
    status="$(grep '^STATUS=' "$file" | cut -d= -f2-)"
    timestamp="$(grep '^TIMESTAMP=' "$file" | cut -d= -f2-)"
    summary="$(grep '^SUMMARY=' "$file" | cut -d= -f2-)"
    echo "  Statut: ${status:-inconnu}  (${timestamp:-date inconnue})"
    echo "  ${summary}"
}

# Latest snapshot per share, grouped by path - fast, metadata-only,
# reuses the same flags restic-snapshots.sh defaults to.
SHARES_TABLE="$(restic snapshots "${RESTIC_GLOBAL_ARGS[@]}" --group-by paths --latest 1 2>>"$LOG_FILE")"

BODY="$(cat <<REPORTEOF
Rapport quotidien restic - ${host} - ${today}

=== Backup ===
$(read_status backup)

=== Maintenance ===
$(read_status maintenance)

=== Verification de restore (manuelle, sur demande - pas de planification automatique) ===
$(read_status verify)

=== Shares (dernier snapshot) ===
${SHARES_TABLE}

--
Genere automatiquement par restic-report.sh sur ${host}.
REPORTEOF
)"

printf '%s\n' "$BODY" >> "$LOG_FILE"

if [[ -n "$RECIPIENT" ]]; then
    if send_email "$RECIPIENT" "[restic] rapport quotidien - ${host}" "$BODY"; then
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
