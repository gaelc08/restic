#!/usr/bin/env bash
# Provisions a new share end to end: adds the mount to /etc/fstab,
# mounts it, verifies the mount actually came up, then adds it to
# shares.conf with a retention policy - so you no longer need to do
# both halves (fstab + restic config) by hand.
#
# Once shares.conf has the new line, nothing else is needed: the daily
# restic-backup.timer dispatcher re-reads shares.conf fresh every run
# and picks up the new share automatically (see
# bin/restic-backup-dispatch.sh). To back it up right now instead of
# waiting for that:
#   resticctl backup --background <share-name>
#
# Usage:
#   restic-add-share.sh --type nfs  --source <host:/export> --mount <path> --policy <name> [--nconnect N] [--yes]
#   restic-add-share.sh --type cifs --source //<host>/<share> --mount <path> --policy <name> --credentials <file> [--yes]
#   restic-add-share.sh ... --options "<raw fstab mount options>"   # escape hatch - overrides the built-in defaults entirely
#
# --yes skips the confirmation prompt (needed for non-interactive use).
#
# This is a provisioning helper, not a daily job - it touches
# /etc/fstab and runs `mount`, both one-off, interactive-ish
# operations, unlike the restic-*.sh scripts it otherwise matches in
# style (source restic-common.sh for config paths and log()/die()).

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/restic-common.sh"

LOG_FILE="${ADD_SHARE_LOG_FILE:-${LOG_DIR}/add-share.log}"
FSTAB_FILE="${FSTAB_FILE:-/etc/fstab}"

if [[ $EUID -ne 0 ]]; then
    die "must be run as root (it writes to ${FSTAB_FILE} and ${SHARES_FILE})"
fi

usage() {
    cat <<EOF >&2
Usage:
  $(basename "$0") --type nfs  --source <host:/export> --mount <path> --policy <name> [--nconnect N] [--yes]
  $(basename "$0") --type cifs --source //<host>/<share> --mount <path> --policy <name> --credentials <file> [--yes]
  $(basename "$0") ... --options "<raw fstab mount options>"
EOF
}

# Default matches RESTIC_READ_CONCURRENCY, already loaded from
# restic.env by restic-common.sh above (default 4 in
# config/restic.env.example, but this host's actual value - whatever
# it is - wins, since that's a shell variable, not a literal) rather
# than a generic "N is fine for most links" number: restic reads that
# many files concurrently during backup, and each concurrent read
# becomes an NFS RPC call that the client spreads across nconnect's
# TCP connections - fewer connections than concurrent reads means some
# of those reads queue up behind each other on the same connection
# instead of actually running in parallel.
TYPE="" SOURCE="" MOUNT_POINT="" POLICY="" NCONNECT="$RESTIC_READ_CONCURRENCY" CREDENTIALS="" RAW_OPTIONS="" ASSUME_YES=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --type) TYPE="$2"; shift 2 ;;
        --source) SOURCE="$2"; shift 2 ;;
        --mount) MOUNT_POINT="${2%/}"; shift 2 ;;
        --policy) POLICY="$2"; shift 2 ;;
        --nconnect) NCONNECT="$2"; shift 2 ;;
        --credentials) CREDENTIALS="$2"; shift 2 ;;
        --options) RAW_OPTIONS="$2"; shift 2 ;;
        --yes|-y) ASSUME_YES=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown argument: $1" >&2; usage; exit 2 ;;
    esac
done

[[ "$TYPE" == "nfs" || "$TYPE" == "cifs" ]] || { echo "--type must be 'nfs' or 'cifs'" >&2; usage; exit 2; }
[[ -n "$SOURCE" ]] || { echo "--source is required" >&2; usage; exit 2; }
[[ "$MOUNT_POINT" == /* ]] || { echo "--mount must be an absolute path" >&2; usage; exit 2; }
[[ -n "$POLICY" ]] || { echo "--policy is required" >&2; usage; exit 2; }
if [[ "$TYPE" == "cifs" && -z "$CREDENTIALS" && -z "$RAW_OPTIONS" ]]; then
    echo "--credentials is required for --type cifs (or pass --options yourself)" >&2
    exit 2
fi
if [[ "$TYPE" == "cifs" && -n "$CREDENTIALS" && ! -r "$CREDENTIALS" ]]; then
    die "credentials file not readable: $CREDENTIALS"
fi

# Reuses the exact same validation parse_shares_file applies to every
# existing share - an unknown policy name is a config error here too,
# not something to silently fall back on.
load_retention_policies
if [[ -z "${POLICY_KEEP_DAILY[$POLICY]+x}" ]]; then
    die "unknown retention policy '$POLICY' (check $RETENTION_POLICIES_FILE)"
fi

if grep -qsE "^\S+\s+${MOUNT_POINT}\s" "$FSTAB_FILE"; then
    die "$MOUNT_POINT is already in $FSTAB_FILE"
fi
if [[ -r "$SHARES_FILE" ]] && grep -qsE "^${MOUNT_POINT}(/)?\s" "$SHARES_FILE"; then
    die "$MOUNT_POINT is already in $SHARES_FILE"
fi

if [[ -n "$RAW_OPTIONS" ]]; then
    FSTYPE="$TYPE"
    OPTIONS="$RAW_OPTIONS"
elif [[ "$TYPE" == "nfs" ]]; then
    [[ "$NCONNECT" =~ ^[0-9]+$ ]] || die "--nconnect must be a number, got: $NCONNECT"
    FSTYPE="nfs4"
    OPTIONS="rw,_netdev,vers=4.2,hard,proto=tcp,timeo=600,retrans=2,sec=sys,rsize=262144,wsize=262144,nconnect=${NCONNECT}"
else
    FSTYPE="cifs"
    OPTIONS="credentials=${CREDENTIALS},vers=3.1.1,seal,noserverino,_netdev"
fi

FSTAB_LINE="${SOURCE} ${MOUNT_POINT} ${FSTYPE} ${OPTIONS} 0 0"
SHARE_LINE="${MOUNT_POINT} ${POLICY}"

echo "About to add:"
echo "  ${FSTAB_FILE}:    ${FSTAB_LINE}"
echo "  ${SHARES_FILE}: ${SHARE_LINE}"
if [[ $ASSUME_YES -ne 1 ]]; then
    if [[ ! -t 0 ]]; then
        die "not running interactively and --yes was not given; aborting without making changes"
    fi
    read -r -p "Proceed? [y/N] " reply
    case "$reply" in
        y|Y|yes|YES) ;;
        *) log_info "aborted by user, no changes made"; exit 1 ;;
    esac
fi

log_info "===== restic-add-share starting: ${MOUNT_POINT} (${TYPE}) ====="

FSTAB_BACKUP="${FSTAB_FILE}.bak.$(date +%Y%m%d%H%M%S)"
cp -p "$FSTAB_FILE" "$FSTAB_BACKUP"
log_info "backed up $FSTAB_FILE to $FSTAB_BACKUP"

mkdir -p "$MOUNT_POINT"
echo "$FSTAB_LINE" >> "$FSTAB_FILE"
log_info "appended to $FSTAB_FILE: $FSTAB_LINE"

# /etc/fstab changes need this for systemd's fstab generator to turn
# the new line into a .mount unit (unlike most changes this project
# makes, which never need daemon-reload at all).
systemctl daemon-reload

mount "$MOUNT_POINT" >>"$LOG_FILE" 2>&1
mount_rc=$?

if [[ $mount_rc -ne 0 ]] || ! mountpoint -q "$MOUNT_POINT"; then
    log_error "mount failed (exit $mount_rc) or $MOUNT_POINT is not actually mounted - rolling back $FSTAB_FILE"
    cp -p "$FSTAB_BACKUP" "$FSTAB_FILE"
    systemctl daemon-reload
    die "could not mount $MOUNT_POINT - $FSTAB_FILE rolled back to $FSTAB_BACKUP, nothing added to $SHARES_FILE. See $LOG_FILE."
fi
log_info "mounted $MOUNT_POINT successfully"

echo "$SHARE_LINE" >> "$SHARES_FILE"
log_info "appended to $SHARES_FILE: $SHARE_LINE"

share_name="$(basename "$MOUNT_POINT")"
log_info "===== restic-add-share finished: ${MOUNT_POINT} added as share '${share_name}' ====="

cat <<EOF

Done. '$share_name' will be backed up automatically at the next
restic-backup.timer run. To back it up right now instead:
    resticctl backup --background ${share_name}
EOF
