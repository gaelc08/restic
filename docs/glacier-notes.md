# Notes on restic + S3 Glacier

restic talks to Amazon S3 (or an S3-compatible endpoint) through its
standard `s3:` backend. Glacier is a *storage class* on top of S3, not
a different protocol, so no special restic backend is needed - only
the right options.

## Storage class

`config/restic.env.example` sets:

```
RESTIC_S3_STORAGE_CLASS="GLACIER"
```

which is applied via `-o s3.storage-class=GLACIER` to every restic
invocation (backup, forget/prune, check, snapshots) in
`bin/restic-common.sh`'s `RESTIC_GLOBAL_ARGS`. This tells the S3
backend to write new objects with that storage class.

## Why prune uses `--max-repack-size 0`

`restic prune` normally does two things:

1. Deletes pack files that are no longer referenced by any snapshot
   (cheap - a plain delete).
2. **Repacks** pack files that are only partially referenced: it reads
   the still-needed blobs out of the old pack, writes a new, smaller
   pack, and deletes the old one. This step requires *reading* pack
   data back from the repository.

On a Glacier-class (or tape-backed) destination, reading archived pack
data back is slow, may require an explicit restore/retrieval step, and
can incur retrieval charges or tape mounts. `bin/restic-maintenance.sh`
always passes `--max-repack-size 0`, which disables repacking
entirely - prune then only removes fully-unreferenced packs, never
reads archived data. This is exactly what was asked for and is safe to
run daily.

The trade-off: disk space from partially-referenced packs is never
reclaimed by repacking. In practice this is fine for an
archive/Glacier-tier repository, since the goal is retention, not disk
efficiency.

## Metadata vs. data objects

A restic repository is not one big blob - it has several object
types: `config`, `keys/`, `snapshots/`, `index/`, and `data/` (the
actual pack files). Every restic operation (`backup`, `forget`,
`prune`, `check`, `snapshots`) needs immediate, synchronous read
access to `config`, `keys/`, `index/` and `snapshots/` - these must
stay readable without a Glacier restore/thaw delay.

Two ways to satisfy this while still archiving the bulk of the data
(the pack files) to Glacier:

1. **Set the storage class in restic** (what this automation does by
   default via `RESTIC_S3_STORAGE_CLASS`). This is simplest, but be
   aware some Glacier tiers make objects genuinely unreadable until
   restored - if your bucket/gateway enforces that even for the small
   metadata objects, `restic check`, `prune`, and any `restore` will
   fail until those specific objects are restored. Test this against
   your actual endpoint (AWS Glacier Instant Retrieval and most
   on-prem "Glacier-compatible" tape gateways keep small/recent
   objects promptly readable; AWS Glacier Deep Archive does not).

2. **Set `RESTIC_S3_STORAGE_CLASS=STANDARD`** and instead add an S3
   **lifecycle rule** on the bucket that transitions objects under the
   `data/` prefix only to Glacier after N days, leaving `config`,
   `keys/`, `index/`, `snapshots/` on Standard storage permanently.
   This keeps all restic operations that only need metadata (which is
   most of them, including `restic snapshots` and the retention/forget
   step) fast, while still archiving the bulk of the data. `restore`
   and `check --read-data` will still need a Glacier restore for
   objects under `data/`.

Option 2 is the more robust long-term setup if you ever need to run
`restic restore` or `restic check --read-data` regularly; this
automation ships with option 1 configured (per the stated requirement)
but the switch is a one-line change to `restic.env` plus a bucket
lifecycle rule.

**Confirmed for this repo's destination**: option 1 already works fine
in practice - daily `backup`, `forget`, `prune`, and metadata-only
`check` have all been running successfully without needing a restore,
so `config`/`keys/`/`index/`/`snapshots/` are evidently readable
without delay. It's specifically reading pack data under `data/`
(actual file content) that requires the explicit restore step covered
below.

## Restoring from Glacier

`restic restore`, `restic dump`, and `restic check --read-data` all
need to read pack data. **Confirmed against this repo's real
destination (`scrat-1.ctie.etat.lu`): reads need an explicit restore
step first**, same as true AWS Glacier. The daily jobs in this repo
(per-share `backup`, per-share `forget`, the single `prune
--max-repack-size 0`, and the metadata-only `check`) never need to
read pack data, which is why they can keep running automatically every
day regardless.

Restic itself *can* drive the Glacier restore workflow, via an
experimental feature flag - this is the mechanism `restic-verify.sh`
uses by default (`RESTIC_VERIFY_USE_S3_RESTORE=true`), and it's also
**the procedure to use for a real disaster-recovery restore** from
this repository, not just for verification:

```sh
# 1. trigger the S3 restore for whatever objects this snapshot/path
#    needs, and wait (up to -o s3.restore-timeout) for them to thaw
RESTIC_FEATURES=s3-restore restic -r "$RESTIC_REPOSITORY" restore <snapshot-id> \
    -o s3.enable-restore=1 -o s3.restore-days=1 -o s3.restore-timeout=24h \
    --target <restore-path>

# 2. plain restore, now that the objects are warm
restic -r "$RESTIC_REPOSITORY" restore <snapshot-id> --target <restore-path>
```

Notes:

- `RESTIC_FEATURES=s3-restore` only needs to be set for the first
  command - it's an experimental-feature opt-in for the `-o
  s3.enable-restore=...` options, which the second (plain) restore
  doesn't use.
- `-o s3.restore-days` controls how many days the thawed copy stays
  available before reverting to archive; `-o s3.restore-timeout` is
  how long restic itself will wait for objects to thaw (a Go duration
  like `24h`, `90m`) before giving up - tune both to your tape robot's
  actual behavior and how much time you can give a real restore.
- restic figures out which pack objects a given restore actually needs
  and restores those - you don't need to work out S3 keys by hand, and
  you can restrict scope with the usual `--include`/`--path` filters
  to restore (and therefore only need to thaw) a subset of a snapshot.
- Add `--target` under a scratch/DR location, not back onto the live
  share, until you've confirmed the restored content is what you
  expect.

For destinations that serve reads transparently instead (no restore
step needed - true of AWS Glacier Instant Retrieval and many on-prem
S3-compatible tape gateways), skip all of the above: a plain `restic
restore` or `restic dump` just works. Set
`RESTIC_VERIFY_USE_S3_RESTORE=false` in that case so `restic-verify.sh`
uses the cheaper direct-read path instead.

This is also why `restic-verify.timer` is installed but never
auto-enabled by `install.sh`: even with the restore mechanism working,
a real restore against a tape-backed destination can take anywhere
from minutes to many hours, so it needs a deliberate decision about
scheduling rather than a default-on timer.
