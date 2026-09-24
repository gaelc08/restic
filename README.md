# restic backup automation for mounted shares -> S3 Glacier

Automates daily restic backups of locally-mounted shares into an S3
(Glacier storage class) repository, plus daily retention/maintenance,
via systemd services and timers. Built against
[restic's manual](https://restic.readthedocs.io/en/latest/).

## What's here

```
config/     Example config files - copy to /etc/restic/, then edit
bin/        The actual scripts (installed to /opt/restic/bin)
systemd/    Service + timer units (installed to /etc/systemd/system)
logrotate/  Log rotation for /var/log/restic
docs/       Notes on the S3 Glacier specifics
install.sh  Installs everything above onto this host
```

## The `resticctl` CLI

Everything below can also be driven through one command with verb
subcommands - `install.sh` links it onto `PATH`
(`/usr/local/sbin/resticctl`), so it's callable from anywhere once
installed:

```sh
resticctl backup [--manual] [share-path]  # backup all shares, or just one
resticctl maintenance           # apply retention + prune + check
resticctl list [flags...]       # list snapshots (restic snapshots flags)
resticctl delete [flags...]     # remove snapshot(s), see below
resticctl verify [share-path]   # prove backups are actually restorable, see below
resticctl version               # what commit is deployed
resticctl status                # timer schedule + each service's last run/status
resticctl help
```

It's a thin dispatcher, not a reimplementation - `resticctl backup` is
exactly `restic-backup.sh`, `resticctl list` is exactly
`restic-snapshots.sh`, and so on, each documented in detail below.
Use whichever is more convenient; both work identically, including
from cron, other scripts, or systemd (which still calls the
underlying scripts directly, not through `resticctl`).

## How it fits together

- **restic-backup.timer** fires **restic-backup.service** daily at
  01:00 (+ up to 10 min random delay), which runs
  `/opt/restic/bin/restic-backup.sh`. That script verifies every
  configured share is actually mounted, then backs up **each share as
  its own `restic backup` call** - one snapshot per share, per run
  (not one combined multi-path snapshot) - so each can carry its own
  retention policy.
- **restic-maintenance.timer** fires **restic-maintenance.service**
  daily at 00:00 (midnight, the last job of the day), which runs
  `/opt/restic/bin/restic-maintenance.sh`: applies **each share's own
  retention policy** (`restic forget --path <share> --keep-...`, once
  per share), then a single repository-wide `restic prune
  --max-repack-size 0`, then an optional metadata-only `restic check`.
- **Backup and maintenance never run at the same time.** Both scripts
  take the same exclusive lock (`RESTIC_LOCK_FILE`,
  `/run/restic/restic.lock` by default) before touching the
  repository:
  - if maintenance fires while a backup is still running, it logs
    that, exits immediately without doing anything, and simply tries
    again at its next scheduled run;
  - if a backup fires while maintenance is still finishing up, it
    waits up to `RESTIC_BACKUP_LOCK_TIMEOUT` seconds (default 300) for
    the lock, then fails loudly (non-zero exit, logged) if maintenance
    still hasn't released it.
- Both scripts source `/etc/restic/restic.env` (and
  `/etc/restic/secrets.env`, chmod 600, holding the repo password and
  AWS credentials together) for configuration, and log every run to
  `/var/log/restic/{backup,maintenance}.log` as well as the systemd
  journal (`journalctl -u restic-backup.service`).
- **`restic-verify.sh` / `resticctl verify`** (see "Restore
  verification" below) samples a few files from each share's latest
  snapshot and proves they're actually restorable, not just present.
  It has no systemd unit and no timer - manual/on-demand only, since a
  real Glacier/tape restore can take minutes to many hours.
- **Every job reports its outcome two ways**: a status file
  (`RESTIC_STATUS_DIR`, always written, zero config needed) any
  external monitoring can poll, and an optional email/webhook
  notification on failure (or always, if configured) - see
  "Alerting on failure" below.
- `restic-snapshots.sh` is a standalone script (and sourceable shell
  function) to list snapshots on demand.

## Requirements

- `restic` (recent enough to support `--pack-size`, `--read-concurrency`
  and `-o s3.connections` / `-o s3.storage-class`)
- `bash`, `systemd`, `logrotate`, `mountpoint`, `flock`, `timeout`
  (util-linux/coreutils, almost always already present)
- `jq` and `shuf` (coreutils) - used by `restic-snapshots.sh --latest-id`
  and required by `restic-verify.sh`
- `mail`/`sendmail` and/or `curl`, only if you enable email or webhook
  failure notifications (`RESTIC_NOTIFY_EMAIL` / `RESTIC_NOTIFY_WEBHOOK_URL`)

## Install

```sh
sudo ./install.sh
```

This copies the scripts, systemd units and logrotate config into
place, and seeds `/etc/restic/*` from the `config/*.example` files
**without enabling the timers** - it will not touch an existing
`/etc/restic/restic.env`.

Then:

1. Edit `/etc/restic/restic.env` - at minimum set `RESTIC_REPOSITORY`.
   Defaults already match what was requested:
   ```
   RESTIC_CACHE_DIR="/opt/restic/restic-cache"
   RESTIC_TMP_DIR="/opt/restic/restic-tmp"
   RESTIC_PACK_SIZE=64
   ```
2. Edit `/etc/restic/secrets.env` (chmod 600, root-only) with the
   repository password and your AWS access key/secret (ideally a
   dedicated IAM user scoped to just this bucket/prefix).
3. Edit `/etc/restic/retention-policies.conf` to define your policies
   (short/mid/long, or whatever names you want), then
   `/etc/restic/shares.conf` to list each share's mount point and
   which policy it uses. See [Per-share retention](#per-share-retention-short-mid-long-or-your-own-names)
   below.
4. Edit `/etc/restic/excludes.txt` as needed.
5. If the repository doesn't exist yet, initialize it with the same
   pack size and storage class the automation will use:
   ```sh
   set -a; source /etc/restic/restic.env; source /etc/restic/secrets.env; set +a
   restic init --pack-size "$RESTIC_PACK_SIZE" -o s3.storage-class="$RESTIC_S3_STORAGE_CLASS"
   ```
6. Enable and start the daily timers:
   ```sh
   systemctl enable --now restic-backup.timer
   systemctl enable --now restic-maintenance.timer
   ```

## Configuration reference (`/etc/restic/restic.env`)

| Variable | Purpose |
|---|---|
| `RESTIC_REPOSITORY` | `s3:...` repository URL |
| `RESTIC_SECRETS_FILE` | path to the combined password + AWS credentials file |
| `RESTIC_S3_STORAGE_CLASS` | S3 storage class for written objects (`GLACIER`) |
| `RESTIC_S3_CONNECTIONS` | concurrent S3 connections (backend parallelism, `-o s3.connections`) |
| `RESTIC_PACK_SIZE` | target pack size in MiB (`--pack-size`) |
| `RESTIC_READ_CONCURRENCY` | concurrent file reads during backup (`--read-concurrency`) |
| `RESTIC_CACHE_DIR` | restic's local metadata cache |
| `RESTIC_TMP_DIR` | scratch dir; exported as `TMPDIR` for restic (see below) |
| `SHARES_FILE` | each share's mount point + retention policy name (see below) |
| `RETENTION_POLICIES_FILE` | named retention policies (see below) |
| `EXCLUDE_FILE` | `--exclude-file` patterns, applied to every share |
| `RESTIC_BACKUP_TAG` | tag applied to snapshots created by the job |
| `REQUIRE_MOUNTED` | abort backup if a configured share isn't mounted |
| `RESTIC_MAINTENANCE_EXTRA_ARGS` | extra flags for the maintenance `prune` (default `--max-repack-size 0`, required for Glacier/tape) |
| `RESTIC_RUN_CHECK` | run metadata-only `restic check` after prune |
| `RESTIC_LOCK_FILE` | shared lock preventing backup/maintenance overlap |
| `RESTIC_BACKUP_LOCK_TIMEOUT` | seconds backup waits for the lock before failing |
| `LOG_DIR`, `*_LOG_FILE` | log locations |
| `RESTIC_JSON_LOG` | emit `restic backup --json` progress into the log |

**Why `RESTIC_TMP_DIR` and not `TMPDIR`:** restic (and the Go runtime
underneath it) actually reads the standard `TMPDIR` environment
variable for scratch space - there is no native `RESTIC_TMP_DIR`.
`bin/restic-common.sh` keeps the `RESTIC_TMP_DIR` name you asked for
in the config file, and exports it as `TMPDIR` internally so restic
picks it up correctly.

**If you change `RESTIC_CACHE_DIR` or `RESTIC_TMP_DIR`** away from the
`/opt/restic/restic-cache` / `/opt/restic/restic-tmp` defaults, also
update `ReadWritePaths=` in both `systemd/restic-backup.service` and
`systemd/restic-maintenance.service` to match, and `mkdir` the new
paths yourself. Systemd bind-mounts everything in `ReadWritePaths=`
into the service's sandbox *before* `ExecStart` runs, so - unlike the
script's own `mkdir -p` - it never creates a missing directory; it
just fails the unit with `226/NAMESPACE`
("Failed to set up mount namespacing: ... No such file or
directory"). `install.sh` creates the default paths for you, but a
custom path is on you to create.

### Parallelism knobs

Two independent settings control parallelism, per the requirement to
make it customizable:

- `RESTIC_READ_CONCURRENCY` (`--read-concurrency`): how many files
  restic reads/chunks in parallel from the source shares during
  backup.
- `RESTIC_S3_CONNECTIONS` (`-o s3.connections`): how many concurrent
  connections the S3 backend uses to upload/download pack files.

### Per-share retention (short/mid/long, or your own names)

Every share can use a different retention policy. Two files work
together:

**`retention-policies.conf`** defines named policies as
`name keep_daily keep_weekly keep_monthly keep_yearly`:

```
# name    daily  weekly  monthly  yearly
short     30     0       0        0
mid       14     12      6        0
long      7      8       24       7
```

**`shares.conf`** assigns one policy per share:

```
# path                     policy
/mnt/share-finance         long
/mnt/share-engineering     mid
/mnt/share-hr              short
```

Add as many policies and shares as you need - the names `short`/
`mid`/`long` are just the shipped defaults (chosen to mirror
Cohesity's tiers), not special-cased anywhere in the scripts. A share
with an unknown policy name causes both backup and maintenance to
abort loudly rather than silently apply the wrong retention.

**Why one snapshot per share is required:** restic's `forget`/`prune`
act on whole snapshots, not on sub-paths within one. To let two shares
keep different histories, each must own its own snapshots that
`restic forget --path <share>` can select independently - so
`restic-backup.sh` runs `restic backup <path>` once per share (see
`bin/restic-common.sh` for the full explanation), rather than passing
every share to a single combined `restic backup` call.

### Maintenance and `--max-repack-size 0`

`bin/restic-maintenance.sh`, once per share:

```
restic forget --path <share> --group-by host,paths \
    --keep-daily N --keep-weekly N --keep-monthly N --keep-yearly N
```

using that share's own numbers from `retention-policies.conf`, then
once for the whole repository:

```
restic prune --max-repack-size 0
```

`--max-repack-size 0` is mandatory for a Glacier/tape-backed
repository: it stops prune from repacking (rewriting) partially-used
pack files, which would otherwise require reading archived data back
from Glacier/tape. Prune still deletes fully-unreferenced packs. See
`docs/glacier-notes.md` for the full explanation, plus how the
metadata objects (`config`/`keys`/`index`/`snapshots`) are kept
readable so daily operations never need a Glacier restore.

## Listing snapshots

```sh
/opt/restic/bin/restic-snapshots.sh                    # snapshots grouped by share
/opt/restic/bin/restic-snapshots.sh --host myhost
/opt/restic/bin/restic-snapshots.sh --path /mnt/share-finance
/opt/restic/bin/restic-snapshots.sh --json              # flat, ungrouped, for scripting
/opt/restic/bin/restic-snapshots.sh --latest-id         # just the newest snapshot's short ID
```

By default this adds `--group-by paths`, so restic prints a header
naming each share's path before listing that share's snapshots
underneath it - rather than one flat table where you have to spot the
right `share:<name>` tag in a crowded `Tags` column. Since every share
is backed up as its own snapshot, grouping by path is effectively
grouping by share (the exact header wording/format is restic's own and
varies a bit by version, but it always names the path(s) in that
group before the table for it).

Pass your own `--group-by` to override this, or `--json` to get
restic's normal flat (ungrouped) array back for scripting - both skip
the default grouping so existing automation isn't affected.

Any flags accepted by `restic snapshots` can be passed through
directly. It can also be sourced to get a `restic_list_snapshots()`
shell function for use in other scripts:

```sh
RESTIC_SNAPSHOTS_SOURCED=1 source /opt/restic/bin/restic-snapshots.sh
restic_list_snapshots --json --host myhost
```

## Removing snapshots manually

`restic-forget.sh` is a safety-wrapped `restic forget` for ad-hoc
cleanup (test snapshots, mistakes, one-off removals) - the automated
daily retention already runs on its own via `restic-maintenance.sh`,
this is only for manual intervention outside that schedule.

```sh
# by snapshot ID (from restic-snapshots.sh)
sudo /opt/restic/bin/restic-forget.sh 35f79137 740bba99

# or with restic's own filter/policy flags
sudo /opt/restic/bin/restic-forget.sh --tag share:test --keep-last 1
```

It always shows what would be removed first (`restic forget
--dry-run`) and asks for confirmation before doing anything - pass
`--yes` to skip the prompt for non-interactive use (required when
there's no TTY, e.g. from another script). By default it also runs
`restic prune --max-repack-size 0` immediately afterward to actually
reclaim the space (same `--max-repack-size 0` requirement as
`restic-maintenance.sh` - see `docs/glacier-notes.md`); pass
`--no-prune` to skip that and batch several forget runs before a
single prune. Like backup and maintenance, it takes the shared lock
(`RESTIC_LOCK_FILE`) so it can't run concurrently with either, and
logs everything to `maintenance.log`.

**This is destructive and, once pruned, irreversible** - double-check
the dry-run output and the snapshot IDs before confirming.

## Restore verification

`restic check` (run as part of daily maintenance) only validates
repository metadata - it never proves a file can actually be read back
out. `restic-verify.sh` / `resticctl verify` closes that gap: for each
configured share, it takes the latest snapshot and samples a handful
of files (`RESTIC_VERIFY_SAMPLE_FILES`, default 3).

```sh
resticctl verify --target /path/with/free/space                       # every configured share
resticctl verify --target /path/with/free/space /mnt/share-finance    # just one share
```

**Confirmed against this repo's real destination
(`scrat-1.ctie.etat.lu`): reads need an explicit tape recall first**,
same as true AWS Glacier. `RESTIC_VERIFY_USE_S3_RESTORE` defaults to
`true` accordingly, which makes `restic-verify.sh` drive restic's own
Glacier-restore mechanism for the sampled files:

```sh
# 1. trigger the tape recall (confirmed: this call itself reliably
#    FAILS on this destination, even though the recall proceeds
#    anyway in the background on the gateway's own cache - so its
#    exit code is logged but never treated as fatal)
RESTIC_FEATURES=s3-restore restic restore <snapshot> \
    -o s3.enable-restore=1 -o s3.restore-days=<N> -o s3.restore-timeout=<duration> \
    --target <target> --include <file> [--include <file> ...]

# 2. plain restore - ONE attempt only. If the tape hasn't finished
#    landing the data yet, this fails and the run is reported as
#    failed - there is deliberately no internal retry/poll loop (that
#    would just be a schedule under a different name). Re-run the
#    whole command yourself later to check again.
restic restore <snapshot> --target <target> --include <file> ...
```

All sampled files for a share are restored in **one** such pair of
calls (multiple `--include` flags), not one pair per file. Restored
files land under `--target` just long enough to confirm each landed
with non-zero size, then that sample is deleted again - on every code
path, success or failure (only this run's own restored files are
removed, never anything else already in `--target`).

**`--target <path>` is a required argument, every time - there is no
configured or default location.** This is intentionally a manual,
deliberate restore test: you decide where there's real free disk space
each time you run it, rather than relying on a fixed setting that
could go stale or point somewhere without room. `/opt/restic` does not
have enough room for this on this host, so don't point it there.

Tune:
- `RESTIC_VERIFY_RESTORE_DAYS` - how long the thawed copy stays warm
  on the Glacier side.
- `RESTIC_VERIFY_RESTORE_TIMEOUT` - passed as-is to restic's own
  `-o s3.restore-timeout` on the trigger call (a Go duration like
  `24h`, `90m`, `1h30m`). It doesn't control anything on our side -
  there's no retry loop here to bound.
- `RESTIC_VERIFY_ATTEMPT_TIMEOUT` - max seconds any single restic call
  (the trigger, or the one plain-restore attempt) may run before being
  killed (default 120).

If your destination instead serves reads transparently (no restore
step needed), set `RESTIC_VERIFY_USE_S3_RESTORE=false` to fall back to
the older, cheaper approach: streaming each sampled file straight back
with `restic dump` under `RESTIC_VERIFY_TIMEOUT` (default 300s).

**There is no systemd timer for this, on purpose.** A real Glacier/
tape restore can take anywhere from minutes to many hours depending on
the robot, and running that unattended on a schedule was judged too
risky - `restic-verify.sh` is a manual/on-demand tool only. Run it by
hand whenever you actually want to check.

A share with zero snapshots is reported as a failure too (nothing to
verify means something's wrong, not nothing to do), and an empty
snapshot (no files) is logged as a skip, not a failure.

## Alerting on failure

Every job (backup, maintenance, verify) reports its outcome two ways,
configured in `restic.env`:

1. **A status file**, always written regardless of any other config -
   `${RESTIC_STATUS_DIR}/<job>.status` (default
   `/var/log/restic/status/{backup,maintenance,verify}.status`), a
   simple `KEY=value` file:
   ```
   JOB=backup
   STATUS=success
   TIMESTAMP=2026-09-23T16:12:07+02:00
   HOST=manny-01
   SUMMARY=restic backup on manny-01 completed successfully in 42s (3 share(s)).
   ```
   `STATUS` is one of `success`, `warning`, `failure`, or `skipped`
   (maintenance finding a backup still running - not a failure). This
   needs zero configuration and is meant to be polled by whatever
   monitoring you already have (Nagios, Zabbix, a cron job that greps
   `STATUS=`, ...) - also viewable via `resticctl status`.

2. **Email and/or webhook notifications**, opt-in:
   ```sh
   RESTIC_NOTIFY_EMAIL="ops-team@example.lu"
   RESTIC_NOTIFY_WEBHOOK_URL="https://hooks.example.com/incoming/..."   # Slack/Teams-style {"text": "..."}
   RESTIC_NOTIFY_ON="failure"    # or "always" for a daily success ping too
   ```
   Email goes through whatever local `mail`/`sendmail` is configured
   on the host (a local MTA/relay must actually exist - if neither
   command is installed, or no relay is configured, the job logs an
   error about it but still completes normally; a notification failure
   never fails the backup/maintenance job itself). Leave a channel
   empty to disable it - both are independent and optional. By
   default (`RESTIC_NOTIFY_ON=failure`) you only hear about failures
   and warnings, not a confirmation on every routine success.

## Logging

Every run of every job is logged with timestamps to:

- `/var/log/restic/backup.log`
- `/var/log/restic/maintenance.log`
- `/var/log/restic/verify.log`

and mirrored to the systemd journal (`journalctl -u restic-backup -u
restic-maintenance -u restic-verify`). `logrotate/restic` (installed to
`/etc/logrotate.d/restic`) rotates these daily and keeps 90 days,
compressed.

## Checking the deployed version

`install.sh` stamps exactly which commit it deployed into
`/opt/restic/bin/VERSION` - no manually-bumped version number to
forget to update, since it's just read straight from git at install
time:

```sh
cat /opt/restic/bin/VERSION
```

```
commit:      aefe587
branch:      claude/amazing-ptolemy-8a49lf
commit date: 2026-09-23T14:32:05+00:00
installed:   2026-09-23T16:40:12+02:00
```

To check whether that's actually the latest, compare `commit` above
against the branch's head commit - either on your synced checkout
(`git -C /opt/restic/src log -1 --oneline`) or on GitHub. If they
match, you're up to date; if not, sync and re-run `./install.sh`
(see "Updating a deployment" below). `commit` also gets a `(with
local uncommitted changes)` suffix if `/opt/restic/src` had
uncommitted edits at install time - a sign something was hand-patched
outside of git.

If `/opt/restic/src` isn't a git checkout at all (e.g. a bare tarball
extract with no `.git`), `VERSION` says so explicitly rather than
showing stale or misleading info.

## Updating a deployment

```sh
cd /opt/restic/src
git pull                # or: re-sync from your laptop, see below
sudo ./install.sh       # re-stamps VERSION, overwrites bin/*.sh and the
                         # systemd units, leaves /etc/restic/* untouched
```

If the server can't reach GitHub directly, sync from a machine that
can instead (`git pull` there, then `rsync -avz --delete` the checkout
across), then run `install.sh` on the server as above.

## Operational checks

```sh
systemctl list-timers 'restic-*'                 # next scheduled runs
systemctl status restic-backup.service
systemctl status restic-maintenance.service
journalctl -u restic-backup.service -n 100
tail -f /var/log/restic/backup.log
/opt/restic/bin/restic-snapshots.sh
```

To run a job on demand outside its schedule:

```sh
sudo systemctl start restic-backup.service
sudo systemctl start restic-maintenance.service
```

Snapshots created this way still get the `RESTIC_BACKUP_TAG` value
(`"scheduled"` by default) - systemd has no way to tell "the timer
fired this" apart from "an admin ran `systemctl start`", so the tag
doesn't change based on how the service was started. To run an ad-hoc
backup and have it clearly labeled as such instead, bypass systemd and
invoke the script directly with `--manual`:

```sh
sudo /opt/restic/bin/restic-backup.sh --manual
```

which tags the resulting snapshot(s) `manual` instead of `scheduled`
(the per-share `share:<name>` and `policy:<name>` tags are unaffected).

To back up just one share instead of every configured one, add its
path (in either order relative to `--manual`):

```sh
resticctl backup /mnt/share-finance
resticctl backup --manual /mnt/share-finance
```

An unrelated share being missing or unmounted never blocks a
single-share run - only the requested share's mount status is checked.

## Development

CI (`.github/workflows/ci.yml`) runs shellcheck and `bash -n` on
`install.sh` and every script in `bin/` on each push and pull request.
To run the same locally:

```sh
shellcheck install.sh bin/*.sh bin/resticctl
```

`.shellcheckrc` makes shellcheck follow the `source` of
`restic-common.sh`, so no extra flags are needed.
