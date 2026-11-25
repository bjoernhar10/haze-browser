# Haze – Build Spec

You are an experienced Chromium engineer. We are building **Haze**, a desktop browser based on Chromium for **macOS, Windows and Linux**. It focuses on privacy, security and performance. Its look is a calm, sidebar-first UI on a translucent window, in the spirit of Zen Browser, with its own design. Haze should feel native on every platform, especially on the Mac. Mobile (Android, iOS) comes later and is planned for now, not built.

Haze is a **patch set on top of Chromium stable and ungoogled-chromium**, not a hard fork. Every decision has to keep rebasing onto new Chromium releases cheap, because that is how Haze stays secure.

Work in the phases below. State your plan briefly before you start a phase. If an architecture decision is not settled here, ask before you build.

---

## 1. Base & build (decided)

- **Chromium stable**, version pinned in `chromium_version.txt`.
- **ungoogled-chromium** as the base layer: a git submodule pinned to the tag that matches the Chromium version. Its pruning, patches, domain substitution and `flags.gn` are applied before anything from Haze. Platform repos (`ungoogled-chromium-macos`, `-windows`, `-portablelinux`) show how each platform is built.
- **Pipeline:** download source tarball → prune binaries → ungoogled patches → domain substitution → baseline commit in `build/src` → Haze patches (one git commit per patch). Haze patches are made against the substituted tree.
- **New code** lives in `overlay/` and is synced to `build/src/haze/` before each build. **Changes to existing Chromium files** are patches in `patches/`, applied in the order from `patches/series`. A good patch only adds an include, a call into `haze/` and a GN dependency.
- **Build:** GN + autoninja. Two configs: `out/Dev` (component build, for iteration) and `out/Release` (official, optimized).
- **Languages:** C++ (Chromium style), Objective-C++ for macOS-specific code, TypeScript/HTML/CSS for WebUI pages where Chromium uses them, Rust only for the integrated adblock-rust crate, Bash/PowerShell/Python for scripts.
- **License:** Haze's own code is BSD-3-Clause, like Chromium. Vendored third-party code gets `README.chromium` metadata and its license file so it shows up in `chrome://credits`.

## 2. Platforms

| Platform | v1 target | Look |
|---|---|---|
| macOS | Apple Silicon (arm64). Minimum = what the pinned Chromium supports | Full look on macOS 26+ (Liquid Glass), vibrancy fallback on older versions |
| Windows | Windows 11 x64 (Windows 10 as long as Chromium supports it) | Mica on Windows 11, solid fallback on Windows 10 |
| Linux | x64, Wayland first, X11 supported | Blur on KDE Plasma if feasible, solid elsewhere |

Linux is the main development platform, because builds and tests are fastest there. Every phase has to build and run on all three platforms before it counts as done.

### Mobile later (plan now, don't build)
- **Android:** a Chromium-based app with the same patch set approach. Chromium's Android UI is a separate Java/Kotlin layer, so the Android UI will be its own phase.
- **iOS:** in most regions, iOS browsers have to use WebKit. Haze for iOS would be a WebKit app that reuses Haze's design, filter lists and privacy rules, not the Chromium code.
- **What this means for desktop now:** privacy, content blocking and fingerprinting logic lives in `haze/components/` without any dependency on desktop UI code, so Android can reuse it. Design tokens (colors, spacing, radii, type sizes) live in one platform-neutral file, `tokens/haze.json`. C++ constants are generated from it now, Kotlin and Swift later. Nothing else is built for mobile in v1.

## 3. Privacy

**Baseline rule:** a fresh profile sitting idle makes **zero** network requests. Every request Haze makes on its own is listed in `docs/PRIVACY.md` (what, when, why, how to turn it off). The only allowed exceptions are filter list updates, update checks (Windows, macOS), and Chrome Web Store traffic when the user installs or updates an extension.

ungoogled-chromium already removes most Google traffic, telemetry and field trials. Verify each point in the code; don't assume it from a patch name.

Haze defaults:

| Area | Default |
|---|---|
| Third-party cookies | Blocked |
| HTTPS | HTTPS-First, warning before loading HTTP |
| Secure DNS | Automatic upgrade. Provider picker: Quad9, Mullvad, Cloudflare, custom |
| Search engine | Chosen on first run, no preselection. DuckDuckGo, Startpage, Brave Search, Qwant, Ecosia, Kagi, custom. No Google default |
| Search suggestions | Off (opt-in) |
| Preloading / network prediction | Off |
| WebRTC | `default_public_interface_only` (no local IP leak) |
| Global Privacy Control | On (`Sec-GPC: 1` + `navigator.globalPrivacyControl`) |
| Tracking parameters | Stripped from top-level navigations (`utm_*`, `fbclid`, `gclid`, `msclkid`, …) |
| Content blocking | On, see below |
| Fingerprinting protection | Standard, see below |
| AI features (Gemini, Help me write, AI history search, tab organizer, …) | Disabled and hidden |
| Privacy Sandbox ad APIs (Topics, Protected Audience, Attribution Reporting, …) | Off |
| Clear data on exit | Available, off by default |
| Telemetry, crash upload, field trials | None, not even opt-in |

### Content blocker
- **Native, not an extension.** Chromium has removed Manifest V2 completely, and MV3 limits what blockers can do.
- **Engine:** [adblock-rust](https://github.com/brave/adblock-rust) (MPL-2.0), built with Chromium's Rust toolchain, in `haze/components/`. Network filtering first, cosmetic filtering (element hiding) second.
- **Default lists:** EasyList, EasyPrivacy, uBlock filters (incl. privacy and unbreak), Peter Lowe's list. Optional: EasyList Germany, a cookie banner list. Check each list's license and credit it.
- A snapshot of the lists is bundled at build time. Updates are fetched weekly **directly from the list sources** with conditional requests. Haze has no server.
- Blocks in main frames, iframes and workers, for all resource types.
- Per-site toggle and blocked count in a "Shield" button in the URL field.

### Fingerprinting protection (standard level, must not break sites)
- Canvas readback, WebGL readback and AudioContext: small deterministic noise, seeded per session and per eTLD+1. The seed is never persisted.
- WebGL unmasked vendor/renderer: generic values.
- `navigator.hardwareConcurrency`: coarse buckets.
- Battery Status API: off.
- User-Agent: Chromium's reduced UA for the same major version, **no Haze token**. Blending in beats branding.
- Per-site off switch in the Shield panel.

## 4. Security

- **Never weaken:** sandbox, site isolation, V8 sandbox, CFI and other hardening of official builds, macOS hardened runtime, certificate verification, mixed content blocking.
- **Safe Browsing** is removed by ungoogled-chromium, because it talks to Google. This is a known trade-off, documented in `docs/SECURITY.md`. There is no replacement in v1.
- **JIT toggle:** global "Disable JavaScript optimizer" setting with per-site exceptions, built on Chromium's existing V8 optimizer content setting. No custom V8 patches.
- **Updates:** Haze follows Chromium stable. When a Chromium security release comes out, Haze ships for all three platforms as soon as the rebase builds. The process is in `docs/REBASE.md`.
- **Extensions:** MV3 only. Installing and updating from the Chrome Web Store works. That is the only Google contact, and it is listed in `docs/PRIVACY.md`.
- **Releases:** SHA-256 checksums and a GPG signature for every artifact. On macOS, Developer ID signing and notarization. On Windows, Authenticode signing once there's a certificate.
- Patches that touch `sandbox/`, `content/browser/renderer_host/`, `net/cert/`, `components/permissions/` or `third_party/blink/` need an explicit reason in the patch header.

## 5. Performance

- **Release build:** official build, ThinLTO, PGO profiles for the pinned version if they can be fetched, `symbol_level=0`. Optional x86-64-v3 (AVX2) variant on Windows and Linux next to the baseline build.
- **Memory Saver** on by default. Tabs in inactive workspaces are the first to be discarded.
- **No extra startup work:** Haze features initialize lazily.
- **Translucency comes from the OS** (macOS materials, Windows Mica, KWin blur). Haze never blurs anything itself.
- **Custom UI is as fast as stock UI:** no polling timers, no layout work per frame, no repaint storms on hover. Animations run at the display's refresh rate (120 Hz on ProMotion Macs).
- **Benchmarks** against the official ungoogled-chromium release of the same version on each platform, results in `docs/PERF.md`: cold start (median of 10), Speedometer 3, memory after loading 20 fixed URLs, idle CPU over 5 minutes. Haze must not be slower than the baseline beyond noise.

## 6. Visual target

`docs/reference/target.png` is the target look. **Not a 1:1 copy, but someone who sees both should say "same feel".** These are the things that make that look, and all of them are required:

1. **One surface.** Sidebar and window frame are one continuous translucent material; the desktop shows through, blurred by the OS. There is no line between the sidebar and the frame.
2. **Content as a card.** The page area is inset from the frame on top, right and bottom (6–8 px), has rounded corners (~10 px, concentric with the window corners) and a faint edge. It sits on the material like a card.
3. **Top row.** Window controls, then back / forward / reload and one action button, all in one row at the top of the sidebar. Icons small and muted.
4. **URL field.** A rounded field across the sidebar width, a little lighter than the material, with a search icon and muted placeholder text. One line, ellipsized.
5. **Essentials.** A 3-column grid of rounded tiles in the same fill as the URL field, with a centered favicon.
6. **Workspace header.** The workspace icon and name above its tabs, medium weight.
7. **Tab rows.** Favicon and title, about 32 px tall, no close button until hover. The active tab gets a soft fill, hover a lighter one. "+ New tab" in muted text.
8. **Bottom bar.** Settings on the left, workspace icons in the middle, downloads on the right, all small and muted.
9. **Quiet type.** Small sizes (12–13 px), secondary text at about 60% opacity, no bold anywhere except headers.
10. **Empty tab.** A new or empty tab shows the window material through the card, not a white page.
11. **Dark is the hero look.** Light mode keeps the exact same structure.

```
+-------------------------+-------------------------------------------+
| (o)(o)(o)  *  <  >  R   | +---------------------------------------+ |
| [ Search or enter URL ] | |                                       | |
| [ E ] [ E ] [ E ]       | |                                       | |
| [ E ] [ E ] [ E ]       | |                                       | |
|  @ Personal             | |            web content                | |
|  # ChatGPT              | |            (card on the material)     | |
|  # YouTube              | |                                       | |
|  + New tab              | |                                       | |
|                         | |                                       | |
| *       @  @  @       v | +---------------------------------------+ |
+-------------------------+-------------------------------------------+
  E = Essentials   @ = workspace icon   * = action/settings   v = downloads
```

**Acceptance for every UI step:** screenshots of every affected state in `docs/screens/<step>/` (`<platform>-<light|dark>.png`, at least the platform you worked on), compared with the reference, plus a short list of remaining differences in `PROGRESS.md`. Measured values (sizes, spacing, radii, opacities) go into `docs/DESIGN.md` and `tokens/haze.json`, never as magic numbers in code.

## 7. UI / UX

### Features
- **Sidebar** (left by default, can be moved right, resizable, width persists): built on **Chromium's native vertical tabs**. Extend them, don't rebuild them. The horizontal toolbar disappears; everything from it lives in the sidebar's top row and URL field.
- **Essentials:** up to 12 tiles, shared across all workspaces, never closed by "clear".
- **Pinned tabs:** per workspace, directly under the workspace header. If a pinned tab has navigated away from its pinned URL, it shows a small "back to pinned page" affordance.
- **Clear:** when a workspace has unpinned tabs, a thin divider with a "clear" button appears (visible on hover) and closes all unpinned tabs.
- **Workspaces:** per window, each with a name, an icon, an accent color, its own pinned tabs and tabs. Icon: from Haze's icon set by default, or an emoji the user picks (like in the reference). Switch via the bottom bar, keyboard shortcut, or a horizontal two-finger swipe over the sidebar. Survive restarts.
- **Compact mode:** sidebar hidden, the card uses the whole window. When the pointer stays at the sidebar edge for ~120 ms, the sidebar slides in as an overlay with the same material (the page is not resized) and hides again when the pointer leaves.
- **Command bar:** the new-tab and URL shortcuts open the omnibox as a floating, centered panel over the card. New tab only creates the tab on Enter. Escape leaves no empty tab behind. Results include open tabs from all workspaces.
- **Glance:** modifier+click on a link (and Force Click on Mac) opens it in a floating panel over the current tab (~85% of the card, dimmed backdrop). Esc closes it. "Open as tab" moves it into a real tab without reloading. "Split" puts it in split view.
- **Split view:** built on **Chromium's native Split View**. Haze adds only what upstream lacks in the pinned version (draggable divider, drag a tab onto the card to split, split pair as one sidebar row).
- **Theming:** the OS material is the base. The workspace accent tints the material slightly (≤ ~6% mix) and colors accent elements. Light / dark / system. Without a material (Reduce Transparency, Windows 10, GNOME), a solid color from the tokens that matches the reference's tone.
- **Motion:** 150–250 ms, ease-out, only where it helps orientation (sidebar slide, glance, workspace switch). Respects reduced motion on every platform.
- **Settings:** Haze sections in `chrome://settings` ("Look & layout", "Workspaces", "Shields"). Settings that make no sense in Haze (sign-in, sync, Google services, AI) are hidden.
- **First run:** one page with a search engine picker, theme, import from another browser, and "Done". No account, no marketing copy.
- **Languages:** English and German.

### Native on each platform
Haze has one layout, but on each OS it uses that OS's materials, controls, fonts and conventions. A Mac user should never feel they're in a port.

**macOS**
- Window: full-size content view, hidden titlebar. The traffic lights sit in the sidebar's top row, vertically centered with the nav buttons. In compact mode they appear together with the sidebar.
- Material: `NSGlassEffectView` (Liquid Glass) on macOS 26+, `NSVisualEffectView` with a behind-window sidebar material on older versions. Follows Reduce Transparency and Increase Contrast live.
- Corners: the card's radius is concentric with the system window corner radius of the running macOS version.
- Font: the system font (SF Pro), with SF's optical sizes. Standard actions (back, forward, reload, settings, downloads, share) use SF Symbols through the system API. Haze's own icons are drawn to match SF Symbols' regular weight.
- Menus: a complete native menu bar (Haze, File, Edit, View, History, Workspaces, Window, Help), "Settings…" on Cmd+,, native context menus, native share menu.
- Input: Cmd-based shortcuts with Mac conventions, two-finger swipe on the page for back/forward (Chromium's native history swipe), two-finger swipe on the sidebar for workspaces, Force Click on a link for Glance.
- Fullscreen: native fullscreen in its own Space. Sidebar and menu bar reveal on hover at the edges.
- System accent color for focus rings, live switching between light and dark.
- App icon made with Apple's current icon template (layered, with light, dark and tinted variants).
- Distribution: DMG with drag-to-Applications, Developer ID signed, notarized, hardened runtime. Updates with Sparkle 2 (EdDSA-signed appcast), listed in PRIVACY.md and can be turned off.

**Windows**
- Material: Mica (or Mica Alt, whichever matches the reference better) through the DWM system backdrop on Windows 11. Solid color on Windows 10 and when "Transparency effects" is off.
- Caption buttons: native-looking minimize/maximize/close at the top right, with the Snap Layouts flyout on hover over maximize. Placement must not cover page content.
- Font: Segoe UI Variable. Standard actions use Segoe Fluent Icons. Haze's own icons are drawn to match.
- Respects high contrast mode, system accent color, and Windows 11's rounded window corners.
- Per-user installer, update check (see step list), listed in PRIVACY.md.

**Linux**
- Wayland first, X11 supported. Client-side decorations with the window buttons in the order from `gtk-decoration-layout`.
- KDE Plasma: blur behind the sidebar through KWin's blur protocol if it can be wired up in Ozone without a huge patch, otherwise solid. GNOME: solid, no fake blur.
- Font: the system UI font via fontconfig. Icons: Haze's icon set.
- Packages: tar.xz, AppImage, PKGBUILD (Arch), RPM spec (Fedora).

### Keyboard shortcuts

| Action | Windows / Linux | macOS |
|---|---|---|
| Command bar, current tab | Ctrl+L | Cmd+L |
| Command bar, new tab | Ctrl+T | Cmd+T |
| Tab 1–8 / last tab (active workspace only) | Ctrl+1…8 / Ctrl+9 | Cmd+1…8 / Cmd+9 |
| Workspace 1–9 | Ctrl+Shift+1…9 (proposed) | Cmd+Option+1…9 (proposed) |
| Toggle sidebar | Ctrl+Shift+S (proposed) | Cmd+Option+S (proposed) |
| Compact mode | Ctrl+Shift+E (proposed) | Cmd+Option+E (proposed) |
| Split with next tab / unsplit | free combo, by the rules below | free combo, by the rules below |
| Glance | Alt+click | Option+click, Force Click |
| Settings | menu | Cmd+, |

Rules: **no Ctrl+Alt combinations on Windows/Linux.** On Windows, Ctrl+Alt is AltGr on German and many other layouts and types characters like `{ [ ] } \ @`. **On macOS, no Option combinations without Cmd**, because Option+key types characters. Check each shortcut against Chromium's accelerator tables for each platform and the default shortcuts of macOS, Windows, GNOME and KDE before you use it.

## 8. Repo structure

```
haze/
  CLAUDE.md
  chromium_version.txt
  ungoogled-chromium/          # submodule, pinned tag
  tokens/haze.json             # design tokens, source of truth
  patches/
    series
    core/  privacy/  security/  ui/  mac/  win/  linux/
  overlay/                     # Haze sources -> build/src/haze/
    components/                # privacy, blocker, fingerprinting (no UI deps)
    browser/                   # desktop UI (*_mac.mm, *_win.cc, *_linux.cc)
    common/
    renderer/
    BUILD.gn
  flags/
    dev.gn  release.gn
  scripts/
    lib.sh fetch.sh prepare.sh build.sh build.ps1 patch.sh
    gen_tokens.py netcheck.sh bench.sh rebase.sh
    package-linux.sh package-win.ps1 package-mac.sh
  test/data/                   # local test pages
  docs/
    SPEC.md PROGRESS.md PATCHES.md PRIVACY.md SECURITY.md
    PERF.md REBASE.md DESIGN.md
    reference/target.png
    screens/
  build/                       # gitignored: source, out/, logs, profiles
```

## 9. Phases

1. **Build pipeline:** pin, fetch, prune, ungoogled patches, patch workflow, branding, first builds on Linux, macOS and Windows.
2. **Privacy & security:** zero-request baseline, defaults, tracking parameters, content blocker, fingerprinting, JIT toggle, extension store, security docs.
3. **Look & feel:** tokens and design measurements, sidebar, native window chrome per platform, workspaces, compact mode, command bar, Glance, split view, settings and first run, visual pass against the reference.
4. **Ship:** performance, icon, packaging and updates per platform, rebase playbook.

**Definition of done for each phase:** builds and runs on all three platforms, Haze tests pass, `patch.sh check` is clean against a fresh baseline, `netcheck.sh` reports zero requests, screenshots are in `docs/screens/`, and the docs are updated.

## 10. Non-goals (v1)

- No accounts, no sync server, no Haze backend of any kind.
- No AI features, no crypto wallet, no rewards, no news feed, no sponsored tiles.
- No own search engine, no VPN.
- No mobile apps yet (only the preparation from section 2).
- No macOS Intel build yet.
- No renaming `chrome://` to `haze://`: too invasive for rebases.
- No containers. Chromium has profiles instead.
- No Manifest V2 revival.
- No custom blur or fake glass drawn by Haze.
