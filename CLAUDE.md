# Haze – Project context for Claude Code

Haze is a desktop browser built on Chromium for macOS, Windows and Linux, with a focus on privacy, security and performance. The UI is calm and sidebar-first on a translucent window, in the spirit of Zen Browser, with its own design. It has to feel native on every OS, especially on the Mac. Haze is a patch set on top of Chromium stable and ungoogled-chromium, not a hard fork. Cheap rebases are what keep it secure.

The full spec is in `docs/SPEC.md`. Read only the sections the current step names. The target look is `docs/reference/target.png`.

## How Haze is built
- `chromium_version.txt` pins the Chromium version. `ungoogled-chromium/` is a submodule pinned to the matching tag.
- Pipeline: download → prune → ungoogled patches → domain substitution → baseline commit in `build/src` → Haze patches, one commit each.
- New code lives in `overlay/`. The build scripts sync it to `build/src/haze/`. **`build/src/haze/` is a copy. Never edit it.**
- Changes to existing Chromium files are patches in `patches/`, ordered by `patches/series`. Edit in `build/src`, commit, then run `scripts/patch.sh export`.
- `scripts/build.sh dev|release [targets]` (macOS, Linux) and `scripts/build.ps1` (Windows). `out/Dev` is a component build for iteration. `out/Release` is the official config.
- Design tokens live in `tokens/haze.json`. `scripts/gen_tokens.py` generates the C++ constants. Edit the JSON, never the generated file.

## Patch rules
- Keep hooks into Chromium as small as possible. An ideal patch adds an include, a call into `haze/` and a GN dep. Logic goes in `overlay/`.
- One patch = one concern. Each patch has a header with `Subject`, `Why` (1–3 sentences) and `Security-relevant: yes/no`.
- Don't reformat upstream code. Format only your own lines.
- Disable or hide upstream features instead of deleting them. Deleted upstream code means conflicts on every rebase.
- Touching `sandbox/`, `content/browser/renderer_host/`, `net/cert/`, `components/permissions/` or `third_party/blink/` requires a reason in the header.
- Respect DEPS rules. `content/` and Blink must not depend on `chrome/`. Code that has to run in Blink lives where Blink may use it.

## Layering (keeps mobile possible later)
- `haze/components/`: privacy, content blocker, fingerprinting, tracking parameters. **No dependency on `haze/browser/` or `chrome/browser/ui/`.**
- `haze/browser/`: desktop UI and desktop glue.
- Platform code goes in platform files the Chromium way (`*_mac.mm`, `*_win.cc`, `*_linux.cc`) and is selected in GN. No `#if BUILDFLAG(IS_MAC)` piles in shared code when a platform file would do.

## Chromium code
- Follow the Chromium C++ style guide and use what Chromium uses: `base::OnceCallback`/`RepeatingCallback`, `raw_ptr<>` for members, `base::WeakPtr`, `CHECK` for invariants that must hold in release builds.
- **Don't invent APIs.** Before using a class, function, pref, flag, AppKit or Win32 API, find it in `build/src` with `rg` or in the platform SDK. The pinned version is the truth, not your memory. For AppKit/DWM APIs, check the minimum OS version and add a fallback.
- Every Haze feature sits behind a `BASE_FEATURE` in `haze/common/haze_features.h` (prefix `kHaze`). User options are prefs with the prefix `haze.`.
- UI strings go only through GRD (`IDS_HAZE_*`), in English and German. No hardcoded strings.
- Colors, sizes, radii and opacities only from the generated tokens. No magic numbers in views.
- Unit tests go in the `haze_unittests` target. Browser tests go in `browser_tests` with a `Haze` prefix (`--gtest_filter=Haze*`).

## Privacy & security (hard rules)
- A fresh, idle profile makes **zero** network requests. Every request Haze makes on its own is listed in `docs/PRIVACY.md` and can be turned off. A new request without an entry there is a bug.
- No telemetry, no crash upload, no field trials, no "anonymous" statistics. Not even opt-in.
- Never weaken the sandbox, site isolation, the V8 sandbox, CFI and other hardening of official builds, the macOS hardened runtime, certificate verification, or mixed content blocking.
- No user data in URLs, logs or crash dumps.
- No Manifest V2 revival, no Google services, no AI features.

## Design: no AI slop
Haze should look like a browser designed by someone with taste, not a generated template. Quiet, precise, translucent, dense where it helps. The bar: the reference screenshot, Zen, Arc, Safari.

Forbidden:
- Purple-blue or rainbow gradients, glow effects, neon accents
- Blur or glass that Haze draws itself. Translucency comes only from the OS material (macOS glass/vibrancy, Windows Mica, KWin blur)
- Sparkle icons, robot or brain icons, emojis in Haze's own UI. (The only emojis are workspace icons the user picks.)
- Marketing copy like "Browse smarter" or "Your privacy, supercharged"
- Heavy shadows, cards inside cards, everything rounded to the max
- Random spacing, too many colors, too many font weights
- Animations that only exist to show off
- Anything that makes the Mac version feel like a Windows app (wrong fonts, custom fake traffic lights, non-native menus, Ctrl shortcuts)

Instead:
- **Surface:** sidebar and frame are one material, and the page is a card inset on it. Without a material, a solid color from the tokens.
- **Color:** neutral grays plus **one** accent, used sparingly (active tab, focus ring, toggles). Workspace accents tint the material only a little.
- **Type:** the platform's system font (SF Pro, Segoe UI Variable, the system UI font on Linux). 12–13 px in the sidebar, max 3 sizes and 2 weights, secondary text at about 60% opacity.
- **Icons:** platform system icons for standard actions (SF Symbols, Segoe Fluent Icons). Haze's own icons are drawn to match them.
- **Spacing:** 4 px grid. Radii concentric with the window corners.
- **Motion:** 150–250 ms, ease-out, functional only. Respect reduced motion and reduced transparency.
- **Copy:** short and plain. "New tab", not "Start a fresh browsing journey". Empty states without filler.
- **Details:** correct hover, pressed and focus states. Everything is reachable by keyboard. No layout jumps. Looks right at 100–200% scaling and on Retina.
- When in doubt, leave it out.

## Code: no AI slop
- Comments explain why, not what.
- No speculative abstractions. No `Manager` or `Helper` classes without a real need, no interfaces with one implementation "for later". The only "for later" thing is the layering above.
- No dead code, no commented-out blocks, no TODO without a step or bug reference.
- Clear names, small functions, consistent with the surrounding Chromium code.

## Folders
- `overlay/`: Haze sources (`components/`, `browser/`, `common/`, `renderer/`)
- `patches/`: `core/`, `privacy/`, `security/`, `ui/`, `mac/`, `win/`, `linux/` plus `series`
- `tokens/`: `haze.json`
- `flags/`: `dev.gn`, `release.gn`
- `scripts/`: fetch, prepare, build, patch, tokens, netcheck, bench, package, rebase
- `test/data/`: local test pages
- `docs/`: SPEC, PROGRESS, PATCHES, PRIVACY, SECURITY, PERF, REBASE, DESIGN, `reference/`, `screens/`
- `build/`: gitignored (source tree, `out/`, logs, test profiles)

## Workflow (important)
- Work **only on the current step**. Nothing from later steps.
- Before coding, give a short plan (max. 5 points), including which Chromium files you will touch and which platforms are affected.
- Build only the targets you need. Run long builds in the background and read only the end of the log and the errors.
- Test profiles go in `build/profiles/`, never the real user profile.
- At the end of every step:
  - build the affected targets and run the Haze tests
  - `scripts/patch.sh export` produces no unexpected diff, and `scripts/patch.sh check` is clean
  - `scripts/netcheck.sh` still reports zero requests (from step 8 on)
  - UI steps: screenshots in `docs/screens/<step>/` and the remaining differences to the reference in `PROGRESS.md`
  - if you could only test one platform, say which ones still need a check
  - add a few lines to `docs/PROGRESS.md` (what's new, how to test it) and update `docs/PATCHES.md`
  - give a short summary, then **stop**
- If an architecture decision is unclear, ask first, then build.
