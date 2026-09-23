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

## Restoring from Glacier

`restic restore`, `restic dump`, and `restic check --read-data` all
need to read pack data. If that data is in a Glacier storage class
that requires restoration, you must first trigger and wait for the S3
restore (e.g. `aws s3api restore-object`) for the relevant objects
before running those restic commands - restic itself does not
initiate or wait for Glacier restores. The daily jobs in this repo
(per-share `backup`, per-share `forget`, the single `prune
--max-repack-size 0`, and the metadata-only `check`) never need to do
this, which is why they can safely run automatically every day even
against a Glacier/tape-backed repository.

`restic-verify.sh` (`resticctl verify`) is the one job here that does
need to read real data - it samples a few files per share and reads
them back with `restic dump` to prove backups are actually restorable.
Whether that "just works" or needs an explicit restore-object step
first depends entirely on your specific destination:

- **True AWS Glacier / Glacier Deep Archive**: reads will fail (or
  hang) until you explicitly restore the object first. `restic-verify.sh`
  bounds each file's read with `RESTIC_VERIFY_TIMEOUT` so it fails
  cleanly and reports it rather than hanging forever, but it cannot
  usefully run unattended against this kind of destination without
  extra automation (e.g. a wrapper that issues `aws s3api
  restore-object` for the relevant keys and waits before running
  `restic-verify.sh`) - not something this toolkit does for you today.
- **AWS Glacier Instant Retrieval, or most on-prem S3-compatible
  gateways backed by tape**: typically serve reads directly, with
  some added latency, and no explicit restore step - `restic-verify.sh`
  works as-is here.

This is exactly why `restic-verify.timer` is installed but never
auto-enabled: run `resticctl verify` manually first and see which of
the above actually describes your setup before deciding whether (and
how often) to schedule it.
