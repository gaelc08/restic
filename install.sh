#!/usr/bin/env bash
# Installs the restic backup automation onto this host:
#   - copies bin/*.sh to /usr/local/bin
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
    echo "This script must be run as root (it writes to /etc, /usr/local/bin, /etc/systemd)." >&2
    exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

echo "==> Installing scripts to /usr/local/bin"
install -m 0755 "${SCRIPT_DIR}/bin/restic-backup.sh"      /usr/local/bin/restic-backup.sh
install -m 0755 "${SCRIPT_DIR}/bin/restic-maintenance.sh" /usr/local/bin/restic-maintenance.sh
install -m 0755 "${SCRIPT_DIR}/bin/restic-snapshots.sh"   /usr/local/bin/restic-snapshots.sh
install -m 0644 "${SCRIPT_DIR}/bin/restic-common.sh"      /usr/local/bin/restic-common.sh

echo "==> Installing config to /etc/restic (existing files left untouched)"
mkdir -p /etc/restic
for f in restic.env secrets.env backup-paths.txt excludes.txt; do
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
    1. Edit /etc/restic/restic.env        (repository, pack size, parallelism, retention, ...)
    2. Edit /etc/restic/secrets.env       (chmod 600 - repo password + AWS credentials)
    3. Edit /etc/restic/backup-paths.txt  (mount points to back up)
    4. Edit /etc/restic/excludes.txt as needed
    5. If the repository is new:
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
