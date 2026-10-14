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
# Does NOT enable or start the service. No secrets to fill in either -
# it reads /etc/restic/restic.env and /etc/restic/secrets.env
# directly, the exact same files and credentials restic-backup.sh
# itself already uses (see the ACL grant below and
# systemd/backrest.service for why). Just:
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
# chmod explicitly rather than trusting mkdir -p's umask-derived mode:
# these stay root:root (only the binary needs to be here), but must
# still be traversable+executable by the separate `backrest` user that
# runs it - a restrictive root umask (observed on manny-01: 0027, making
# mkdir -p produce 750 directories) would otherwise block that with
# "Permission denied" (systemd reports this as status=203/EXEC) even
# though the binary itself is 0755.
mkdir -p /opt/backrest/bin
chmod 755 /opt/backrest /opt/backrest/bin
install -m 0755 "${WORK_DIR}/backrest" /opt/backrest/bin/backrest

echo "==> Creating config/data directories"
# restic-cache is Backrest's own RESTIC_CACHE_DIR (see
# systemd/backrest.service) - kept separate from the real backups'
# /opt/restic/restic-cache (root-owned) rather than sharing it, since
# that one may not even be reachable by this unprivileged user
# depending on the host's umask.
mkdir -p /etc/backrest /var/lib/backrest /var/lib/backrest/cache /var/lib/backrest/restic-cache
chown backrest:backrest /etc/backrest
chown -R backrest:backrest /var/lib/backrest

echo "==> Granting backrest read access to the existing restic secrets"
# No copy: Backrest reads /etc/restic/{restic,secrets}.env directly
# (see systemd/backrest.service), the exact same files and order
# restic-backup.sh itself sources - so it authenticates exactly the
# same way the real backups do, whichever of this host's two
# overlapping credential mechanisms (RESTIC_PASSWORD_FILE/AWS_PROFILE
# in restic.env, or the literal RESTIC_PASSWORD/AWS_ACCESS_KEY_ID/
# AWS_SECRET_ACCESS_KEY in secrets.env) actually wins. A POSIX ACL
# grants just read access on secrets.env without changing its
# ownership or mode (still 600 root:root) - restic.env isn't secret
# and needs no ACL. Requires the `acl` package (setfacl/getfacl).
if ! command -v setfacl >/dev/null 2>&1; then
    echo "setfacl not found (part of the 'acl' package) - install it, e.g. 'dnf install acl', and re-run this script." >&2
    exit 1
fi
setfacl -m u:backrest:x /etc/restic
setfacl -m u:backrest:r /etc/restic/secrets.env
echo "    granted backrest read access to /etc/restic/secrets.env (getfacl /etc/restic/secrets.env to verify)"

# RESTIC_PASSWORD_FILE and/or AWS_PROFILE's credentials file live
# OUTSIDE /etc/restic/secrets.env itself (e.g. /etc/restic/password,
# /root/.aws/credentials) when the file/profile mechanism is in use
# instead of inline secrets - grant read access to those too, same as
# above, rather than leaving this as a manual step discovered the hard
# way through Backrest's own "Add Repo" errors. Sourcing
# restic.env/secrets.env here only to read these variable names, not
# to run anything with them.
grant_ancestor_traversal() {
    # Walks up from $1's parent directory to /, granting `backrest`
    # execute (traverse) access at each level - needed however deep
    # the actual path turns out to be (e.g. /root/.aws/credentials).
    local dir
    dir="$(dirname "$1")"
    while [[ "$dir" != "/" && "$dir" != "." ]]; do
        setfacl -m u:backrest:x "$dir"
        dir="$(dirname "$dir")"
    done
}

if [[ -r /etc/restic/restic.env ]]; then
    # shellcheck disable=SC1091
    source /etc/restic/restic.env
    if [[ -n "${RESTIC_SECRETS_FILE:-}" && -r "$RESTIC_SECRETS_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$RESTIC_SECRETS_FILE"
    fi
    if [[ -n "${RESTIC_PASSWORD_FILE:-}" ]]; then
        grant_ancestor_traversal "$RESTIC_PASSWORD_FILE"
        setfacl -m u:backrest:r "$RESTIC_PASSWORD_FILE"
        echo "    granted backrest read access to RESTIC_PASSWORD_FILE (${RESTIC_PASSWORD_FILE})"
    fi
    if [[ -n "${AWS_PROFILE:-}" ]]; then
        # Defaults to root's own credentials file, since none of the
        # restic-backup@.service/restic-maintenance.service units set
        # User= - they (and AWS_PROFILE) run as root. Adjust if that
        # ever changes.
        aws_creds_file="${AWS_SHARED_CREDENTIALS_FILE:-/root/.aws/credentials}"
        # NOT an ACL grant, unlike RESTIC_PASSWORD_FILE above -
        # confirmed experimentally (systemd-run reproducing
        # backrest.service's exact hardening) that ProtectHome=true
        # makes /root invisible to this service no matter what ACL is
        # granted: ACLs are a DAC permission check, irrelevant once
        # systemd's own mount namespace hides the path entirely before
        # any permission check happens. The only fix is a copy living
        # outside /root, under /etc/restic (never masked by
        # ProtectHome). Acceptable since these credentials are
        # static/rarely rotated - re-run this installer after rotating
        # them to refresh the copy, and update any already-configured
        # repo's own "Env" (AWS_SHARED_CREDENTIALS_FILE=...) to point
        # here instead of the original path.
        if [[ -r "$aws_creds_file" ]]; then
            install -m 0600 -o backrest -g backrest "$aws_creds_file" /etc/restic/backrest-aws-credentials
            echo "    copied AWS_PROFILE's credentials file to /etc/restic/backrest-aws-credentials"
            echo "    (point this repo's own Env at AWS_SHARED_CREDENTIALS_FILE=/etc/restic/backrest-aws-credentials, not the original path)"
        else
            echo "WARNING: AWS_PROFILE is set but ${aws_creds_file} isn't readable - skipping the Backrest copy." >&2
        fi
    fi
fi

echo "==> Installing systemd unit"
install -m 0644 "${REPO_ROOT}/systemd/backrest.service" /etc/systemd/system/backrest.service
systemctl daemon-reload

cat <<'EOF'

==> Backrest installed, but NOT started.
No secrets to fill in - it reads /etc/restic/restic.env and
/etc/restic/secrets.env directly (read access just granted via ACL),
the same files and credentials the real backups already use.

Before starting it, confirm the system restic binary is at
/usr/bin/restic (`which restic`); if not, edit
BACKREST_RESTIC_COMMAND in systemd/backrest.service and
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
    password field empty - the service environment already has
    whichever of RESTIC_PASSWORD_FILE or RESTIC_PASSWORD this host's
    restic.env/secrets.env actually resolve to, so Backrest picks it
    up the same way restic itself does. Do NOT add a "Plan" - that
    would schedule Backrest's own backups/retention on top of the
    dispatcher/timers already running here.
  - Stick to the snapshot list view. Avoid "browse files"/"restore" in
    Backrest - this repository's S3 Glacier storage class means
    reading actual file contents needs the deliberately manual
    `resticctl verify --target` workflow instead.
EOF
