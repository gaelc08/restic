# vendor/

Holds third-party binaries that `bin/install-backrest.sh` installs on
manny-01, which has no internet access of its own.

- `backrest_Linux_x86_64.tar.gz` - fetched by `bin/fetch-backrest.sh`,
  run on a machine WITH internet access (the laptop that also runs
  `./update-manny.sh`). It's gitignored - `./update-manny.sh` rsyncs
  the whole working tree regardless of what's tracked in git, so the
  file just needs to exist locally when you run it, not be committed.

To install or upgrade Backrest:

```sh
# On the laptop (has internet):
bin/fetch-backrest.sh
./update-manny.sh

# On manny-01 (offline), from the synced checkout:
sudo bin/install-backrest.sh
```

See `bin/backrest-version.sh` for the pinned version/checksum, and the
"Browsing snapshots in a web UI" section of the top-level README.md
for the full setup and the safety rules for using Backrest against
this repository.
