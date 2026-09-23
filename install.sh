#!/usr/bin/env bash
# Installs the restic backup automation onto this host:
#   - copies bin/*.sh to /opt/restic/bin
#   - copies config/*.example to /etc/restic/* (only if not already present)
#   - installs the systemd units and logrotate config
#   - creates /var/log/restic and reloads systemd
#
# Does NOT enable or start the timers, and does NOT overwrite an
# existing /etc/restic/restic.env - edit the config first
# (see README.md), then run:
#   systemctl enable --now restic-backup.timer restic-maintenance.timer

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root (it writes to /etc, /opt/restic, /etc/systemd)." >&2
    exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

echo "==> Installing scripts to /opt/restic/bin"
mkdir -p /opt/restic/bin
install -m 0755 "${SCRIPT_DIR}/bin/restic-backup.sh"      /opt/restic/bin/restic-backup.sh
install -m 0755 "${SCRIPT_DIR}/bin/restic-maintenance.sh" /opt/restic/bin/restic-maintenance.sh
install -m 0755 "${SCRIPT_DIR}/bin/restic-snapshots.sh"   /opt/restic/bin/restic-snapshots.sh
install -m 0644 "${SCRIPT_DIR}/bin/restic-common.sh"      /opt/restic/bin/restic-common.sh

echo "==> Creating cache/tmp directories"
# These must exist on disk *before* the systemd services ever start:
# ReadWritePaths= in restic-backup.service / restic-maintenance.service
# bind-mounts them into the service's private mount namespace before
# ExecStart runs, and unlike the script's own `mkdir -p` (which only
# runs after that), systemd will not create them for you - it fails
# with "226/NAMESPACE" instead. If you change RESTIC_CACHE_DIR or
# RESTIC_TMP_DIR in restic.env away from these defaults, update
# ReadWritePaths= in both unit files to match and create the new
# directories the same way.
mkdir -p /opt/restic/restic-cache /opt/restic/restic-tmp

echo "==> Installing config to /etc/restic (existing files left untouched)"
mkdir -p /etc/restic
for f in restic.env secrets.env shares.conf retention-policies.conf excludes.txt; do
    if [[ -f "/etc/restic/${f}" ]]; then
        echo "    skip existing /etc/restic/${f}"
    else
        install -m 0640 "${SCRIPT_DIR}/config/${f}.example" "/etc/restic/${f}"
        echo "    installed /etc/restic/${f} (edit before enabling the timers)"
    fi
done
chown root:root /etc/restic/secrets.env 2>/dev/null || true
chmod 600 /etc/restic/secrets.env 2>/dev/null || true

echo "==> Creating log directory"
mkdir -p /var/log/restic
chmod 750 /var/log/restic

echo "==> Installing logrotate config"
install -m 0644 "${SCRIPT_DIR}/logrotate/restic" /etc/logrotate.d/restic

echo "==> Installing systemd units"
install -m 0644 "${SCRIPT_DIR}/systemd/restic-backup.service"      /etc/systemd/system/restic-backup.service
install -m 0644 "${SCRIPT_DIR}/systemd/restic-backup.timer"        /etc/systemd/system/restic-backup.timer
install -m 0644 "${SCRIPT_DIR}/systemd/restic-maintenance.service" /etc/systemd/system/restic-maintenance.service
install -m 0644 "${SCRIPT_DIR}/systemd/restic-maintenance.timer"   /etc/systemd/system/restic-maintenance.timer
systemctl daemon-reload

cat <<'EOF'

==> Install complete. Before enabling the timers:
    1. Edit /etc/restic/restic.env               (repository, pack size, parallelism, ...)
    2. Edit /etc/restic/secrets.env              (chmod 600 - repo password + AWS credentials)
    3. Edit /etc/restic/retention-policies.conf  (define your short/mid/long - or other - policies)
    4. Edit /etc/restic/shares.conf              (mount points to back up + policy per share)
    5. Edit /etc/restic/excludes.txt as needed
    6. If the repository is new:
         set -a; source /etc/restic/restic.env; source /etc/restic/secrets.env; set +a
         restic init --pack-size "$RESTIC_PACK_SIZE" \
             -o s3.storage-class="$RESTIC_S3_STORAGE_CLASS"

Then enable the daily timers:
    systemctl enable --now restic-backup.timer
    systemctl enable --now restic-maintenance.timer

Check status any time with:
    systemctl list-timers 'restic-*'
    journalctl -u restic-backup.service -u restic-maintenance.service
    tail -f /var/log/restic/backup.log /var/log/restic/maintenance.log
EOF
