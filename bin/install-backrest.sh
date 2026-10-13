#!/usr/bin/env bash
# Installs Backrest (https://github.com/garethgeorge/backrest) as an
# OPTIONAL, read-only snapshot browser for the restic repository this
# host already backs up to - a web UI to replace squinting at
# `resticctl list` once there are many shares/snapshots.
#
# manny-01 is on an isolated network with no internet access, so this
# script NEVER downloads anything itself - it installs from a tarball
# already sitting in vendor/, which must have been fetched on a
# machine WITH internet access (bin/fetch-backrest.sh, run on the
# laptop that also runs ./update-manny.sh) and carried over by that
# same rsync. See vendor/README.md.
#
# This is a separate, optional add-on, not wired into install.sh:
# Backrest is its own long-running web service, entirely independent
# of the backup automation in bin/ and systemd/restic-*. It is pinned
# to one specific release and verified against a checksum captured by
# hand (bin/backrest-version.sh) rather than always fetching "latest",
# since this runs a third-party binary on a government backup server.
#
# Does NOT enable or start the service, and does NOT create
# /etc/backrest/secrets.env if it's missing - fill that in first (see
# README.md), then:
#   systemctl daemon-reload
#   systemctl enable --now backrest.service
#
# IMPORTANT (read before using the web UI, see README.md for the full
# version): only use Backrest to IMPORT the existing repo and browse
# the top-level snapshot list (dates/sizes/tags) - exactly what
# `resticctl list` already does safely today. Do NOT add a "Plan" in
# Backrest (that would schedule its own backups/retention, duplicating
# and potentially conflicting with the dispatcher/timers already
# running here), and avoid its "browse file contents"/"restore"
# features - those read actual data blobs, which on this repository's
# S3 Glacier storage class are only meant to be read through the
# deliberately manual `resticctl verify --target` workflow.

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root (it writes to /etc, /opt, /var/lib, /etc/systemd)." >&2
    exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." &>/dev/null && pwd)"
# shellcheck source=bin/backrest-version.sh
source "${SCRIPT_DIR}/backrest-version.sh"

ARCH="$(uname -m)"
if [[ "$ARCH" != "x86_64" ]]; then
    echo "This installer only has a verified checksum for linux/x86_64 (got: ${ARCH})." >&2
    echo "Fetch the matching backrest_Linux_<arch>.tar.gz on a connected machine" >&2
    echo "yourself, verify it, and adjust this script and bin/fetch-backrest.sh before using it here." >&2
    exit 1
fi

VENDORED_TARBALL="${REPO_ROOT}/vendor/${BACKREST_ASSET}"
if [[ ! -f "$VENDORED_TARBALL" ]]; then
    echo "Missing ${VENDORED_TARBALL}." >&2
    echo "manny-01 has no internet access, so this script never downloads Backrest" >&2
    echo "itself. On a machine WITH internet access (the laptop that runs" >&2
    echo "./update-manny.sh), run bin/fetch-backrest.sh, then run ./update-manny.sh" >&2
    echo "as usual to carry the tarball over here, and re-run this installer." >&2
    exit 1
fi

echo "==> Verifying vendored tarball"
echo "${BACKREST_SHA256}  ${VENDORED_TARBALL}" | sha256sum -c -

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

echo "==> Extracting"
tar -xzf "$VENDORED_TARBALL" -C "$WORK_DIR" backrest

echo "==> Creating backrest system user"
if ! getent passwd backrest >/dev/null; then
    useradd --system --no-create-home --home-dir /var/lib/backrest --shell /usr/sbin/nologin backrest
fi

echo "==> Installing binary to /opt/backrest/bin/backrest"
mkdir -p /opt/backrest/bin
install -m 0755 "${WORK_DIR}/backrest" /opt/backrest/bin/backrest

echo "==> Creating config/data directories"
mkdir -p /etc/backrest /var/lib/backrest /var/lib/backrest/cache
chown -R backrest:backrest /var/lib/backrest
chown root:backrest /etc/backrest
chmod 750 /etc/backrest

if [[ -f /etc/backrest/secrets.env ]]; then
    echo "    skip existing /etc/backrest/secrets.env"
else
    # Mirrors the SAME mechanism restic.env already uses here
    # (RESTIC_PASSWORD_FILE + AWS_PROFILE against a credentials file),
    # not raw inline secrets - Backrest supports this natively (its
    # restic subprocess reads RESTIC_PASSWORD_FILE/AWS_PROFILE exactly
    # like a normal restic invocation would). The actual secret bytes
    # go in the two files below, copied once from the real sources
    # (/etc/restic/password, /root/.aws/credentials's [backup]
    # section) - acceptable here since those are static/rarely
    # rotated; if that changes, point these at the originals via a
    # read ACL instead of copying.
    cat > /etc/backrest/secrets.env <<'EOF'
RESTIC_REPOSITORY="s3:https://scrat-1.ctie.etat.lu:4443/restic"
RESTIC_PASSWORD_FILE=/etc/backrest/password
AWS_SHARED_CREDENTIALS_FILE=/etc/backrest/aws-credentials
AWS_PROFILE=backup
EOF
    chown backrest:backrest /etc/backrest/secrets.env
    chmod 600 /etc/backrest/secrets.env
    echo "    wrote /etc/backrest/secrets.env"

    touch /etc/backrest/password
    chown backrest:backrest /etc/backrest/password
    chmod 600 /etc/backrest/password
    echo "    created empty /etc/backrest/password - paste the SAME content as /etc/restic/password into it (no trailing newline)"

    cat > /etc/backrest/aws-credentials <<'EOF'
[backup]
aws_access_key_id =
aws_secret_access_key =
EOF
    chown backrest:backrest /etc/backrest/aws-credentials
    chmod 600 /etc/backrest/aws-credentials
    echo "    wrote /etc/backrest/aws-credentials - fill in the [backup] profile from /root/.aws/credentials"
fi

echo "==> Installing systemd unit"
install -m 0644 "${REPO_ROOT}/systemd/backrest.service" /etc/systemd/system/backrest.service
systemctl daemon-reload

cat <<'EOF'

==> Backrest installed, but NOT started. Before starting it:
    1. Paste the restic repo password into /etc/backrest/password
       (same content as /etc/restic/password, no trailing newline).
    2. Fill in the [backup] profile in /etc/backrest/aws-credentials
       from /root/.aws/credentials.
    3. Confirm the system restic binary is at /usr/bin/restic (`which restic`);
       if not, edit BACKREST_RESTIC_COMMAND in systemd/backrest.service and
       `systemctl daemon-reload`.

Then:
    systemctl enable --now backrest.service

Backrest listens on every interface (BACKREST_PORT=:9898) - open
http://<this host>:9898 directly. First visit prompts you to create
an admin username/password (bcrypt-hashed) - do this immediately,
before anyone else on the network can reach that first-run screen.
There is NO built-in TLS, so that login (and everything else) travels
as plain HTTP - if your network needs encryption in transit too, put
a reverse proxy in front instead of exposing this directly.

IMPORTANT - see README.md's Backrest section for the full explanation:
  - Only "Add Repo" -> import the existing repository. Leave its
    password field empty - with RESTIC_PASSWORD_FILE already set in
    the service environment, Backrest reads the password from there,
    the same way restic itself does. Do NOT add a "Plan" - that would
    schedule Backrest's own backups/retention on top of the
    dispatcher/timers already running here.
  - Stick to the snapshot list view. Avoid "browse files"/"restore" in
    Backrest - this repository's S3 Glacier storage class means
    reading actual file contents needs the deliberately manual
    `resticctl verify --target` workflow instead.
EOF
