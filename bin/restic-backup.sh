#!/usr/bin/env bash
# Run a restic backup of one or all configured mounted shares against
# the S3 (Glacier) repository. Each share is backed up as its own
# `restic backup <path>` call, i.e. its own snapshot, tagged with the
# share's name and retention policy. This is required so
# restic-maintenance.sh can apply a different retention policy per
# share (restic forget/prune act on whole snapshots, not on sub-paths
# within one) - see restic-common.sh.
#
# Intended to be run per share, in parallel, by one instance of the
# restic-backup@.service template unit per configured share - started
# by restic-backup-dispatch.sh (restic-backup.service/.timer), which
# fires daily and starts one instance per share currently in
# shares.conf - NOT by one single service looping over every share
# sequentially. restic itself supports
# multiple concurrent `backup` runs against the same repository (see
# acquire_lock in restic-common.sh), so this is a real fix for a real
# failure mode: with one sequential service, a single share that takes
# longer than a day (first upload of a large share, a slow link) would
# leave the whole job still running at the next day's scheduled start,
# and - since systemd won't start a second instance of a unit that's
# still active - silently skip that entire day's backup for every
# other share too, not just the slow one. One unit instance per share
# means a slow share only ever blocks its own next run, never anyone
# else's.
#
# Being started in parallel is not the same as actually running
# `restic backup` in parallel without limit, though:
# acquire_backup_slot() (restic-common.sh) bounds how many instances
# are doing that memory-heavy part at once to
# RESTIC_BACKUP_MAX_PARALLEL, queuing the rest - every share being
# dispatched at the same moment previously caused an OOM (and a
# reboot) on manny-01, since several concurrent multi-GB `restic
# backup` processes add up to more memory than the host actually has.
#
# Exit codes: 0 if every requested share backed up cleanly, 3 if every
# share succeeded but at least one completed with restic's own "some
# source files could not be read" warning (its exit code 3), 1 if any
# share failed outright. See
# https://restic.readthedocs.io/en/latest/040_backup.html#exit-status-codes
#
# Usage: restic-backup.sh [--manual] [share-name-or-path]
#   --manual tags the run "manual" instead of RESTIC_BACKUP_TAG
#   ("scheduled" by default). Systemd gives no reliable way to tell a
#   timer-triggered start apart from an admin running `systemctl
#   start restic-backup@<share>.service` - both look identical from
#   inside the service - so this is opt-in rather than auto-detected:
#   pass --manual when you deliberately want an ad-hoc run labeled as
#   such, e.g. `sudo /opt/restic/bin/restic-backup.sh --manual`.
#   share-name-or-path restricts the run to just that one share instead
#   of every configured share - either its full path from shares.conf,
#   or just its share name (the path's basename, e.g. "finance" for
#   /mnt/share-finance) - this is what restic-backup@.service passes
#   as %i, since systemd instance names can't contain "/". Omit it to
#   back up every configured share sequentially in one process (handy
#   for an ad-hoc full run; the parallel path is one instance per share,
#   not this).

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/restic-common.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/netapp-common.sh"

LOG_FILE="${BACKUP_LOG_FILE:-${LOG_DIR}/backup.log}"

# --- NetApp snapshot-then-backup cleanup ------------------------------------
#
# One trap for the whole process's lifetime rather than one per share:
# simpler, and it still protects a share's bind-mount/snapshot from
# being left behind if this script is killed mid-backup (systemd stop,
# OOM, ...), not just on a normal/expected failure path. The
# _netapp_active_* variables name whatever (if anything) is currently
# "open" for the share being processed right now; cleanup_netapp_share
# is a no-op when none are set, so it's always safe to call, on every
# exit path, whether or not the current share even uses this feature.
_netapp_active_mount=""
_netapp_active_svm=""
_netapp_active_volume=""
_netapp_active_snapname=""

cleanup_netapp_share() {
    if [[ -n "$_netapp_active_mount" ]]; then
        umount "$_netapp_active_mount" 2>>"$LOG_FILE" \
            || log_error "failed to unmount NetApp snapshot bind-mount at $_netapp_active_mount - it may still be showing frozen snapshot content"
        _netapp_active_mount=""
    fi
    if [[ -n "$_netapp_active_svm" ]]; then
        netapp_delete_snapshot "$_netapp_active_svm" "$_netapp_active_volume" "$_netapp_active_snapname" \
            || log_error "failed to delete NetApp snapshot $_netapp_active_snapname on ${_netapp_active_svm}:${_netapp_active_volume} - delete it by hand once the cluster is reachable again"
        _netapp_active_svm=""
    fi
}

# --- "is a backup of this share running right now" marker -------------------
#
# resticctl status can only ask systemd whether
# restic-backup@<share>.service is active - which tells it nothing
# about a manual, ad-hoc run (`resticctl backup --manual <share>`,
# `restic-backup.sh` invoked directly), since those run as a plain
# process, never through that systemd template instance. Without this,
# resticctl status falls back to whatever this share's last *completed*
# run recorded, silently stale for as long as a current manual run is
# in progress - confirmed on manny-01, where it kept showing a finished
# run from several minutes earlier while a second manual run of the
# same share was actively under way.
#
# A plain marker file (this share's own PID) that resticctl checks for
# liveness with `kill -0` rather than just existence, so a leftover
# marker from a run that was killed outright (SIGKILL, power loss - the
# EXIT trap below never fires for those) doesn't wrongly read as
# "still running" forever.
_running_marker=""
mark_share_running() {
    _running_marker="${RESTIC_STATUS_DIR}/backup-$1.running"
    echo "$$" > "$_running_marker" 2>/dev/null || true
}
clear_share_running() {
    [[ -n "$_running_marker" ]] && rm -f "$_running_marker"
    _running_marker=""
}

trap 'cleanup_netapp_share; clear_share_running' EXIT

RUN_TAG="${RESTIC_BACKUP_TAG:-scheduled}"
ONLY_PATH=""
for arg in "$@"; do
    case "$arg" in
        --manual) RUN_TAG="manual" ;;
        *) ONLY_PATH="${arg%/}" ;;
    esac
done

START_TS=$(date +%s)
log_info "===== restic backup starting (repo: ${RESTIC_REPOSITORY}, run tag: ${RUN_TAG}) ====="

parse_shares_file
if [[ -n "$ONLY_PATH" ]]; then
    # Filter down to just the requested share *before* the mount check,
    # so an unrelated share being unmounted can't block a single-share
    # run - only the share(s) we're actually about to back up matter.
    filtered_paths=()
    filtered_policies=()
    for i in "${!SHARE_PATHS[@]}"; do
        if [[ "${SHARE_PATHS[$i]}" == "$ONLY_PATH" ]]; then
            filtered_paths+=("${SHARE_PATHS[$i]}")
            filtered_policies+=("${SHARE_POLICIES[$i]}")
        fi
    done
    if [[ ${#filtered_paths[@]} -eq 0 ]]; then
        # No exact path matched - try matching by share name (the
        # path's basename) instead, since that's all a systemd
        # instance name can carry (no "/").
        for i in "${!SHARE_PATHS[@]}"; do
            if [[ "$(basename "${SHARE_PATHS[$i]}")" == "$ONLY_PATH" ]]; then
                filtered_paths+=("${SHARE_PATHS[$i]}")
                filtered_policies+=("${SHARE_POLICIES[$i]}")
            fi
        done
    fi
    if [[ ${#filtered_paths[@]} -eq 0 ]]; then
        die "no share matching '$ONLY_PATH' found in shares.conf (checked full paths and share names)"
    elif [[ ${#filtered_paths[@]} -gt 1 ]]; then
        die "share name '$ONLY_PATH' matches more than one entry in shares.conf (${filtered_paths[*]}) - use the full path instead"
    fi
    SHARE_PATHS=("${filtered_paths[@]}")
    SHARE_POLICIES=("${filtered_policies[@]}")
fi

if ! check_shares_mounted; then
    log_error "===== restic backup aborted: invalid shares ====="
    notify backup failure "restic backup on $(hostname -f 2>/dev/null || hostname) aborted: one or more configured shares are missing or unmounted. See ${LOG_FILE}."
    exit 1
fi
log_info "shares: ${VALID_SHARE_PATHS[*]}"

netapp_load_mapping
netapp_load_svm_urls

RESTIC_BACKUP_LOCK_TIMEOUT="${RESTIC_BACKUP_LOCK_TIMEOUT:-300}"
if ! acquire_lock "$RESTIC_BACKUP_LOCK_TIMEOUT" shared; then
    log_error "===== restic backup aborted: could not acquire lock $RESTIC_LOCK_FILE within ${RESTIC_BACKUP_LOCK_TIMEOUT}s (maintenance running?) ====="
    notify backup failure "restic backup on $(hostname -f 2>/dev/null || hostname) aborted: could not acquire the repository lock within ${RESTIC_BACKUP_LOCK_TIMEOUT}s (maintenance stuck?). See ${LOG_FILE}."
    exit 1
fi
log_info "acquired lock $RESTIC_LOCK_FILE"

# Once per process, before the loop below - not once per share. For
# the normal one-share-per-systemd-instance case that loop only ever
# has one entry anyway, but for an ad-hoc no-argument run (every share
# sequentially in this one process) only one `restic backup` is ever
# actually running at a time regardless of how many shares it loops
# over, so it should only ever hold one concurrency slot for its whole
# duration - not grab a fresh one on every iteration without releasing
# the last (which would both leak slots and let one sequential run
# starve genuinely parallel ones).
acquire_backup_slot

FAILED=0
WARNED=0
FAILED_SHARES=()
WARNED_SHARES=()

for i in "${!VALID_SHARE_PATHS[@]}"; do
    path="${VALID_SHARE_PATHS[$i]}"
    policy="${VALID_SHARE_POLICIES[$i]}"
    share_name="$(basename "$path")"
    mark_share_running "$share_name"

    BACKUP_ARGS=(
        backup
        "${RESTIC_GLOBAL_ARGS[@]}"
        --read-concurrency "$RESTIC_READ_CONCURRENCY"
        --one-file-system
        --tag "${RUN_TAG}"
        --tag "share:${share_name}"
        --tag "policy:${policy}"
    )

    if [[ -n "${EXCLUDE_FILE:-}" && -r "${EXCLUDE_FILE:-}" ]]; then
        BACKUP_ARGS+=(--exclude-file "$EXCLUDE_FILE")
    fi

    if [[ "$RESTIC_JSON_LOG" == "true" ]]; then
        BACKUP_ARGS+=(--json)
    fi

    BACKUP_ARGS+=("$path")

    # If this share is mapped in NETAPP_VOLUMES_FILE, back up a frozen
    # NetApp Snapshot copy of it instead of its live, changing
    # filesystem - see "Backing up from a NetApp snapshot" in
    # README.md. Deliberately bind-mounted onto $path itself (not
    # backed up from a separate .snapshot/... path): restic records
    # whatever path it's given as that snapshot's own, and everything
    # downstream (restic forget --path, resticctl list --path, the
    # web report) depends on that path being the exact same string,
    # share after share, run after run - a bind-mount keeps $path
    # itself unchanged while swapping what it actually shows for the
    # duration of this one backup.
    if [[ -v "NETAPP_SVM[$path]" ]]; then
        svm="${NETAPP_SVM[$path]}"
        volume="${NETAPP_VOLUME[$path]}"
        netapp_snap_name="restic_backup_${share_name}"

        log_info "share '$share_name': snapshotting NetApp volume ${svm}:${volume} (snapshot '${netapp_snap_name}') before backup"
        if ! netapp_create_snapshot "$svm" "$volume" "$netapp_snap_name"; then
            msg="share '$share_name' backup FAILED (could not create NetApp snapshot ${netapp_snap_name} on ${svm}:${volume})"
            log_error "$msg"
            FAILED=1
            FAILED_SHARES+=("$share_name")
            write_status_file "backup-${share_name}" "failure" "$msg"
            clear_share_running
            continue
        fi
        _netapp_active_svm="$svm"
        _netapp_active_volume="$volume"
        _netapp_active_snapname="$netapp_snap_name"

        if ! mount --bind "${path}/.snapshot/${netapp_snap_name}" "$path" 2>>"$LOG_FILE"; then
            msg="share '$share_name' backup FAILED (bind-mounting the NetApp snapshot onto $path failed)"
            log_error "$msg"
            FAILED=1
            FAILED_SHARES+=("$share_name")
            write_status_file "backup-${share_name}" "failure" "$msg"
            cleanup_netapp_share
            clear_share_running
            continue
        fi
        _netapp_active_mount="$path"
    fi

    # Also tee restic's own output into a per-share progress file (one
    # per share, truncated fresh - tee's default, since it's given
    # without -a - at the start of each run) so `resticctl status` can
    # find a given share's latest --json status line unambiguously.
    # $LOG_FILE alone can't serve that: every restic-backup@<share>
    # instance appends to the exact same file, so once more than one
    # runs at a time their JSON lines interleave with no share/path
    # field of their own to tell them apart - confirmed on manny-01
    # once parallelism went from 4 to 8 shares at once.
    PROGRESS_FILE="${RESTIC_STATUS_DIR}/progress-${share_name}.json"
    log_info "backing up share '$share_name' (policy=$policy): running restic ${BACKUP_ARGS[*]}"
    restic "${BACKUP_ARGS[@]}" 2>&1 | tee "$PROGRESS_FILE" >>"$LOG_FILE"
    rc=${PIPESTATUS[0]}

    cleanup_netapp_share

    if [[ $rc -eq 0 ]]; then
        msg="share '$share_name' backup completed successfully"
        log_info "$msg"
        write_status_file "backup-${share_name}" "success" "$msg"
    elif [[ $rc -eq 3 ]]; then
        msg="share '$share_name' backup completed with warnings (some source files could not be read, exit 3)"
        log_warn "$msg"
        WARNED=1
        WARNED_SHARES+=("$share_name")
        write_status_file "backup-${share_name}" "warning" "$msg"
    else
        msg="share '$share_name' backup FAILED (exit $rc)"
        log_error "$msg"
        FAILED=1
        FAILED_SHARES+=("$share_name")
        write_status_file "backup-${share_name}" "failure" "$msg"
    fi
    clear_share_running
done

END_TS=$(date +%s)
DURATION=$((END_TS - START_TS))

if [[ $FAILED -eq 1 ]]; then
    RC=1
    log_error "restic backup finished in ${DURATION}s with at least one failed share"
    notify backup failure "restic backup on $(hostname -f 2>/dev/null || hostname) FAILED for share(s): ${FAILED_SHARES[*]} (after ${DURATION}s). See ${LOG_FILE}."
elif [[ $WARNED -eq 1 ]]; then
    RC=3
    log_warn "restic backup completed in ${DURATION}s; all shares backed up but at least one had warnings"
    notify backup warning "restic backup on $(hostname -f 2>/dev/null || hostname) completed in ${DURATION}s with warnings for share(s): ${WARNED_SHARES[*]} (some source files could not be read). See ${LOG_FILE}."
else
    RC=0
    log_info "restic backup completed successfully in ${DURATION}s"
    notify backup success "restic backup on $(hostname -f 2>/dev/null || hostname) completed successfully in ${DURATION}s (${#VALID_SHARE_PATHS[@]} share(s))."
fi

log_info "===== restic backup finished (exit $RC) ====="
exit $RC
