# Haze progress

One entry per step: what is new, and how to test it.

## Step 6 — macOS (2026-11-27, incomplete: the Mac run is still to do)

This step was worked on from the Linux machine, which has no access to a Mac.
Everything that can be prepared and checked without one is done; building,
launching and the in-app checks are listed below for the Mac.

**What Chromium M158 needs on macOS**

- Xcode with the **macOS 27.0 SDK** (`mac_sdk_official_version` in
  `build/config/mac/mac_sdk.gni`, SDK build 26A425). That is what the bots use;
  a newer SDK usually works, an older one may not. Xcode 27 runs on Apple
  Silicon only. The Command Line Tools alone are not enough.
- Deployment target and minimum macOS for the built app: **13.0**.
- An APFS volume (the default). arm64 is the host architecture on Apple
  Silicon, so `target_cpu` stays at its default and is not set.
- Python **3.10 or newer**. Xcode's `/usr/bin/python3` is 3.9, and 39 build
  scripts use 3.10 syntax, V8's metagen among them (`-> str | None` without
  `from __future__ import annotations`), which fails at import.

**ungoogled-chromium-macos**

It has no tag for 158 yet; the newest is `157.0.8103.78-1.1`, and `master` is
on 157 too. Read as a reference, not pinned. Most of its 24 patches exist
because it builds clang, Rust, bindgen and Crubit itself and uses Homebrew's
esbuild and TypeScript. Haze takes the toolchains Chromium pins in `DEPS`
instead, as on Linux, so it does not need those. Two of them are relevant:

- `fix-disabling-safebrowsing`: GN fixes for `safe_browsing_mode=0` on macOS.
  Not applied ahead of time: written for 157, and it also deletes sandbox
  parameter code in `chrome_content_browser_client.cc` and a policy entry,
  which CLAUDE.md wants disabled rather than deleted, with a reason. If
  `gn gen` fails on the Mac in `chrome/browser/extensions`, `chrome/browser/ui`
  or `chrome/services/file_util`, that patch is where to look.
- `add-local-network-usage-description`: since macOS 15 the app and helper
  bundles need `NSLocalNetworkUsageDescription`, or requests to LAN addresses
  fail with `ERR_ADDRESS_UNREACHABLE`. Not part of this step; noted for a later
  macOS step.

They also moved to a bundle ID that matches the signing identifier, because
macOS keys privacy permissions such as Local Network to the bundle ID. For
Haze that means the signing identity at packaging time must be
`org.hazebrowser.Haze`.

**What changed**

- `scripts/lib.sh`: `haze_host_cpu` (Chromium's `x64`/`arm64`),
  `haze_require_python` (3.10+, fails early with a hint), `haze_sha256_ok`
  (Python's hashlib instead of GNU `sha256sum`, which macOS lacks; `shasum`
  would need Perl).
- `scripts/deps_tool.py` picks a gcs object by `host_cpu` as well as
  `host_os`. Before, an Apple Silicon Mac would have fetched the Intel libclang.
- `scripts/build.sh`:
  - Linux-only toolchain steps (sysroot, gperf link) run only on Linux; macOS
    checks for Xcode and warns on an SDK older than 27.
  - node comes from `node/mac_arm64` (`node-darwin-arm64`), clang-format from
    `buildtools/mac_arm64-format`; gn stays in `buildtools/mac`.
  - `args.gn` gets `flags/<config>.<platform>.gn` appended when it exists.
    `use_mold` moved to `flags/dev.linux.gn`: GN declares it only off Apple and
    Windows, so on a Mac it would be an unused arg and fail
    `--fail-on-unused-args`.
- macOS identity patch: the `haze://` launch scheme, in
  `shell_integration_mac.mm` and in `build/apple/tweak_info_plist.py`, which
  adds the scheme to Info.plist only for bundle IDs it knows. Step 5 had left
  macOS on `chromium://`.

**Checked from Linux**

| Check | Result |
|---|---|
| Paths in the baseline that clash on a case- and normalisation-insensitive FS | 0 of 527,761 (one non-ASCII path, an emoji, which has no decomposed form) |
| Same for the Haze repo | 0 |
| GNU-only tools and bash 4 features in `scripts/` | only `sha256sum`, replaced; ungoogled's unpacker already supports BSD tar |
| gcs downloads for mac-arm64 (libclang, clang-format, node) | present, sha256 matches DEPS, clang-format is Mach-O arm64, archives contain the files `build.sh` checks for |
| cipd packages for mac-arm64 (gn, esbuild, TypeScript, Go) | all present |
| Chromium's clang and Rust for `Mac_arm64` | both present |
| Linux build with the ported scripts | passes, `args.gn` gets `dev.linux.gn` |
| `patch.sh check` / `export` | clean / no change on a second run |

**To do on the Mac** (Apple Silicon)

```sh
# Prerequisites
xcode-select -p          # must be .../Xcode.app/..., not CommandLineTools
xcrun --sdk macosx --show-sdk-version   # 27.0 or newer
brew install ninja python                # python3 on PATH must be >= 3.10
df -h .                                  # ~40 GB free for build/

git clone --recurse-submodules https://github.com/bjoernhar10/haze-browser
cd haze-browser
scripts/fetch.sh && scripts/prepare.sh && scripts/patch.sh apply
HAZE_JOBS=<cores, fewer if RAM < 32 GB> scripts/build.sh dev chrome

# Launch once without --user-data-dir: the default location is the check.
open build/src/out/Dev/Haze.app
```

Then confirm, and record build times here:

- Dock and menu bar say **Haze**; Haze menu → About Haze shows Haze and the
  placeholder icon (the Dock icon may still be Chromium's: `Assets.car`, step 5).
- `defaults read "$PWD/build/src/out/Dev/Haze.app/Contents/Info" CFBundleIdentifier`
  → `org.hazebrowser.Haze`; `CFBundleURLTypes` lists `haze`.
- `~/Library/Application Support/Haze/` exists and no new
  `Application Support/Chromium/` appeared. Remove it afterwards: it is the
  real default location, used here only because that is what is being checked.
- `security find-generic-password -s "Haze Safe Storage"` finds the key once a
  password or cookie has been stored.

**Platform coverage**

The scripts are verified on Linux only. Nothing has run on macOS yet.

## Step 5 — Branding (2026-11-26)

**What's new**

Nine patches in `patches/core/`, one concern each:

| Patch | What it covers |
|---|---|
| grit strings | Every UI string that says "Chromium", in all locales |
| `BRANDING` | Product, company and copyright names; macOS bundle name and ID `org.hazebrowser.Haze` |
| Linux identity | `~/.config/haze`, `haze.desktop`, app ID and WM class `haze`, icon name, `haze` URL scheme, package metadata |
| System dirs | `/etc/haze/policies`, `/etc/haze/native-messaging-hosts` (macOS: `Application Support/Haze`) |
| OS keyring | "Haze Safe Storage" in Secret Service, KWallet and the macOS Keychain |
| macOS identity | `Application Support/Haze`, initial preferences, "Haze Apps" folder, Finder document type names |
| Windows identity | `%LOCALAPPDATA%\Haze`, AppUserModelID, ProgIDs, policy and TriggeredReset keys, new CLSIDs, Active Setup GUID and AppContainer SID prefix |
| `haze.exe` | Output name, version resource, installer and the code that finds the exe by name |
| Placeholder icon | Neutral square with an "H" in every size and format, drawn by `scripts/placeholder_icon.py` |

- **Strings without losing translations.** grit keys each translation by a
  fingerprint of the English text, so editing "Chromium" in the `.grd` files
  would orphan the translations of every string naming the product, German
  included. Instead, one hook in grit's `MessageNode.Translate()` renames the
  product *after* the translation is chosen. The rules live in
  `overlay/tools/grit/haze_branding.py`: whole word "Chromium" only, so
  "ChromiumOS" and URLs stay; the link text between `BEGIN_LINK_CHROMIUM` and
  `END_LINK_CHROMIUM` stays, so "Haze is made possible by the **Chromium**
  open source project" stays true in every language. German needs nothing
  more ("Die Haze-Autoren"). Languages that inflect names keep their case
  ending on the new stem ("Hazea"), which is understandable but not polished;
  Haze supports English and German.
- **Deliberately still Chromium:** the User-Agent (reduced UA, no Haze token),
  UA-CH brands (`Chromium 158`), and the "Chromium PDF Plugin/Viewer" names in
  `navigator.plugins`. Websites see all three, and a Haze-specific value would
  single Haze users out. UA-CH would only pick up the product name under a
  non-Chromium branding flag, which Haze does not set.
- `patch.sh export` now requires a `Security:` line whenever a patch says
  `Security-relevant: yes`, so the reason CLAUDE.md asks for is checked rather
  than hoped for. Three of these patches carry one.
- `test/data/smoke.html` also shows the UA-CH brands.

**Verified on Linux x64** (incremental build: 2,136 edges, 10 min)

| Check | Result |
|---|---|
| `chrome://version`, English | Haze, The Haze Authors, Copyright 2026 The Haze Authors |
| `chrome://version`, German | "Informationen zur Version", "Die Haze-Autoren" |
| About page, en / de | "About Haze" / "Über Haze", placeholder icon, credits link still "Chromium" |
| Window title (Wayland `set_title`) | `Haze smoke test: ok - Haze` |
| App ID (Wayland `set_app_id`) | `haze` |
| KDE (asked KWin over D-Bus) | `desktopFileName=haze`, `resourceClass=haze` → `haze.desktop`, Name "Haze" |
| Default profile dir (with `XDG_CONFIG_HOME` redirected) | `<XDG_CONFIG_HOME>/haze` |
| User-Agent / UA-CH | no Haze token / `Not.A/Brand 24, Chromium 158` |
| Visible "Chromium" left on version and About pages | only the credits link |
| Shutdown | clean, no crash dump |

Screenshots: `docs/screens/05/` (version and About page, English and German).

**How to test**

```sh
HAZE_JOBS=5 scripts/build.sh dev chrome
(cd build/src && python3 haze/tools/grit/haze_branding_unittest.py)

# Crashpad ignores --user-data-dir and writes to the *default* data dir, so
# redirect XDG_CONFIG_HOME too or a test run creates ~/.config/haze.
# On Linux the UI language comes from LANGUAGE, not --lang.
LANGUAGE=de XDG_CONFIG_HOME=$PWD/build/profiles/xdg \
  build/src/out/Dev/chrome --user-data-dir=build/profiles/brand chrome://settings/help
```

**Platform coverage**

Only Linux was built and run. macOS and Windows are patched but unbuilt:

- macOS: `Assets.car` is a compiled asset catalog that only Apple's `actool`
  produces, so it still holds Chromium's icon; `app.icns` and the
  `Assets.xcassets` PNGs are replaced. The Dock may show Chromium's icon until
  the catalog is rebuilt on a Mac.
- Windows: the `haze.exe` rename covers the build, installer and every code
  path that finds the exe by name, but has never been compiled. The COM
  interface IIDs are unchanged on purpose (they are defined in the IDL files);
  if a system-level install of both Haze and Chromium turns out to clash on the
  type library registration, the IDL needs Haze's own IIDs.

**Found along the way**

- Crashpad keeps its database in the default user data dir regardless of
  `--user-data-dir` (upstream, crbug.com/40447560). Earlier test runs had
  therefore created `~/.config/chromium/Crash Reports` (step 3) and
  `~/.config/haze/Crash Reports` (this step) in the real home. Both held only
  crashpad's local database and were removed. The one dump in it was a
  `DumpWithoutCrashing` from the step-3 cleanup killing the zygote and browser
  at once, not a crash.
- The version line reads "Developer Build, ungoogled-chromium". That is
  ungoogled's own patch and names what Haze is built on; left as is.
- Settings still has a "You and Google" section. Not branding; belongs with
  removing Google services.

**Open decisions**

- macOS bundle ID `org.hazebrowser.Haze` (also the Linux RDN) is a
  placeholder for a domain the project controls. Cheap to change before the
  first release, expensive after.
- The Linux package maintainer address is `patches@haze.invalid` until
  packaging.

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
  is the source of truth) and every path `build.sh` fetches pruned tools into,
  so generated files can never leak into an exported patch.
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
cd build/src && buildtools/linux64/gn path out/Dev //chrome/browser:browser //haze
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

| `chrome` built and launched with the patch applied (step 3) | links, starts, renders |
| `export` / `check` against the built tree (2026-11-26) | no diff / clean |

An empty group has nothing to compile, so the link only proves the hook does
not break the build; the first Haze sources will prove it carries code.

**Haze tests**

None yet: `haze_unittests` arrives with the first real Haze code.

**Platform coverage**

Linux x64 only. `patch.sh` is plain bash and git, so it should run unchanged on
macOS; Windows needs Git Bash or a PowerShell port.

## Step 3 — GN configs and the build script (2026-11-25 – 26)

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
  `build/src/haze/` with `rsync --delete`, ensures the toolchain and the pruned
  tools, writes `args.gn`, runs `gn gen` and then ninja, logging to
  `build/logs/build-<config>-<timestamp>.log`. `HAZE_JOBS` overrides the job
  count.

**Pruned tools are fetched from DEPS, not linked from the host**

ungoogled prunes prebuilt binaries, but the build still runs them from fixed
paths. Linking host copies looked simpler and failed twice: `tsc` needs its
whole package (it reads `lib.*.d.ts` beside itself), and
`third_party/node:check_version` asserts the exact pinned node version.
`scripts/deps_tool.py` reads the entry out of the tree's own `DEPS` (resolving
`Var()`), so a rebase picks up new versions with no change to Haze:

| Tool | Source | Found by |
|---|---|---|
| `gn` | cipd `gn/gn/linux-amd64`, into `buildtools/linux64/` | V8's metagen runs `gn desc` and looks only there |
| `clang-format` | gcs, sha256-checked | Crubit; `enable_cpp_api_from_rust` is not settable |
| `libclang` | gcs, sha256-checked, per host OS | V8 metagen |
| `node` | gcs, sha256-checked | devtools-frontend, version-asserted |
| `esbuild`, TypeScript | cipd | devtools-frontend |
| Go | cipd, from Dawn's `DEPS` | Dawn runs `go run` inside an action script |

Only `python3` and `gperf` are still linked from the host. gcs downloads are
checked against the sha256 in DEPS; cipd ones come from the
`chrome-infra-packages.appspot.com` HTTPS endpoint, which DEPS pins by version
but not by hash.

`ninja -t inputs` cannot prove this list complete: a tool spawned inside an
action script (Dawn's `go`) is not a declared input. The build finishing is the
proof.

**Measured on Linux x64** (i7-1185G7, 4 cores / 8 threads, 15 GiB RAM, NVMe)

| | |
|---|---|
| `chrome` edges | 56,852 |
| Ninja time, all runs | **14 h 21 min** (five runs: three stopped on a missing tool, one on low memory; ninja resumes) |
| Last run | 10 h 39 min for 31,156 edges at `-j 5` |
| `out/Dev` | 6.6 GB, 554 shared libraries |
| `chrome` binary | 190 MB |

A clean run would land near the sum: every stopped run kept its objects. One
run was killed when the machine ran low on memory at `-j 8`; Blink's bindings
generators push 8 parallel jobs past 15 GiB. `HAZE_JOBS=5` finished without
trouble.

**Launch check**

- Headless, fresh profile in `build/profiles/step3-smoke`, loading
  `test/data/smoke.html` over `file://`: the page script ran and set the title
  to `Haze smoke test: ok`. Screenshot: `docs/screens/03/smoke.png`.
- Windowed under Wayland, fresh profile in `build/profiles/step3-window`: browser,
  GPU, zygote, utility and four renderer processes started, the toplevel window
  was mapped, and it shut down cleanly. A KWin screenshot of it comes out black
  without a portal grant, so the rendered page above is the visual record.
- The smoke page is local on purpose. A fresh profile must make zero requests,
  so the test makes none either. Whether the browser itself stays quiet is
  `scripts/netcheck.sh`'s job from step 8.

**How to test**

```sh
HAZE_JOBS=5 scripts/build.sh dev chrome     # resumes where ninja stopped

build/src/out/Dev/chrome --headless=new --no-first-run \
  --user-data-dir=build/profiles/smoke \
  --dump-dom "file://$PWD/test/data/smoke.html" | grep '<title>'
# -> <title>Haze smoke test: ok</title>
```

**Platform coverage**

Linux x64 only. `build.sh` is bash; the toolchain steps and the cipd/gcs
selection already pick per host OS, but nothing has run on macOS, and Windows
needs `scripts/build.ps1`, which does not exist yet. `out/Release` has not been
built: an official ThinLTO/CFI build is far heavier than dev and is not
practical on this machine.

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
