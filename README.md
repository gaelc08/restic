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
resticctl backup-all            # start every share's backup now, in parallel, in the background
resticctl add-share --type nfs|cifs --source <src> --mount <path> --policy <name>  # provision a new share, see below
resticctl migrate-host --target <user@host>  # copy this host's secrets/config to new hardware, see below
resticctl maintenance           # apply retention + prune + check
resticctl list [flags...]       # list snapshots (restic snapshots flags)
resticctl delete [flags...]     # remove snapshot(s), see below
resticctl verify --target <path> [share-path]  # prove backups are actually restorable, see below
resticctl report                # email the daily status digest, see below
resticctl version               # what commit is deployed
resticctl status                # which shares are backing up now (with progress), which are idle
resticctl help
```

It's a thin dispatcher, not a reimplementation - `resticctl backup` is
exactly `restic-backup.sh`, `resticctl list` is exactly
`restic-snapshots.sh`, and so on, each documented in detail below.
Use whichever is more convenient; both work identically, including
from cron, other scripts, or systemd (which still calls the
underlying scripts directly, not through `resticctl`).

## How it fits together

- **`restic-backup.timer` fires `restic-backup.service` once daily at
  01:00** (+ up to 10 min random delay) - but that service is just a
  thin *dispatcher* (`bin/restic-backup-dispatch.sh`): it reads
  `shares.conf` fresh every time it runs and, for each share, starts
  `restic-backup@<share>.service` - **a template unit, one instance
  per share** (e.g. `restic-backup@finance.service`) - with
  `systemctl start --no-block`, then exits within seconds. Each of
  those instances runs `/opt/restic/bin/restic-backup.sh <share-name>`,
  backing up just that one share as **its own `restic backup` call** -
  one snapshot per share, per run - so each can carry its own
  retention policy, *and* so N shares back up in parallel instead of
  one sequential job.
  This two-layer setup (one static timer, one dynamic instance per
  share) exists because of a real failure mode: with a single service
  looping over every share in-process, one share that takes longer
  than a day (first upload of a large share, a slow link) would still
  be running at the next day's scheduled start, and since systemd
  won't start a second instance of a unit that's still active, the
  *entire* next day's backup - every other share too - would silently
  be skipped. Making the dispatcher itself trivial (it only starts
  jobs, never waits on them) means *it* is never still active the next
  day; the actual per-share backups live in their own independent
  units, so a slow share only ever blocks its own next run. It also
  means a share added to `shares.conf` is picked up automatically at
  the next run - no per-share timer to separately enable.
  Trigger it on demand with `resticctl backup-all` (or
  `systemctl start --no-block restic-backup.service` to go through the
  timer's own unit) instead of waiting for 01:00.
- **restic-maintenance.timer** fires **restic-maintenance.service**
  daily at 23:00 (the last job of the day, 2 hours ahead of the 01:00
  backup dispatch for extra margin), which runs
  `/opt/restic/bin/restic-maintenance.sh`: applies **each share's own
  retention policy** (`restic forget --tag scheduled --path <share>
  --keep-...`, once per share), then a single repository-wide `restic
  prune --max-repack-size 0`, then an optional metadata-only `restic
  check`.
- **Backups run in parallel with each other, never with maintenance.**
  All of them take the same lock file (`RESTIC_LOCK_FILE`,
  `/run/restic/restic.lock` by default), but in different modes: every
  `restic-backup@<share>.service` instance takes it in *shared* mode
  (any number can hold it at once), while maintenance takes it in
  *exclusive* mode (waits for every backup to release it first, then
  blocks new ones) - restic itself allows concurrent `backup` runs
  against one repository, just never alongside a `prune`. See
  `acquire_lock()` in `bin/restic-common.sh`.
  - if maintenance fires while any backup is still running, it logs
    that, exits immediately without doing anything, and simply tries
    again at its next scheduled run;
  - if a backup fires while maintenance is still finishing up, it
    waits up to `RESTIC_BACKUP_LOCK_TIMEOUT` seconds (default 300) for
    the lock, then fails loudly (non-zero exit, logged) if maintenance
    still hasn't released it.
- **Every share is *started* at once, but only `RESTIC_BACKUP_MAX_PARALLEL`
  of them actually run `restic backup` at the same time** (default 4, sized for
  manny-01's planned 64G) -
  this is a separate, memory-driven limit from the shared/exclusive
  lock above, not a restic or systemd restriction. Each concurrent
  `restic backup` process can use several GB to tens of GB of RAM
  depending on `RESTIC_READ_CONCURRENCY`, pack buffers, and the
  share's own size; dispatching every share at once (correctly, by
  design) previously meant every one of them trying to actually run
  at the same moment too, which added up to more memory than the host
  had and caused an OOM (and a reboot) on manny-01. `acquire_backup_slot()`
  in `bin/restic-common.sh` bounds this: any instance beyond the limit
  waits (polling every 30s, logged once) until one of the running
  backups finishes and frees a slot. Size `RESTIC_BACKUP_MAX_PARALLEL`
  to the host's actual available RAM divided by the peak memory you've
  observed for one `restic backup` (`systemctl status
  restic-backup@<share>.service` while it's running shows `Memory:`) -
  not to the number of shares, which has nothing to do with how much
  RAM the host has.
  **This bounds a *count*, not a memory budget - it does nothing if a
  single share's backup is, by itself, big enough to exhaust the
  host** (manny-01's original incident happened at only 8G of RAM, where
  one large share's backup alone was enough). For that, `restic-backup@.service`
  sets per-instance `MemoryHigh=12G`/`MemoryMax=16G`, and `restic-backup.slice`
  (which every instance explicitly joins) sets `MemoryHigh=40G`/`MemoryMax=48G`
  as a cap on their *combined* memory - past `MemoryHigh` the kernel throttles/
  reclaims; past `MemoryMax` the kernel's cgroup-aware OOM killer kills
  only the processes in that cgroup, so one backup (or several
  together) failing can't take the whole host down with it. These
  values are sized together with `RESTIC_BACKUP_MAX_PARALLEL=4` for a
  64G host - **do not raise `RESTIC_BACKUP_MAX_PARALLEL` past what
  the current unit files' memory limits budget for**, and if the host
  is still at less RAM than these values assume, lower
  `RESTIC_BACKUP_MAX_PARALLEL` back to 1 and shrink both unit files'
  limits to match before enabling backups. Update both unit files'
  values together whenever the host's RAM changes.
- All scripts source `/etc/restic/restic.env` (and
  `/etc/restic/secrets.env`, chmod 600, holding the repo password and
  AWS credentials together) for configuration, and log every run to
  `/var/log/restic/{backup,maintenance}.log` as well as the systemd
  journal (`journalctl -u restic-backup.service -u
  'restic-backup@*.service'`).
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
- **restic-report.timer** fires **restic-report.service** daily at
  06:00, which runs `/opt/restic/bin/restic-report.sh`: emails an HTML
  table of the latest snapshot per configured share. Unlike verify,
  this only reads fast repository metadata, so it's safe to schedule -
  see "Daily backup report" below.
- `restic-snapshots.sh` is a standalone script (and sourceable shell
  function) to list snapshots on demand.

## Requirements

- `restic` (recent enough to support `--pack-size`, `--read-concurrency`
  and `-o s3.connections` / `-o s3.storage-class`)
- `bash`, `systemd`, `logrotate`, `mountpoint`, `findmnt`, `flock`, `timeout`
  (util-linux/coreutils, almost always already present)
- `jq` and `shuf` (coreutils) - used by `restic-snapshots.sh --latest-id`,
  required by `restic-verify.sh`, `restic-report.sh` and
  `restic-webreport.sh` (per-snapshot backup duration), and by
  `resticctl status` to read a running backup's progress
- `nfs-utils` (for `mount.nfs4`) and/or `cifs-utils` (for `mount.cifs`),
  whichever share types you actually use - required by
  `resticctl add-share`, which doesn't install them for you
- `mail`/`sendmail` and/or `curl`, only if you enable email or webhook
  failure notifications (`RESTIC_NOTIFY_EMAIL` / `RESTIC_NOTIFY_WEBHOOK_URL`)
- `curl` and `sha256sum` (on whatever machine fetches Backrest) and
  `tar`, `sha256sum` and `setfacl`/`getfacl` (the `acl` package, on
  manny-01 itself), only if you install the optional Backrest web UI -
  see
  [Browsing snapshots in a web UI](#browsing-snapshots-in-a-web-ui-backrest-optional)
- `python3` (stdlib only, no extra packages), only if you enable
  `restic-webserver.service` - see
  [A live, grouped-by-share web report](#a-live-grouped-by-share-web-report)

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
   dedicated IAM user scoped to just this bucket/prefix) - or, more
   securely, `RESTIC_PASSWORD_FILE`/`RESTIC_PASSWORD_COMMAND` and
   `AWS_PROFILE` instead; see the comments in
   `config/secrets.env.example`.
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
6. Enable and start the daily timers - just these two, regardless of
   how many shares you have (see "How it fits together" above for why
   `restic-backup.timer`/`.service` is a dispatcher, not the thing
   that actually backs up any share):
   ```sh
   systemctl enable --now restic-backup.timer
   systemctl enable --now restic-maintenance.timer
   ```
   A share added to or removed from `shares.conf` takes effect
   automatically at the dispatcher's next run - nothing to separately
   enable or disable per share.

## Where the secrets actually live

Quick reference for exactly what holds a real secret, where, and who
can read it - worth keeping accurate, since this host has in practice
run two different credential mechanisms at once and it's easy to lose
track of which one is actually live (see the git history around
`bin/restic-common.sh`'s `RESTIC_PASSWORD_FILE`/`AWS_PROFILE` support
for how that went wrong once already).

| What | Where | Mode/owner | Read by |
|---|---|---|---|
| Repo password (inline) | `RESTIC_PASSWORD` in `/etc/restic/secrets.env` | `600 root:root` | `restic`, via every `restic-backup@*`/`restic-maintenance`/etc. systemd unit (`EnvironmentFile=`), as root |
| Repo password (file, preferred) | content of the path named by `RESTIC_PASSWORD_FILE` in `restic.env`/`secrets.env` (e.g. `/etc/restic/password`) | `600 root:root` | `restic` itself opens this path directly - never passes through our scripts' own variables |
| AWS keys (inline) | `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` in `/etc/restic/secrets.env` | `600 root:root` | same as above |
| AWS keys (profile, preferred) | the profile named by `AWS_PROFILE` in `restic.env`/`secrets.env`, inside the file named by `AWS_SHARED_CREDENTIALS_FILE` (defaults to `~/.aws/credentials` of whichever user runs the service - root here, since the systemd units don't set `User=`) | `600`, owner of that home dir | the AWS SDK inside `restic`'s S3 backend, resolved independently of our scripts |
| Backrest's access to `secrets.env`/`RESTIC_PASSWORD_FILE` | no separate copy - `systemd/backrest.service` reads `/etc/restic/restic.env` and `/etc/restic/secrets.env` directly | unchanged (`secrets.env` stays `600 root:root`); the `backrest` service user gets a POSIX ACL grant (`getfacl /etc/restic/secrets.env` / `getfacl /etc/restic/password` to inspect) | `backrest`'s own restic subprocess, exactly like the real backups |
| Backrest's access to `AWS_PROFILE`'s credentials | **a separate copy**, `/etc/restic/backrest-aws-credentials` (owned `backrest:backrest`, no ACL) | `600 backrest:backrest` | `backrest`'s restic subprocess, via `AWS_SHARED_CREDENTIALS_FILE=/etc/restic/backrest-aws-credentials` (overridden in `systemd/backrest.service`) |
| Backrest's own login (unrelated secret) | bcrypt hash inside Backrest's `config.json` (`BACKREST_CONFIG=/etc/backrest/config.json`), set via its web UI on first visit | managed by Backrest itself | Backrest only - this is the password *to the dashboard*, not to the repository |

**Only one of each pair (inline vs. file/profile) should actually be
set at a time** - if both are present, whichever restic/the AWS SDK
resolves first silently wins, which is exactly the confusing state
this host was in before. Prefer the file/profile form: the secret then
never sits in a process's environment (visible via `/proc/<pid>/environ`,
`systemctl show`, core dumps, etc.), only in a file `restic` opens
directly when it needs it.

**`AWS_PROFILE` alone is not enough under systemd**: the default
`~/.aws/credentials` lookup only resolves correctly when `$HOME` is
set, which is true in an interactive root shell but is **not**
guaranteed inside a systemd service that doesn't set `User=` (every
`restic-backup@*`/`restic-maintenance`/etc. unit here, which all run
as root without `User=`). Confirmed on manny-01: `resticctl backup
<share>` run by hand worked, but the exact same configuration run via
`restic-backup@<share>.service` failed with `s3.getCredentials: no
credentials found` - `$HOME` was simply empty in the service's
environment, so the AWS SDK had no path to resolve. Fix: always set
`AWS_SHARED_CREDENTIALS_FILE` explicitly (e.g.
`/root/.aws/credentials`) alongside `AWS_PROFILE` - see
`config/secrets.env.example` - rather than relying on the `~/...`
default to resolve the same way in both contexts.

**Housekeeping**: any `/etc/restic/secrets.env.bak-*` files created
while migrating between mechanisms still hold the old secrets in
plaintext. Once you've confirmed `resticctl list` works on whichever
mechanism you kept, delete them (`rm /etc/restic/secrets.env.bak-*`) -
they're not read by anything, just a second copy of the password/keys
sitting on disk.

**Why `AWS_PROFILE`'s credentials get copied instead of read in
place, unlike everything else above**: `backrest.service` sets
`ProtectHome=true`, which hides `/root` (and `/home`, `/run/user`)
*entirely* from the service's private mount namespace - confirmed by
reproducing the exact same hardening with `systemd-run` and watching
`restic` fail with `s3.getCredentials: no credentials found` after a
~30s AWS SDK timeout, even with a POSIX ACL correctly granted on
`/root/.aws/credentials`. A mount-namespace hide happens before any
permission check, so no ACL can fix it - the only way to give Backrest
access is a copy living somewhere `ProtectHome` doesn't touch.
**If you rotate these AWS credentials, refresh the copy** (no need to
re-run the whole installer, and no service restart needed either -
`restic` reads the file fresh on each invocation):
```sh
install -m 0600 -o backrest -g backrest /root/.aws/credentials /etc/restic/backrest-aws-credentials
```
(adjust the source path if `AWS_SHARED_CREDENTIALS_FILE` names a
different one). `bin/install-backrest.sh` also refreshes this copy
every time it's re-run, if you'd rather just do that.

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
| `RESTIC_LOCK_FILE` | lock file backups hold in shared mode (parallel with each other) and maintenance holds in exclusive mode (never alongside a backup) |
| `RESTIC_BACKUP_LOCK_TIMEOUT` | seconds backup waits for the lock before failing |
| `RESTIC_BACKUP_MAX_PARALLEL` | how many shares actually run `restic backup` at once (default 4, sized for a 64G host) - see below |
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
update `ReadWritePaths=` in `systemd/restic-backup@.service` and
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

A share's path doesn't need to be its own dedicated mount point -
it's fine for several shares to be subdirectories of one larger mount
(e.g. several `shares.conf` entries under `/mnt/SVMCIGOUVZ1001/...`,
all backed by a single CIFS mount of the admin share `//host/c$`).
Before each backup, `check_shares_mounted()` in `bin/restic-common.sh`
verifies every configured path is itself an active mount or sits
*underneath* one (`findmnt -T`, not `mountpoint -q`), so this still
aborts loudly if the underlying CIFS/NFS mount actually drops instead
of silently backing up whatever's left on the local root filesystem.

**Why one snapshot per share is required:** restic's `forget`/`prune`
act on whole snapshots, not on sub-paths within one. To let two shares
keep different histories, each must own its own snapshots that
`restic forget --path <share>` can select independently - so
`restic-backup.sh` runs `restic backup <path>` once per share (see
`bin/restic-common.sh` for the full explanation), rather than passing
every share to a single combined `restic backup` call.

### Adding a new share

Adding a share normally means two separate things: mounting it
(`/etc/fstab` + `mount`) and telling restic about it (`shares.conf`).
`resticctl add-share` does both in one step, end to end, and rolls
back cleanly if the mount doesn't actually come up:

```sh
# NFS
resticctl add-share --type nfs \
    --source 10.110.136.44:/presentation_copy \
    --mount /mnt/svm-cs3-bnl-dev/presentation_copy \
    --policy short

# CIFS/SMB
resticctl add-share --type cifs \
    --source //10.110.136.43/c\$/myvolume \
    --mount /mnt/SVMCIGOUVZ1001/myvolume \
    --policy short \
    --credentials /etc/smb-cred-fileshare
```

It validates everything *before* touching anything (the `--policy`
name must already exist in `retention-policies.conf`, the mount point
must not already be in `/etc/fstab` or `shares.conf`), shows you the
exact two lines it's about to add and asks for confirmation (`--yes`
to skip that, for scripted use), then: backs up `/etc/fstab`, appends
the new line, `mount`s it, and checks with `mountpoint -q` that it
actually came up. If it didn't, `/etc/fstab` is restored from that
backup and nothing is added to `shares.conf` - you're never left with
a share half-configured (mounted but not backed up, or the reverse).
Once it succeeds, nothing else is needed: the next
`restic-backup.timer` run picks up the new line in `shares.conf`
automatically (or run `resticctl backup --background <share-name>` to
back it up immediately instead of waiting).

Default mount options (both match what's already proven on manny-01):
```
# NFS  (fstype nfs4)
rw,_netdev,vers=4.2,hard,proto=tcp,timeo=600,retrans=2,sec=sys,rsize=262144,wsize=262144,nconnect=<RESTIC_READ_CONCURRENCY>

# CIFS (fstype cifs)
credentials=<file>,vers=3.1.1,seal,noserverino,_netdev
```
`--nconnect N` overrides the NFS connection count (default: whatever
`RESTIC_READ_CONCURRENCY` is currently set to in `restic.env` - see
below and "Configuration reference" below; the shipped example
defaults that to 4, manny-01 currently runs it at 16); `--options
"..."` overrides the whole options string for either type, for
anything unusual. `--credentials <file>` is required for `--type cifs`
(there's no sensible default - it's a secrets file path) unless you
pass `--options` yourself.

**On `nconnect`:** more parallel TCP connections to the NFS server can
meaningfully help throughput for large sequential transfers like a
backup, but it's not "higher is always better" - each connection adds
overhead, and you're bounded by both link speed and the server's own
per-connection threading. The default here is deliberately tied to
`RESTIC_READ_CONCURRENCY` rather than a generic rule of thumb: restic
reads that many files concurrently during backup, and each concurrent
read becomes an NFS RPC call that the client spreads across
`nconnect`'s TCP connections - fewer connections than concurrent reads
means some of those reads queue up behind each other on the same
connection instead of actually running in parallel, leaving some of
that read concurrency unable to help. If you change
`RESTIC_READ_CONCURRENCY`, new shares pick up the new value
automatically (existing shares need their fstab line and
`mount -o remount` updated by hand). Keep it consistent across shares
on the same network path rather than mixing values without a measured
reason to.

### Moving to new hardware

`update-manny.sh`/`install.sh` only deploy the *code* - they deliberately
never touch an `/etc/restic/*` file that already exists, never touch
`/etc/fstab`, firewall rules, or Backrest's own state. All of that lives
outside git, so moving the service to new hardware (even keeping the
same IP) needs one extra step first, run **from the old host, as root**:

```sh
resticctl migrate-host --target root@<new-host>

# More realistically, on a host where root has no SSH identity of its
# own (by policy) and root login is disabled on the target too:
# --identity picks the key the SSH *connection* presents (this script
# itself still has to run as root locally, to read the 600-permission
# secrets files - that's independent of which key the network
# connection authenticates with), and --remote-sudo runs the remote
# side as `sudo rsync` so files still land with the right ownership
# (needs a NOPASSWD sudo rule for rsync on the target, since rsync's
# transport has no terminal for sudo to prompt on - see
# restic-migrate-host.sh's header comment):
resticctl migrate-host --target WBX669@<new-host> \
    --identity /path/to/a/key/WBX669/already/authorized/on/the/target \
    --remote-sudo
```

This copies, over rsync+ssh: `restic.env`/`secrets.env`/`shares.conf`/
`retention-policies.conf`/`excludes.txt` (whatever paths they're
actually configured to in `restic.env`, not assumed defaults),
`AWS_SHARED_CREDENTIALS_FILE` if set, and any CIFS `credentials=` files
referenced from `/etc/fstab` - then prints the matching CIFS/NFS
`/etc/fstab` lines for you to review and add on the new host by hand
(never auto-appended - blindly concatenating fstab files risks
duplicating or conflicting with entries the new host already has for
its own local disks). `--dry-run` previews without copying anything.

Still to do on the new host afterwards (`restic-migrate-host.sh`'s own
output repeats this list): run `update-manny.sh` to deploy the code
(it won't overwrite what was just copied), add the reviewed fstab
lines and `mount -a`, re-open the firewall ports this host had open,
re-run `bin/install-backrest.sh` if Backrest was migrated, and enable
the timers. Nothing about the restic repository itself needs
migrating - it's remote S3/Glacier, not local state.

### Maintenance and `--max-repack-size 0`

`bin/restic-maintenance.sh`, once per share:

```
restic forget --tag scheduled --path <share> --group-by host,paths \
    --keep-within Nd --keep-weekly N --keep-monthly N --keep-yearly N
```

using that share's own numbers from `retention-policies.conf` (the
`daily` column becomes the `N` in `--keep-within Nd`), then once for
the whole repository:

`--tag scheduled` (or `RESTIC_BACKUP_TAG` if you changed it) matters:
without it, forget would also consider ad-hoc `restic-backup.sh
--manual` snapshots, and since restic's `--keep-daily`/`--keep-within`
only ever keep the *latest* snapshot per matching period, a manual
backup taken the same day as the scheduled one would win that slot -
forgetting the actual scheduled backup early. Scoping to `--tag
scheduled` means manual snapshots are never touched by this automated
policy at all; clean them up by hand with `resticctl forget` when
you're done with them. The daily tier uses `--keep-within Nd` rather
than `--keep-daily N` for the same reason in miniature: "keep every
scheduled snapshot from the last N days" is a plain rolling window,
where `--keep-daily` still buckets by calendar day and would collapse
two scheduled runs landing on the same day (a timer catch-up after
downtime, a DST-boundary day) down to one.

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

### Browsing snapshots in a web UI (Backrest, optional)

Once there are enough shares and enough history, `resticctl list`'s
table gets long. [`bin/install-backrest.sh`](bin/install-backrest.sh)
installs [Backrest](https://github.com/garethgeorge/backrest) as an
optional, separate add-on - a small web UI, not wired into
`install.sh` or any of the backup automation.

**Limitation found the hard way**: Backrest can only group/display
snapshots under one of its own "Plans", and only ever associates a
Plan with backups it triggered itself - confirmed empirically that a
schedule-disabled Plan with a path matching an existing share still
showed "No backups yet" for that share's pre-existing history. Since
this automation's own snapshots were never created *through* Backrest,
they all show up flatly under "_unassociated_" with no per-share
grouping, however many Plans you define - Backrest isn't a good fit
for "see my shares at a glance" unless you let it run the actual
backups itself (which this project deliberately doesn't, to avoid
duplicating/conflicting with the dispatcher and timers). See
[A live, grouped-by-share web report](#a-live-grouped-by-share-web-report)
below for the thing that actually solves that.

**manny-01 has no internet access**, so `bin/install-backrest.sh`
never downloads anything itself - it installs from a tarball vendored
into `vendor/` ahead of time. Fetch and deploy it in two steps:

```sh
# 1. On the laptop that runs ./update-manny.sh (has internet):
bin/fetch-backrest.sh
./update-manny.sh

# 2. On manny-01 (offline), from the synced checkout:
sudo bin/install-backrest.sh
```

`fetch-backrest.sh` downloads the pinned release into `vendor/` and
verifies it against the checksum in `bin/backrest-version.sh`;
`install-backrest.sh` re-verifies that same checksum before installing
from it, so a stale or tampered vendor file is never installed
silently. Both are pinned to one specific release (captured by hand,
not fetched as "latest") rather than always tracking upstream, since
this runs a third-party binary on a government backup server - see
`vendor/README.md` for the full fetch/deploy flow and how to upgrade.

`install-backrest.sh` installs the binary, a dedicated unprivileged
`backrest` system user, and `systemd/backrest.service` - but does
**not** start it. No secrets to fill in anywhere: this host actually
has two overlapping credential mechanisms at once
(`RESTIC_PASSWORD_FILE`/`AWS_PROFILE` in `restic.env`, *and* literal
`RESTIC_PASSWORD`/`AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` in
`secrets.env`), and which one restic/the AWS SDK actually prefers
isn't something to guess at or duplicate. So `backrest.service` reads
`/etc/restic/restic.env` and `/etc/restic/secrets.env` directly, in
the same order `restic-backup.sh` itself sources them - Backrest ends
up authenticating exactly the same way the real backups already do,
whichever mechanism that turns out to be. The installer grants
`backrest` read access to `secrets.env` with a POSIX ACL
(`setfacl -m u:backrest:r /etc/restic/secrets.env`, requires the `acl`
package) rather than changing that file's ownership or mode - still
`600 root:root`, just additionally readable by this one service
account. Verify with `getfacl /etc/restic/secrets.env`.

Then:

```sh
systemctl enable --now backrest.service
```

manny-01's backup network is already protected, so this listens on
every interface (`BACKREST_PORT=:9898` in the unit) rather than only
`127.0.0.1` - open `http://<this host>:9898` directly, no SSH tunnel
needed. Backrest enforces its own local authentication on every
request: the first visit prompts you to create an admin
username/password (bcrypt-hashed, changeable later in its Settings
page) before anything else is reachable - do this immediately after
first starting the service. It has **no built-in TLS**, so that login
and everything else travels as plain HTTP; if the network ever needs
encryption in transit too, put a TLS-terminating reverse proxy in
front rather than changing the unit file. To restrict it to a specific
interface instead of all of them, set `BACKREST_PORT` to that
interface's `IP:9898` and/or add a host firewall rule scoped to the
backup network.

**Use it read-only, exactly like the rest of this section:**
- **Only "Add Repo" to import the existing repository, and leave its
  password field empty.** The service environment already carries
  whichever of `RESTIC_PASSWORD_FILE` or `RESTIC_PASSWORD` this host's
  config actually resolves to, so Backrest picks it up the same way
  restic itself does - confirmed from the release binary itself, which
  clears any password typed into a Repo's config once it detects
  `RESTIC_PASSWORD_FILE` in that repo's environment.
  **Never add a "Plan"** - a Plan is what makes Backrest schedule its
  own backups/retention, which would duplicate (and could fight with)
  the dispatcher and timers already running here. Importing a Repo
  alone just lets you browse what `resticctl list`/`restic snapshots`
  already read safely.
- **Stick to the snapshot list view; avoid "browse files" and
  "restore" inside Backrest.** Those read actual file contents
  (data blobs), and this repository's S3 **Glacier** storage class
  means that's only meant to happen through the deliberately manual
  `resticctl verify --target` workflow (see
  [Restore verification](#restore-verification)) - a generic restore
  UI doesn't know about that and may just hang or fail trying to read
  data that needs a Glacier restore first.

To upgrade Backrest later: after checking the release notes, update
`BACKREST_VERSION`/`BACKREST_SHA256` in `bin/backrest-version.sh`
together (never just bump one, and never point at a moving "latest"
tag), then repeat the fetch/deploy flow above - `fetch-backrest.sh`
will pull the new version into `vendor/` and `install-backrest.sh`
will verify and install it.

### A live, grouped-by-share web report

A small alternative/complement to Backrest: `bin/restic-webreport.sh`
regenerates one static HTML page - every configured share in its own
section, full snapshot history (date, ID, tags, size), newest first -
and `restic-webserver.service` serves it continuously as a live page
(reload to see the latest), not a file you download. Unlike Backrest,
this reuses the exact same `restic snapshots --path <share>` grouping
`resticctl list` already does correctly, so it actually groups by share
for the *existing* history, with nothing to configure per share and no
Plan/Repo concept to fight.

```sh
systemctl enable --now restic-webreport.timer     # regenerates the page hourly
systemctl enable --now restic-webserver.service   # serves it continuously
resticctl webreport                               # regenerate immediately instead of waiting for the timer
```

Open `http://<this host>:9900` (change the port in both
`systemd/restic-webserver.service` and your firewall if 9900 is
already taken). `restic-webserver.service` runs as its own dedicated,
unprivileged `resticweb` user with **no access at all** to
`/etc/restic`, `restic.env`, or `secrets.env` - it only ever reads the
one HTML file `restic-webreport.service` (which does need the usual
repository access, same as `resticctl list`) already wrote to
`/var/lib/restic-webreport`. Both only ever read fast repository
metadata (`restic snapshots`), never archived Glacier pack data, so
there's no real cost to regenerating or reloading often.

The page has a search box and a few sort options, all client-side
(plain JavaScript embedded in the page itself, no external library or
CDN - consistent with this host having no internet access):

- Typing in the search box filters by share name, date, snapshot ID or
  tag, live as you type - matching a share's name keeps every row in
  that section, matching only a tag/date/ID hides the other rows.
- Each snapshot row also shows how long that backup actually took
  (`Duration`), computed from restic's own `backup_start`/`backup_end`
  - shown as "—" for older snapshots that predate restic storing that
    data (same gap as the Size column, which comes from the same
    "snapshot summary").
- Clicking a column header (Date/ID/Tags/Size/Duration) sorts that
  share's table by that column; click again to reverse. Size and
  Duration sort by actual value (bytes / seconds), not as plain text -
  so `677.77 GiB` correctly sorts before `1.98 TiB`, and `4m05s`
  before `1h30m`.
- The "Trier les shares par" dropdown reorders the share sections
  themselves, by name, snapshot count, or most recent backup date.

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

   Sent from `RESTIC_NOTIFY_FROM` (default `Restic Backup
   <restic@<hostname>>`) - set this if you want a different display
   name/address; without it, some local MTAs fall back to the OS
   account running the job (e.g. "Super User <root@...>").

## Daily backup report

Separate from failure alerting above: `restic-report.sh` /
`resticctl report` emails one HTML table with the latest snapshot of
every configured share - a daily "did everything actually back up"
overview, sent regardless of `RESTIC_NOTIFY_ON`.

This is a backup report, not a server-health digest: it doesn't cover
backup/maintenance/verify job status - that's what the `RESTIC_NOTIFY_*`
failure alerts above and the `RESTIC_STATUS_DIR` status files are for.

```sh
resticctl report
```

Renders as an actual `<table>` (ID/Time/Tags/Paths/Size columns - Host
is left out, since one report only ever covers one host):

| ID | Time | Tags | Paths | Size |
|---|---|---|---|---|
| `a1b2c3d4` | 2026-09-24 01:00:05 | `scheduled,share:finance,policy:short` | `/mnt/share-finance` | 12.345 GiB |
| `e5f6a7b8` | 2026-09-24 01:00:41 | `scheduled,share:hr,policy:long` | `/mnt/share-hr` | 4.567 GiB |

Sent as HTML rather than a space-padded plain-text table: most mail
clients don't render plain text in a monospace font, so column
alignment done with spaces looks fine in a terminal (or in
`REPORT_LOG_FILE`, where the plain-text version is still logged for
`tail`/`less`) but skewed in an inbox - a real `<table>` aligns
correctly regardless of font.

Sent to `RESTIC_REPORT_EMAIL`, falling back to `RESTIC_NOTIFY_EMAIL`
if unset; if neither is set, the report is still generated and logged
to `REPORT_LOG_FILE`, just not emailed. It reuses the same `send_email`
delivery path as failure alerting (same MTA requirement, same
`RESTIC_NOTIFY_FROM`). The table looks up each share's latest snapshot
ID individually (`restic snapshots --path <share> --json --latest 1`,
needs `jq`), then renders them all in a single
`restic snapshots <id1> <id2> ...` call so restic computes/formats the
size correctly, and reformats that as HTML.

Unlike `restic-verify.sh`, this never touches archived pack data or
takes the backup/maintenance lock - only local status files and fast
metadata - so `restic-report.timer` (daily at 06:00, comfortably after
the 23:00/01:00 maintenance/backup runs) is safe to enable:

```sh
systemctl enable --now restic-report.timer
```

## Logging

Every run of every job is logged with timestamps to:

- `/var/log/restic/backup.log`
- `/var/log/restic/maintenance.log`
- `/var/log/restic/verify.log`

and mirrored to the systemd journal (`journalctl -u restic-backup -u
'restic-backup@*' -u restic-maintenance -u restic-verify`). `logrotate/restic` (installed to
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

The quickest "what's happening right now" check:

```sh
resticctl status
```

```
=== Backups ===
  presentation_copy      running   76%  32.2T/42.2T  29583755/44811700 files  elapsed 6h47m  eta 59m  (1192 errors)
  edrop_arc_tmp          idle      last: ok                   8h ago
  finance                idle      last: ok                   8h ago
  hr                     idle      never run

=== Maintenance ===
  idle      last: success              9h ago
            restic maintenance on manny-01 completed successfully in 563s (4 share(s)).
```

The percent/bytes/files/eta for a running share comes straight from
restic's own `--json` progress stream (`message_type: "status"`),
read from that share's `restic-backup@<share>.service` journal - not
re-derived or estimated (`percent_done`/`bytes_done`/`seconds_remaining`
are clamped/dropped if restic's own near-completion estimate briefly
overshoots - it revises its total-size estimate as it goes). An idle
share's last result comes from its own completion line in
`/var/log/restic/backup.log`, not from systemd's in-memory unit
state - that state isn't kept forever (e.g. it's dropped on the next
`daemon-reload`, which every `install.sh` run triggers), so relying on
it would wrongly show "never run" for a share that actually finished
hours earlier. `error_count` (shown only when > 0) is
restic's own count of files it couldn't read during this run, same as
in the final summary.

For the raw systemd/journal view instead:

```sh
systemctl list-timers 'restic-*'                 # next scheduled runs
systemctl status restic-backup.service           # dispatcher's last run
systemctl status 'restic-backup@*.service'       # every share's last run
systemctl status restic-maintenance.service
journalctl -u restic-backup.service -u 'restic-backup@*.service' -n 100
tail -f /var/log/restic/backup.log
/opt/restic/bin/restic-snapshots.sh
```

To run a job on demand outside its schedule, **use `--no-block`** - it
is not optional here. These are `Type=oneshot` services, which systemd
only considers "started" once the command actually *exits*; plain
`systemctl start` waits (blocks your shell) for exactly that, i.e. for
the entire backup to finish, which defeats the point of starting it
in the background. `--no-block` returns the instant the job is
queued instead:

```sh
sudo systemctl start --no-block restic-backup@<share-name>.service   # one share, e.g. "finance"
sudo systemctl start --no-block restic-maintenance.service
```

(if you *do* want to watch it run synchronously in your terminal,
that's the one case to leave `--no-block` off - otherwise always
include it). The job - and the backup it runs - keeps going after your
shell/SSH session exits either way; `--no-block` only changes whether
`systemctl start` itself waits around for it. To do this for *every*
configured share at once (started in parallel, not waiting on each
other):

```sh
resticctl backup-all
```

which is just a loop of `systemctl start --no-block
restic-backup@<share>.service` over every entry in `shares.conf` -
check progress afterward with `resticctl status`, `systemctl status
'restic-backup@*.service'`, or `journalctl -u
'restic-backup@*.service' -f`.

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

**These run in the foreground, in this one process** - useful for
watching the run live, but it blocks your shell until it's done, and
Ctrl+C kills it for real (it's a direct child of this command, not a
systemd job - unlike `systemctl start`/`backup-all` above, where
Ctrl+C only stops you from *watching*, never the job itself). To
start just one share in the background instead, going through systemd
the same way `backup-all` does:

```sh
resticctl backup --background /mnt/share-finance
```

which is a shorthand for `systemctl start --no-block
restic-backup@finance.service` - always tags the run `scheduled`
(can't be combined with `--manual`, since that service's `ExecStart`
has no way to pass it through).

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
