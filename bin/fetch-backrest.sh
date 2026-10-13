#!/usr/bin/env bash
# Run this on a machine WITH internet access (e.g. the laptop that
# runs ./update-manny.sh) - NOT on manny-01, which is on an isolated
# network and can't reach github.com.
#
# Downloads the pinned Backrest release into vendor/, verified against
# the checksum in bin/backrest-version.sh. vendor/*.tar.gz is
# gitignored (no point versioning a binary download in git), but
# ./update-manny.sh rsyncs the whole working tree regardless of what's
# tracked - so once this has run, the next ./update-manny.sh carries
# the tarball over to manny-01 for bin/install-backrest.sh to install
# from, entirely offline.
#
# Usage: bin/fetch-backrest.sh
# (no root needed - this only touches vendor/ inside the repo clone)

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." &>/dev/null && pwd)"
# shellcheck source=bin/backrest-version.sh
source "${SCRIPT_DIR}/backrest-version.sh"

VENDOR_DIR="${REPO_ROOT}/vendor"
DEST="${VENDOR_DIR}/${BACKREST_ASSET}"

mkdir -p "$VENDOR_DIR"

echo "==> Downloading Backrest ${BACKREST_VERSION}"
curl -fsSL -o "$DEST" "$BACKREST_URL"

echo "==> Verifying checksum"
echo "${BACKREST_SHA256}  ${DEST}" | sha256sum -c -

cat <<EOF

==> OK: ${DEST}
Next: run ./update-manny.sh as usual - it rsyncs this file to manny-01
along with everything else, and bin/install-backrest.sh there installs
from it without needing any network access on manny-01 itself.
EOF
