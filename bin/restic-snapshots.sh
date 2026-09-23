#!/usr/bin/env bash
# List restic snapshots in the configured repository.
#
# Usage:
#   restic-snapshots.sh                     # snapshots grouped by share, newest last
#   restic-snapshots.sh --host myhost       # filter by host
#   restic-snapshots.sh --path /mnt/share1  # filter by source path
#   restic-snapshots.sh --last              # only the most recent snapshot per host/path group
#   restic-snapshots.sh --json              # machine-readable output (flat, ungrouped)
#   restic-snapshots.sh --latest-id         # print just the ID of the newest snapshot
#
# By default this adds `--group-by paths` so restic prints a header
# naming each share's path before listing that share's snapshots,
# instead of one flat table where the share is buried in the Tags
# column. Since every share is backed up as its own snapshot (see
# restic-backup.sh), grouping by path is effectively grouping by
# share. Pass your own --group-by to override this, or --json to get
# restic's normal flat (ungrouped) JSON array for scripting.
#
# Any additional arguments are passed straight through to
# `restic snapshots`, so all of restic's own flags
# (https://restic.readthedocs.io/en/latest/045_working_with_repos.html)
# are available.
#
# Can also be sourced (RESTIC_SNAPSHOTS_SOURCED=1 source
# restic-snapshots.sh) to get the restic_list_snapshots() shell
# function without it running immediately.

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/restic-common.sh"

# restic_list_snapshots [extra restic-snapshots args...]
#
# Thin wrapper around `restic snapshots` using the repository/backend
# settings from restic.env. Special-cases --latest-id to print just
# the newest snapshot's short ID (handy for scripting, e.g. feeding
# `restic restore <id>`). Defaults to --group-by paths (see header
# comment) unless the caller already passed their own --group-by or
# asked for --json.
restic_list_snapshots() {
    local args=("$@")

    for a in "${args[@]}"; do
        if [[ "$a" == "--latest-id" ]]; then
            command -v jq >/dev/null 2>&1 || { echo "restic-snapshots.sh --latest-id requires jq to be installed" >&2; return 1; }
            restic snapshots "${RESTIC_GLOBAL_ARGS[@]}" --json --latest 1 \
                | jq -r '.[0].short_id // empty'
            return $?
        fi
    done

    local has_group_by=0 has_json=0
    for a in "${args[@]}"; do
        case "$a" in
            --group-by|--group-by=*) has_group_by=1 ;;
            --json) has_json=1 ;;
        esac
    done
    if [[ $has_group_by -eq 0 && $has_json -eq 0 ]]; then
        args+=(--group-by paths)
    fi

    restic snapshots "${RESTIC_GLOBAL_ARGS[@]}" "${args[@]}"
}

if [[ "${RESTIC_SNAPSHOTS_SOURCED:-0}" != "1" ]]; then
    restic_list_snapshots "$@"
fi
