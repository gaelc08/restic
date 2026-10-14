#!/usr/bin/env bash
# Single source of truth for the pinned Backrest release, shared by
# bin/fetch-backrest.sh (run on a machine with internet access) and
# bin/install-backrest.sh (run on manny-01, which has none - see
# vendor/README.md). Bump both values together, by hand, after
# downloading and hashing the new release yourself - never just point
# at a moving "latest" tag.
# shellcheck disable=SC2034  # used by the scripts that source this file
BACKREST_VERSION="v1.14.1"
# shellcheck disable=SC2034  # used by the scripts that source this file
BACKREST_ASSET="backrest_Linux_x86_64.tar.gz"
# shellcheck disable=SC2034  # used by the scripts that source this file
BACKREST_SHA256="acc7835a9c55b3d254f0fa285cacbe87ac912cb7e069d0211924838020e6921c"
# shellcheck disable=SC2034  # used by the scripts that source this file
BACKREST_URL="https://github.com/garethgeorge/backrest/releases/download/${BACKREST_VERSION}/${BACKREST_ASSET}"
