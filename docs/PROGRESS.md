# Haze progress

One entry per step: what is new, and how to test it.

## Step 2 — Chromium source and the baseline commit (2026-11-25)

**What's new**

- `scripts/fetch.sh` downloads the pinned Chromium tarball through ungoogled's
  `downloads.py retrieve`, which verifies md5, sha1, sha224, sha256, sha384 and
  sha512 and exits non-zero on a mismatch, then extracts it to `build/src`.
  `unpack` does not re-verify, despite what its `--help` claims, so `retrieve`
  is the integrity gate. After extraction the tree's own `chrome/VERSION` is
  checked against the pin.
- `scripts/prepare.sh` runs ungoogled's pipeline in order — `prune_binaries.py`,
  `patches.py apply`, `domain_substitution.py apply` — and then makes
  `build/src` a git repo whose first commit is `baseline 158.0.8127.88`, tagged
  `baseline`. Haze patches become commits on top of it.
- The domain substitution cache is kept at `build/domsubcache.tar.gz` so
  substitution can be reverted on a rebase.
- Both scripts are idempotent through stamps in `build/stamps/`. The stamps are
  load-bearing, because none of ungoogled's utils are idempotent on their own:
  `prune_binaries.py` exits 1 when a file it wants to delete is already gone,
  `patches.py` fails on an already-patched tree, and `domain_substitution.py`
  refuses to run once its cache exists. Stamps live outside `build/src` so they
  never end up in the baseline, and are dropped automatically if `build/src`
  disappears.
- Neither script will touch an existing baseline repo, so Haze patch commits
  survive a re-run. `fetch.sh` also refuses to re-extract over a `build/src`
  that is a git repo.
- `lib.sh` gained the stamp helpers, the version cross-check (ungoogled's utils
  read *their* `chromium_version.txt`, not Haze's, so a mismatch would silently
  build the wrong version), and timing and size helpers.

**Measured on Linux x64 (8 jobs, NVMe, ~5.6 MiB/s download)**

| | |
|---|---|
| `fetch.sh` | **4m 47s** (2m 47s download, rest extract) |
| `prepare.sh` | **8m 01s** (prune, patches, domain substitution, baseline commit) |
| Tarball cache | 946 MB |
| `build/src` working tree | 7.5 GB |
| `build/src/.git` | 3.2 GB |
| `build/src` total | 11 GB |
| `build/domsubcache.tar.gz` | 145 MB |
| **`build/` total** | **12 GB** |
| Files in the baseline commit | 527,761 |

A re-run of both scripts takes 1 second and changes nothing.

**How to test**

```sh
scripts/fetch.sh && scripts/prepare.sh     # first run: ~13 min, 12 GB
scripts/fetch.sh && scripts/prepare.sh     # again: no work, baseline untouched

git -C build/src log --oneline -1          # baseline 158.0.8127.88
git -C build/src tag                       # baseline
git -C build/src status --porcelain        # empty: tree is clean
```

**Platform coverage**

Linux x64 only. Both scripts are bash and should work on macOS as written;
Windows needs a PowerShell equivalent, which does not exist yet.

**Notes for later**

- Domain substitution rewrites the Chromium tool-download URLs, which breaks
  fetching the prebuilt clang and rust. ungoogled's platform repos sed the
  source back; Haze does not need to, because `tools/clang/scripts/update.py`
  reads `CDS_CLANG_BUCKET_OVERRIDE` from the environment and
  `tools/rust/update_rust.py` imports its downloader. `scripts/build.sh` sets
  that one variable, so the source tree stays untouched and the baseline stays
  clean. Upstream's sed list is also partly obsolete here:
  `build/linux/sysroot_scripts/sysroots.json` is not substituted in M158.
- ungoogled prunes the prebuilt `gn` and `ninja`, and Chromium's bundled `node`
  and `gperf` as well.

## Step 1 — Repo skeleton and pinned base (2026-11-25)

**What's new**

- Repo structure from `docs/SPEC.md` §8: `overlay/{components,browser,common,renderer}`,
  `patches/{core,privacy,security,ui,mac,win,linux}` plus an empty `patches/series`,
  `tokens/`, `flags/`, `scripts/`, `test/data/`, `docs/screens/`. Empty
  directories are held by `.gitkeep`.
- `.gitignore` covers `build/` (Chromium source tree, `out/`, logs, test
  profiles) and generated files, including the token header that
  `scripts/gen_tokens.py` will produce.
- `chromium_version.txt` pins Chromium **158.0.8127.88** — current stable
  (M158, Linux channel, released 2026-11-23).
- `ungoogled-chromium/` is a submodule pinned to tag **158.0.8127.88-1**
  (commit `9746a5f`), the exact match for that Chromium version. Its own
  `chromium_version.txt` reads `158.0.8127.88`, so base and pin agree.
- `scripts/lib.sh`: shared paths, logging, platform and job detection, and
  error handling for every later script. `set -Eeuo pipefail` with an `ERR`
  trap that reports the failing line and command; `-E` so the trap also fires
  inside functions and subshells. Written for bash 3.2, because that is what
  macOS ships.
- `docs/PATCHES.md` with an empty patch table and the meaning of each patch
  area.

No Chromium source has been downloaded yet, and no patch exists yet.

**How to test**

```sh
# Paths, pinned versions, platform and parallelism.
bash -c '. scripts/lib.sh
         haze_step "check"
         haze_info "chromium  $(haze_chromium_version)"
         haze_info "ungoogled $(haze_ungoogled_tag)"
         haze_info "platform  $(haze_platform), jobs $(haze_jobs)"'

# Base layer is pinned to a tag, not a floating branch.
git submodule status                    # expect: 9746a5f... (158.0.8127.88-1)
cat ungoogled-chromium/chromium_version.txt   # must equal chromium_version.txt

# Nothing generated or downloaded is tracked.
git status --porcelain                  # clean after the step-1 commit
```

**Platform coverage**

Only Linux was exercised. `scripts/lib.sh` is bash-only and still needs a run
on macOS (`sysctl -n hw.ncpu` path in `haze_jobs`) and on Windows under Git
Bash (`haze_platform` returning `win`); Windows builds will use
`scripts/build.ps1`, which does not exist yet.

**Decisions**

- License is BSD-3-Clause, matching Chromium and ungoogled-chromium (SPEC §1).
  The repo started out MIT; swapped before any outside contribution. Patches
  modify BSD-3-Clause Chromium files and cannot be relicensed, so one
  permissive license across the tree keeps per-file licensing honest and
  leaves upstreaming possible. New files carry the Chromium-style header.
- `adblock-rust`, planned for the content blocker, is MPL-2.0. It combines
  fine with BSD-3-Clause, but modifications to its files must be published.

**Open decision**

`.gitignore` ignores the generated token header at
`overlay/common/haze_tokens.h`. The path is a guess until
`scripts/gen_tokens.py` lands; if the generator writes somewhere else, update
the ignore entry with it.
