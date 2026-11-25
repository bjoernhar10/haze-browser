# Haze progress

One entry per step: what is new, and how to test it.

## Step 4 — Patch workflow and the first patch (2026-11-25)

**What's new**

- `scripts/patch.sh` with `apply`, `export` and `check`. A patch is a git commit
  on top of the `baseline` tag in `build/src` and a `git format-patch` mailbox
  in `patches/<area>/<slug>.patch`, listed in `patches/series`.
- `export` is a fixed point, which it has to be or every step would carry patch
  churn. Three things would otherwise change on each run: the commit hash in the
  `From` line (`--zero-commit`), the trailing git version signature
  (`--no-signature`) and the diffstat width, which follows the terminal
  (`--stat=72 --stat-graph-width=10`). `apply` uses `git am`, which restores the
  original author and date from the file, so those round-trip too.
- `export` validates the CLAUDE.md header and refuses without it: a `Why:` line,
  `Security-relevant: yes|no`, and an `Area:` from
  `core privacy security ui mac win linux`. `Area:` is what decides the target
  directory; `series` decides the order. It also deletes patch files that no
  commit produces any more, and stages everything in a temp directory first, so
  a rejected commit leaves `patches/` untouched.
- `check` adds a scratch worktree with `--no-checkout` and applies the series to
  its index with `git apply --cached`. It answers "does this still apply" without
  materialising 527,761 files: **5 seconds** instead of minutes, which is what
  makes it usable at the end of every step. It is stricter than `apply`, with no
  3-way fallback.
- `build/src/.git/info/exclude` now covers `/haze/` (a copy of `overlay/`, which
  is the source of truth) and the three host-tool link paths, so generated files
  can never leak into an exported patch.
- `prepare.sh` sets the `build/src` identity to `Haze <patches@haze.invalid>`.
  That identity ends up in every patch's `From:` line, so it has to be identical
  on every machine or `export` would diff elsewhere.
- **First patch:** `overlay/BUILD.gn` defines an empty `group("haze")`, and
  `patches/core/build-hazes-sources-into-the-browser.patch` adds one line,
  `"//haze"`, to the `deps` of `//chrome/browser:browser`. From now on Haze code
  is in the build graph.

**How to test**

```sh
scripts/patch.sh check     # ~5 s, exits 1 naming the first patch that fails
scripts/patch.sh apply     # baseline + series -> one commit per patch
scripts/patch.sh export    # and again: patches/ must not change

# the hook really is in the graph:
build/src/out/gn_build/gn path build/src/out/Dev //chrome/browser:browser //haze
```

**Verified**

| Check | Result |
|---|---|
| `export` run twice | byte-identical (sha256 of all patches + series) |
| `apply` then `export` | identical bytes despite a different commit sha |
| `check` on a corrupted patch | exit 1, names the patch |
| `apply` on a dirty tree | exit 1, refuses to discard changes |
| `export` without `Why:` / bad `Security-relevant:` / unknown `Area:` | exit 1 each, `patches/` untouched |
| `gn gen` with the hook | 37,077 targets, `//chrome/browser:browser --> //haze:haze` |

**Not verified yet**

The patch is verified by `gn gen`, not by a compile: an empty group has nothing
to compile. The first full `chrome` build is still pending (see step 3).

## Step 3 — GN configs and the build script (2026-11-25, incomplete)

**What's new**

- `flags/dev.gn` and `flags/release.gn`. `scripts/build.sh` writes `args.gn` as
  ungoogled's `flags.gn` followed by the config file, so ungoogled's args come
  from the submodule and cannot go stale on a rebase. Only the differences from
  them are in Haze's files.
- Every arg was checked against `gn args out/<dir> --list` for the pinned
  version, and both configs pass `gn gen --fail-on-unused-args`, which proves
  each one exists and is consumed. Args that only repeat a default are left out:
  `is_official_build` is already false for dev, `blink_symbol_level` and
  `v8_symbol_level` follow `symbol_level` on their own, and `dcheck_always_on`
  already resolves correctly per config. `enable_nacl` does not exist in M158.

| Arg | dev | release | Why it is listed |
|---|---|---|---|
| `is_component_build` | `true` | — | Defaults to `is_debug`, so turning is_debug off would turn it off too |
| `is_debug` | `false` | — | Default `true`; a debug build is far slower to build and run |
| `symbol_level` | `0` | `0` | Default `2`; the biggest single win on link time |
| `is_official_build` | — | `true` | Default `false` |
| `use_mold` | `false` | — | See below |

- **`use_mold` is the one real trap.** M158 links non-official Linux builds with
  mold by default, but mold comes from a DEPS entry the source tarball does not
  carry, so the dev build would fail at link. Turning it off restores lld from
  the bundled clang. Official builds exclude mold by themselves, so release does
  not need the line.
- Resolved values confirm release keeps `is_cfi = true` and
  `use_thin_lto = true`, so the config does not weaken upstream hardening.
- `scripts/build.sh dev|release [targets]` syncs `overlay/` to
  `build/src/haze/` with `rsync --delete`, ensures the toolchain, builds `gn`,
  writes `args.gn`, runs `gn gen` and then ninja, logging to
  `build/logs/build-<config>-<timestamp>.log`.
- Four pruned host tools had to be linked into the paths the build expects:
  `python3` (`.gn` sets `script_executable` to `third_party/cpython3`, so
  `gn gen` fails with exit 127 without it), `node`, `gperf` and `tsc` (pointed
  at the in-tree `devtools-frontend/node_modules/typescript`, so no global npm
  install is needed).
- `gn` is built by calling GN's own `tools/gn/build/gen.py` with
  `--no-static-libstdc++` rather than `tools/gn/bootstrap/bootstrap.py`, which
  does not forward that flag. GN links the tool with `-static-libstdc++` on
  Linux, which needs `libstdc++.a`, a separate package on Fedora and others.
  Static linking only matters for shipping the binary around.

**Host prerequisites found the hard way**

`ninja-build`, `gperf` and `clang-tools-extra` are needed on Fedora and are not
in the tarball. ungoogled prunes the prebuilt `gn`, `ninja`, `cpython3`, `node`,
`gperf`, `tsc` and `clang-format`.

**What is NOT done**

No `chrome` binary yet, so there is **no build time, no launch with a fresh
profile in `build/profiles/` and no page load**. The build stops in a Crubit
step that needs `clang-format` at `buildtools/linux64-format/clang-format`;
`enable_cpp_api_from_rust` is computed from `enable_rust && build_with_chromium`
and is not a settable gn arg, so Crubit cannot simply be turned off. Install
`clang-tools-extra`, then `scripts/build.sh dev chrome`.

**Platform coverage**

Linux x64 only. `build.sh` is bash, and its host-tool links are Linux paths;
macOS and Windows need their own handling.

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
