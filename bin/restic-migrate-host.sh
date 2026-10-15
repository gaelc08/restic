#!/usr/bin/env bash
# Copies everything this host's restic setup needs that does NOT live
# in git - secrets, per-host config, CIFS/NFS mount credentials files,
# and (optionally) Backrest's own state - to a new host, for a
# hardware replacement/migration. Run this FROM the OLD host, AS ROOT,
# with SSH access to the new one.
#
# What this does NOT do:
#   - install the restic-backup code itself: run update-manny.sh (or
#     install.sh directly) on the new host for that. install.sh never
#     overwrites an existing /etc/restic/* file, so running it after
#     this script is safe - it won't clobber what was just copied.
#   - mount the CIFS/NFS shares on the new host: this only copies the
#     credentials files referenced from /etc/fstab and prints the
#     matching fstab lines for you to review and add by hand (blindly
#     concatenating fstab files risks duplicating/conflicting with
#     entries the new host already has for its own local disks).
#   - open firewall ports, install Backrest (bin/install-backrest.sh is
#     a separate step), or enable the systemd timers.
#   - migrate the restic repository itself - it's remote S3/Glacier,
#     there is nothing local to move.
#
# Usage:
#   restic-migrate-host.sh --target <user@host> [--include-backrest] [--dry-run]

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/restic-common.sh"

LOG_FILE="${MIGRATE_LOG_FILE:-${LOG_DIR}/migrate-host.log}"
FSTAB_FILE="${FSTAB_FILE:-/etc/fstab}"

if [[ $EUID -ne 0 ]]; then
    die "must be run as root (reads ${RESTIC_SECRETS_FILE} and other 600-permission files)"
fi

usage() {
    cat <<EOF >&2
Usage: $(basename "$0") --target <user@host> [--include-backrest] [--dry-run]
EOF
}

TARGET="" INCLUDE_BACKREST=0 DRY_RUN=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target) TARGET="$2"; shift 2 ;;
        --include-backrest) INCLUDE_BACKREST=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown argument: $1" >&2; usage; exit 2 ;;
    esac
done

[[ -n "$TARGET" ]] || { echo "--target <user@host> is required" >&2; usage; exit 2; }

RSYNC_OPTS=(-avR -e ssh)
[[ $DRY_RUN -eq 1 ]] && RSYNC_OPTS+=(--dry-run)

log_info "===== restic-migrate-host starting: target=${TARGET} dry_run=${DRY_RUN} include_backrest=${INCLUDE_BACKREST} ====="

# --- Core config + secrets (never in git, read from this host's own
# configured paths rather than hardcoded /etc/restic/* - in case any
# of them were customized in restic.env) --------------------------------
FILES=(
    "$RESTIC_ENV_FILE"
    "$RESTIC_SECRETS_FILE"
    "$SHARES_FILE"
    "$RETENTION_POLICIES_FILE"
)
[[ -n "${EXCLUDE_FILE:-}" && -r "${EXCLUDE_FILE:-}" ]] && FILES+=("$EXCLUDE_FILE")
# AWS_SHARED_CREDENTIALS_FILE, if restic.env/secrets.env sets it
# (see README's "AWS_PROFILE alone is not enough under systemd") -
# whatever this host actually uses, not an assumed /root/.aws path.
[[ -n "${AWS_SHARED_CREDENTIALS_FILE:-}" && -r "${AWS_SHARED_CREDENTIALS_FILE:-}" ]] && FILES+=("$AWS_SHARED_CREDENTIALS_FILE")

# --- CIFS/NFS mount credentials referenced from /etc/fstab ----------------
# Without these, the fstab lines printed below are useless on the new
# host - CIFS credentials= files in particular live outside
# /etc/restic entirely and are easy to forget.
if [[ -r "$FSTAB_FILE" ]]; then
    while IFS= read -r cred_path; do
        [[ -n "$cred_path" && -r "$cred_path" ]] && FILES+=("$cred_path")
    done < <(grep -E '\scifs\s' "$FSTAB_FILE" | grep -oE 'credentials=[^,[:space:]]+' | cut -d= -f2-)
fi

echo "Copying to ${TARGET}:"
printf '  %s\n' "${FILES[@]}"
rsync "${RSYNC_OPTS[@]}" "${FILES[@]}" "${TARGET}:/" 2>&1 | tee -a "$LOG_FILE"

if [[ $INCLUDE_BACKREST -eq 1 ]]; then
    echo
    echo "Copying Backrest state to ${TARGET}:"
    BACKREST_FILES=()
    [[ -r /etc/backrest/config.json ]] && BACKREST_FILES+=(/etc/backrest/config.json)
    [[ -r /etc/restic/backrest-aws-credentials ]] && BACKREST_FILES+=(/etc/restic/backrest-aws-credentials)
    [[ -d /var/lib/backrest ]] && BACKREST_FILES+=(/var/lib/backrest)
    if [[ ${#BACKREST_FILES[@]} -gt 0 ]]; then
        printf '  %s\n' "${BACKREST_FILES[@]}"
        rsync "${RSYNC_OPTS[@]}" "${BACKREST_FILES[@]}" "${TARGET}:/" 2>&1 | tee -a "$LOG_FILE"
    else
        echo "  (nothing found - Backrest doesn't look installed on this host)"
    fi
fi

echo
echo "===== ${FSTAB_FILE} lines to review and add on ${TARGET} ====="
grep -E '\s(cifs|nfs4?)\s' "$FSTAB_FILE" || echo "(none found in ${FSTAB_FILE})"

log_info "===== restic-migrate-host finished ====="

cat <<EOF

Done copying what lives outside git. Still to do on ${TARGET}:
  1. Run update-manny.sh (or install.sh directly) to deploy the code -
     it skips any /etc/restic/* file that already exists, so it will
     NOT overwrite what was just copied here.
  2. Review the fstab lines printed above, add them to ${TARGET}'s own
     /etc/fstab, mkdir -p the mount points, then:
       systemctl daemon-reload && mount -a
  3. Re-open the firewall ports this host had open (check with
     firewall-cmd --list-all here) - webreport (9900), Backrest (9898
     if migrated), and anything else specific to this deployment.
  4. If Backrest was migrated (--include-backrest): still run
     bin/install-backrest.sh on ${TARGET} - it's a separate step from
     install.sh and sets up the service user/permissions around the
     copied config.
  5. Enable the timers:
       systemctl enable --now restic-backup.timer restic-maintenance.timer
       systemctl enable --now restic-webreport.timer
       systemctl enable --now restic-webserver.service
  6. Verify before decommissioning this host:
       resticctl list   (run on ${TARGET})
EOF
