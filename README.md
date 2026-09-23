# restic backup automation for mounted shares -> S3 Glacier

Automates daily restic backups of locally-mounted shares into an S3
(Glacier storage class) repository, plus daily retention/maintenance,
via systemd services and timers. Built against
[restic's manual](https://restic.readthedocs.io/en/latest/).

## What's here

```
config/     Example config files - copy to /etc/restic/, then edit
bin/        The actual scripts (installed to /usr/local/bin)
systemd/    Service + timer units (installed to /etc/systemd/system)
logrotate/  Log rotation for /var/log/restic
docs/       Notes on the S3 Glacier specifics
install.sh  Installs everything above onto this host
```

## How it fits together

- **restic-backup.timer** fires **restic-backup.service** daily at
  01:00 (+ up to 10 min random delay), which runs
  `/usr/local/bin/restic-backup.sh`. That script verifies every
  configured share is actually mounted, then runs `restic backup`
  against all of them in one snapshot-per-run.
- **restic-maintenance.timer** fires **restic-maintenance.service**
  daily at 00:00 (midnight, the last job of the day), which runs
  `/usr/local/bin/restic-maintenance.sh`: applies the retention policy
  and prunes (`restic forget --prune --max-repack-size 0`), then an
  optional metadata-only `restic check`.
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
  `/etc/restic/aws-credentials.env`) for configuration, and log every
  run to `/var/log/restic/{backup,maintenance}.log` as well as the
  systemd journal (`journalctl -u restic-backup.service`).
- `restic-snapshots.sh` is a standalone script (and sourceable shell
  function) to list snapshots on demand.

## Requirements

- `restic` (recent enough to support `--pack-size`, `--read-concurrency`
  and `-o s3.connections` / `-o s3.storage-class`)
- `bash`, `systemd`, `logrotate`, `mountpoint`, `flock` (util-linux,
  almost always already present)
- `jq`, only needed for `restic-snapshots.sh --latest-id`

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
2. Edit `/etc/restic/aws-credentials.env` with your access key/secret
   (ideally a dedicated IAM user scoped to just this bucket/prefix).
3. Create `/etc/restic/password` (chmod 600) with the repository
   password.
4. Edit `/etc/restic/backup-paths.txt` with the mount points to back
   up, and `/etc/restic/excludes.txt` as needed.
5. If the repository doesn't exist yet, initialize it with the same
   pack size and storage class the automation will use:
   ```sh
   set -a; source /etc/restic/restic.env; source /etc/restic/aws-credentials.env; set +a
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
| `RESTIC_PASSWORD_FILE` | path to the repo password file |
| `AWS_CREDENTIALS_FILE` | path to the separate AWS secrets file |
| `RESTIC_S3_STORAGE_CLASS` | S3 storage class for written objects (`GLACIER`) |
| `RESTIC_S3_CONNECTIONS` | concurrent S3 connections (backend parallelism, `-o s3.connections`) |
| `RESTIC_PACK_SIZE` | target pack size in MiB (`--pack-size`) |
| `RESTIC_READ_CONCURRENCY` | concurrent file reads during backup (`--read-concurrency`) |
| `RESTIC_CACHE_DIR` | restic's local metadata cache |
| `RESTIC_TMP_DIR` | scratch dir; exported as `TMPDIR` for restic (see below) |
| `BACKUP_PATHS_FILE` | list of mount points to back up |
| `EXCLUDE_FILE` | `--exclude-file` patterns |
| `RESTIC_BACKUP_TAG` | tag applied to snapshots created by the job |
| `REQUIRE_MOUNTED` | abort backup if a configured share isn't mounted |
| `RESTIC_KEEP_DAILY/WEEKLY/MONTHLY/YEARLY` | retention (see below) |
| `RESTIC_MAINTENANCE_EXTRA_ARGS` | extra flags for `forget --prune` (default `--max-repack-size 0`, required for Glacier/tape) |
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

### Parallelism knobs

Two independent settings control parallelism, per the requirement to
make it customizable:

- `RESTIC_READ_CONCURRENCY` (`--read-concurrency`): how many files
  restic reads/chunks in parallel from the source shares during
  backup.
- `RESTIC_S3_CONNECTIONS` (`-o s3.connections`): how many concurrent
  connections the S3 backend uses to upload/download pack files.

### Retention (Cohesity-style short/mid/long)

Mapped onto restic's `forget --keep-*` policy tiers:

| Cohesity tier | restic flag | default |
|---|---|---|
| Short term | `--keep-daily` | 30 |
| Mid term | `--keep-weekly` + `--keep-monthly` | 12 + 12 |
| Long term | `--keep-yearly` | 7 |

Adjust the four `RESTIC_KEEP_*` values in `restic.env` to match your
actual Cohesity policy numbers. All snapshots are grouped by
`host,paths` (`--group-by host,paths`) so retention is applied
per-share, not across all shares combined.

### Maintenance and `--max-repack-size 0`

`bin/restic-maintenance.sh` always runs:

```
restic forget --keep-daily N --keep-weekly N --keep-monthly N --keep-yearly N \
    --group-by host,paths --prune --max-repack-size 0
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
/usr/local/bin/restic-snapshots.sh                    # all snapshots
/usr/local/bin/restic-snapshots.sh --host myhost
/usr/local/bin/restic-snapshots.sh --path /mnt/share-finance
/usr/local/bin/restic-snapshots.sh --json
/usr/local/bin/restic-snapshots.sh --latest-id         # just the newest snapshot's short ID
```

Any flags accepted by `restic snapshots` can be passed through
directly. It can also be sourced to get a `restic_list_snapshots()`
shell function for use in other scripts:

```sh
RESTIC_SNAPSHOTS_SOURCED=1 source /usr/local/bin/restic-snapshots.sh
restic_list_snapshots --json --host myhost
```

## Logging

Every run of both jobs is logged with timestamps to:

- `/var/log/restic/backup.log`
- `/var/log/restic/maintenance.log`

and mirrored to the systemd journal (`journalctl -u restic-backup -u
restic-maintenance`). `logrotate/restic` (installed to
`/etc/logrotate.d/restic`) rotates these daily and keeps 90 days,
compressed.

## Operational checks

```sh
systemctl list-timers 'restic-*'                 # next scheduled runs
systemctl status restic-backup.service
systemctl status restic-maintenance.service
journalctl -u restic-backup.service -n 100
tail -f /var/log/restic/backup.log
/usr/local/bin/restic-snapshots.sh
```

To run a job on demand outside its schedule:

```sh
sudo systemctl start restic-backup.service
sudo systemctl start restic-maintenance.service
```
