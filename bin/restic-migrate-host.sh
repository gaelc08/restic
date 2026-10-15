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
#   restic-migrate-host.sh --target <user@host> [--identity <key-file>]
#       [--remote-sudo | --stage [<dir-name>]] [--include-backrest] [--dry-run]
#
# This script itself must run as root (it reads 600-permission secrets
# files), but that does NOT mean the SSH connection has to authenticate
# as root - and on a host where root never has its own network
# identity (no root SSH key, by policy), it can't. --identity
# <key-file> picks which private key the SSH *connection* presents
# instead, independent of which OS user is running this script: root
# can read a key file belonging to anyone (e.g. one just generated for
# this one-off migration, or an existing key for the --target user) and
# hand it to ssh with -i, the same way `sudo -u otheruser` doesn't
# require guessing their password - owning the file is enough. The
# `<user>@` in --target still selects which account to log in as; the
# key just has to be one that account authorized_keys accepts.
#
# Reaching the target as a regular user rather than root means the
# copied files need a privilege escalation on arrival too - two ways
# to get that, pick whichever matches how sudo is actually set up
# there:
#
# --remote-sudo: runs the remote side of rsync itself as `sudo rsync`,
# in one unattended command. Needs a NOPASSWD rule for rsync on the
# target for that user AND for sudo to not require a tty - if either
# is missing (common wherever sudo policy is centrally managed via
# LDAP/SSSD rather than a local /etc/sudoers.d file, which is where
# this was actually hit: a local NOPASSWD rule was added and `visudo
# -c` validated it, but sudo still demanded a password - the central
# policy was clearly the one actually in effect), this hangs/fails
# with "sudo: a password is required" (rsync's transport is a raw
# binary pipe with no terminal for sudo to prompt on, and forcing one
# with `ssh -t` corrupts rsync's own protocol instead of fixing it).
#
# --stage [<dir-name>] (the default, and the one that doesn't depend on
# how sudo is configured): copies everything into <dir-name>
# (default: restic-migrate-staging) under the --target user's own
# home directory instead of "/" - no remote privilege needed for that,
# it's their own writable space. Prints the one `sudo rsync` command
# to run yourself, interactively, ON the target afterwards - the same
# kind of sudo invocation that already works fine with a real
# terminal attached, which is exactly what this avoids needing over
# the network.

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
Usage: $(basename "$0") --target <user@host> [--identity <key-file>] [--remote-sudo | --stage [<dir-name>]] [--include-backrest] [--dry-run]
EOF
}

TARGET="" IDENTITY="" INCLUDE_BACKREST=0 DRY_RUN=0 REMOTE_SUDO=0 STAGE=1 STAGE_DIR="restic-migrate-staging"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target) TARGET="$2"; shift 2 ;;
        --identity) IDENTITY="$2"; shift 2 ;;
        --include-backrest) INCLUDE_BACKREST=1; shift ;;
        --remote-sudo) REMOTE_SUDO=1; STAGE=0; shift ;;
        --stage)
            STAGE=1
            if [[ $# -ge 2 && "$2" != --* ]]; then
                STAGE_DIR="$2"; shift 2
            else
                shift
            fi
            ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown argument: $1" >&2; usage; exit 2 ;;
    esac
done

[[ -n "$TARGET" ]] || { echo "--target <user@host> is required" >&2; usage; exit 2; }
if [[ -n "$IDENTITY" && ! -r "$IDENTITY" ]]; then
    die "--identity file not readable: $IDENTITY"
fi

SSH_CMD="ssh"
[[ -n "$IDENTITY" ]] && SSH_CMD="ssh -i ${IDENTITY} -o IdentitiesOnly=yes"

RSYNC_OPTS=(-avR -e "$SSH_CMD")
if [[ $REMOTE_SUDO -eq 1 ]]; then
    RSYNC_OPTS+=("--rsync-path=sudo rsync")
fi
[[ $DRY_RUN -eq 1 ]] && RSYNC_OPTS+=(--dry-run)

# Where files actually land on the target: "/" for --remote-sudo
# (writing straight to their final absolute path, which is why that
# needs remote root), or a plain directory under the --target user's
# own home for --stage (no privilege needed - it's their own space).
# A relative rsync destination (no leading "/") lands relative to the
# login's home directory, same as a plain `scp` without one.
REMOTE_DEST="/"
[[ $STAGE -eq 1 ]] && REMOTE_DEST="${STAGE_DIR}/"

log_info "===== restic-migrate-host starting: target=${TARGET} identity=${IDENTITY:-<default>} dry_run=${DRY_RUN} include_backrest=${INCLUDE_BACKREST} remote_sudo=${REMOTE_SUDO} stage=${STAGE} stage_dir=${STAGE_DIR} ====="

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
    # sort -u: several shares commonly point at the same credentials
    # file - no need to list (and rsync) it once per share.
    while IFS= read -r cred_path; do
        [[ -n "$cred_path" && -r "$cred_path" ]] && FILES+=("$cred_path")
    done < <(grep -E '\scifs\s' "$FSTAB_FILE" | grep -oE 'credentials=[^,[:space:]]+' | cut -d= -f2- | sort -u)
fi

echo "Copying to ${TARGET}:${REMOTE_DEST}"
printf '  %s\n' "${FILES[@]}"
rsync "${RSYNC_OPTS[@]}" "${FILES[@]}" "${TARGET}:${REMOTE_DEST}" 2>&1 | tee -a "$LOG_FILE"

if [[ $INCLUDE_BACKREST -eq 1 ]]; then
    echo
    echo "Copying Backrest state to ${TARGET}:${REMOTE_DEST}"
    BACKREST_FILES=()
    [[ -r /etc/backrest/config.json ]] && BACKREST_FILES+=(/etc/backrest/config.json)
    [[ -r /etc/restic/backrest-aws-credentials ]] && BACKREST_FILES+=(/etc/restic/backrest-aws-credentials)
    [[ -d /var/lib/backrest ]] && BACKREST_FILES+=(/var/lib/backrest)
    if [[ ${#BACKREST_FILES[@]} -gt 0 ]]; then
        printf '  %s\n' "${BACKREST_FILES[@]}"
        rsync "${RSYNC_OPTS[@]}" "${BACKREST_FILES[@]}" "${TARGET}:${REMOTE_DEST}" 2>&1 | tee -a "$LOG_FILE"
    else
        echo "  (nothing found - Backrest doesn't look installed on this host)"
    fi
fi

echo
echo "===== ${FSTAB_FILE} lines to review and add on ${TARGET} ====="
grep -E '\s(cifs|nfs4?)\s' "$FSTAB_FILE" || echo "(none found in ${FSTAB_FILE})"

log_info "===== restic-migrate-host finished ====="

if [[ $STAGE -eq 1 ]]; then
    cat <<EOF

===== One more step on ${TARGET} before anything else below =====
Everything above landed under ~/${STAGE_DIR}/ (${TARGET}'s own home,
no remote privilege needed for that) rather than its real final
path. Log into ${TARGET} yourself and, as root (interactively - this
is the normal kind of sudo prompt, not the one that doesn't work over
rsync's pipe), move it into place and clean up the staging copy:
    sudo rsync -a ~/${STAGE_DIR}/ /
    rm -rf ~/${STAGE_DIR}
EOF
fi

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
