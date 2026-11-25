# Haze progress

One entry per step: what is new, and how to test it.

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
