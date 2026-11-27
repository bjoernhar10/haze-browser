# Haze privacy status

The privacy rules come from `docs/SPEC.md` §3. This file tracks each one
against what the code actually does, and lists every request Haze makes on its
own.

**Status values**

- **covered**: the pinned tree already behaves as SPEC asks. "By ungoogled"
  or "by Chromium" says who made it so.
- **covered by Haze**: a Haze patch or Haze's default-prefs hook makes it so;
  the patch is named.
- **needs a Haze patch**: SPEC asks for something the tree does not do, or
  does differently.
- **not doing**: deliberately left as it is, with the reason.

Every "covered" row was checked in `build/src` (Chromium 158.0.8127.88 with
ungoogled-chromium 158.0.8127.88-1 applied), at the line that sets the
default, not by patch name. Two of them were caught only that way:
ungoogled's `disable-ai.patch` leaves Gemini and "Help me write" on, and WebGL
spoofing lives in a patch named after a flag.

## Baseline rule

| Rule | Status | Evidence |
|---|---|---|
| A fresh, idle profile makes zero network requests | **covered** (Linux, 5 min) | `scripts/netcheck.sh` on 2026-11-27: 0 URL requests, 0 host name lookups, 0 connections, 0 sockets. See "Network check" below. |

## Defaults

| Area | SPEC | Today | Status | Evidence |
|---|---|---|---|---|
| Third-party cookies | Blocked | Blocked | **covered** by ungoogled | `components/content_settings/core/browser/cookie_settings.cc`: `kCookieControlsMode` registered as `kBlockThirdParty` (inox `0006-modify-default-prefs`; Chromium's default is `kIncognitoOnly`). |
| HTTPS | HTTPS-First, warn before loading HTTP | Strict HTTPS-First on | **covered by Haze** | `privacy/apply-hazes-profile-pref-defaults…`: `haze::SetProfilePrefDefaults` sets `kHttpsOnlyModeEnabled` to `true` (Chromium registers `false` in `chrome/browser/ui/browser_ui_prefs.cc`). |
| Secure DNS | Automatic upgrade; picker with Quad9, Mullvad, Cloudflare, custom | Automatic; dropdown offers Quad9, Mullvad, Cloudflare and custom | **covered by Haze** | `privacy/upgrade-dns-to-dns-over-https-automatically.patch`: back to `SecureDnsMode::kAutomatic` and `kDnsOverHttpsUpgrade` on (ungoogled had both off); the DoH probe asks for `example.com`, because domain substitution had turned its Google name into one that never resolves, so automatic mode could never upgrade; Mullvad added (`dns.mullvad.net`, `194.242.2.2`, `2a07:e340::2`, checked before adding); Quad9's entry switched on; every other provider removed from the dropdown but kept for the upgrade mapping. The probe is a request of its own, see below. |
| Search engine | Chosen on first run, no preselection; DuckDuckGo, Startpage, Brave Search, Qwant, Ecosia, Kagi, custom; no Google default | DuckDuckGo default; no first-run choice yet | **covered by Haze** until step 27, then **needs a Haze patch** | `privacy/make-duckduckgo-the-default-search-engine.patch`: `GetPrepopulatedFallbackSearch` returns DuckDuckGo, also in the 11 regions (CN, HK, KH, KR, LA, MN, MO, TW, UZ, VN and the unknown-country list) that do not list it. The first-run picker, Startpage, Qwant and Kagi come in step 27. |
| Search suggestions | Off (opt-in) | Off | **covered** by ungoogled | `chrome/browser/profiles/profile.cc`: `kSearchSuggestEnabled` registered `false` (inox `0006`). |
| Preloading / network prediction | Off | Off | **covered** by ungoogled | `chrome/browser/preloading/preloading_prefs.h`: `NetworkPredictionOptions::kDefault = kDisabled` (inox `0006`; Chromium's is wifi-only). |
| WebRTC | `default_public_interface_only` | `default_public_interface_only` | **covered by Haze** | `haze::SetProfilePrefDefaults` sets `kWebRTCIPHandlingPolicy` (ungoogled registers `disable_non_proxied_udp`, which takes UDP away from calls without a proxy). |
| Global Privacy Control | On: `Sec-GPC: 1` and `navigator.globalPrivacyControl` | On, with a toggle in the cookie settings | **covered by Haze** | `privacy/turn-on-global-privacy-control.patch`: `kUniversalOptOutSettings` enabled and Blink's `GlobalPrivacyControlApi` moved from experimental to stable; `haze::SetProfilePrefDefaults` sets `universal_optout.enabled` to `true`. |
| Tracking parameters | Stripped from top-level navigations | Not stripped | **needs a Haze patch** | Nothing in Chromium or ungoogled removes `utm_*`, `fbclid`, `gclid`, `msclkid`. |
| Content blocking | On (native adblock-rust) | None | **needs a Haze patch** | Not part of Chromium or ungoogled; planned in `haze/components/`. |
| Fingerprinting protection | Standard | Partial and off by default | **needs a Haze patch** | See the fingerprinting table below. |
| AI features | Disabled and hidden | Off; nothing shown | **covered by Haze** | `privacy/turn-off-and-hide-the-ai-features.patch`; the full list is under "AI features turned off" below. ungoogled's `disable-ai.patch` had removed only the model downloads. |
| Privacy Sandbox ad APIs | Off | Off, and gone from the web platform | **covered by Chromium and Haze** | Chromium retired most of it by M158 (`document.browsingTopics()` throws, `joinAdInterestGroup()` is a no-op, the Attribution Reporting browser code is gone). Step 8 called this covered, but three surfaces were still reachable from pages: `privacy/turn-off-the-privacy-sandbox-ad-apis-that-pages-can-still-reach.patch` removes them, and Related Website Sets are off. See "Privacy Sandbox APIs turned off" below. |
| Clear data on exit | Available, off by default | Available as a flag, off | **covered** by ungoogled | `chrome/browser/browser_features.cc`: `kClearDataOnExit` `FEATURE_DISABLED_BY_DEFAULT`, flag `clear-data-on-exit`; it deletes all browsing data in `chrome_browsing_data_lifetime_manager.cc`. Chromium's own "delete cookies and site data on close" setting also exists. A visible setting belongs to the settings UI step, not here. |
| Telemetry | None, not even opt-in | None | **covered** by ungoogled | UMA consent defaults to `GoogleUpdateSettings::GetCollectStatsConsent()`, which on Linux is true only if a client-ID backup file exists, so false on a fresh profile (`chrome/installer/util/google_update_settings_posix.cc`); the upload hosts are domain-substituted. The settings toggle sits inside `<if expr="_google_chrome">` in `personalization_options.html`, so a Chromium-branded build has no opt-in at all. |
| Crash upload | None | None | **covered** by ungoogled | Upload consent mirrors the metrics consent (`chrome/app/chrome_crash_reporter_client.cc`), and the upload URL is domain-substituted (`https://clients2.9oo91e.qjz9zk/cr/report` in `components/crash/core/app/crash_reporter_client.cc`). Crashpad still keeps a local database (see notes). |
| Field trials | None | None | **covered** by ungoogled | `components/variations/service/variations_service.cc`: `IsFetchingEnabled()` returns `false`; the seed URL is domain-substituted; `disable_fieldtrial_testing_config=true` in ungoogled's `flags.gn`. |

## AI features turned off

Each is switched off where its default is defined, so `chrome://flags` and
policies still see the upstream switch. On Linux, `kGlic` was already off.

| Feature | Where | What it was |
|---|---|---|
| `kGlic` | `chrome/common/chrome_features.cc` | Gemini in Chrome: toolbar button, side panel, context menu, hotkey. On by default on macOS and Windows. |
| `kGlicActor` | `chrome/common/chrome_features.cc` | Gemini acting on pages for the user |
| `kEnableCompose` | `components/compose/core/browser/compose_features.cc` | "Help me write" in text fields |
| `kNtpComposebox` | `chrome/browser/ui/webui/new_tab_page/composebox/variations/composebox_fieldtrial.cc` | AI compose box on the New Tab page |
| `kOptimizationGuideModelExecution` | `components/optimization_guide/core/optimization_guide_features.cc` | Server-side model execution behind the features above |
| `AIPromptAPI` (`LanguageModel`), `AISummarizationAPI` (`Summarizer`), `TranslationAPI` (`Translator`), `LanguageDetectionAPI` (`LanguageDetector`) | `third_party/blink/renderer/platform/runtime_enabled_features.json5`: stable → experimental | Built-in AI APIs exposed to every page; without models they only fail, and their presence is one more fingerprinting bit |

Already off before Haze: AI history search (`kHistoryEmbeddings`), the AI
settings page (ungoogled forces `showAiPage` to false), the Writer, Rewriter
and Proofreader APIs (experimental), and all on-device model downloads
(ungoogled's `disable-ai.patch`).

## Privacy Sandbox APIs turned off

| API | How | Why both |
|---|---|---|
| Topics (`document.browsingTopics`, `Sec-Browsing-Topics`) | `network::features::kBrowsingTopics` off and the Blink `TopicsAPI` status removed | `content/child/runtime_features.cc` copies a disabled base::Feature into Blink only when it is overridden, not when it is merely off by default |
| Attribution Reporting (`attributionsrc`, `Attribution-Reporting-*`) | `attribution_reporting::features::kConversionMeasurement` off and the Blink `AttributionReporting` status removed | same |
| Fenced frames (`<fencedframe>`, the Protected Audience rendering surface) | `blink::features::kFencedFrames` off | `ResolveInvalidConfigurations()` turns the Blink feature off whenever this one is off |
| Related Website Sets | `privacy_sandbox.related_website_sets_enabled` default `false` (Haze default prefs) | they let a declared group of sites share cookies while third-party cookies are blocked |

Left as they are: Private State Tokens, an anti-fraud API rather than an ad
API (SPEC names ad APIs), and the M1 prefs for Topics, Protected Audience and
ad measurement, which are still registered `false` and now gate nothing.

## Fingerprinting protection (standard level)

| Item | SPEC | Today | Status | Evidence |
|---|---|---|---|---|
| Canvas readback noise | Small deterministic noise, seeded per session and eTLD+1, seed never persisted | Optional noise behind flags, off | **needs a Haze patch** | ungoogled's `fingerprinting-canvas-image-data-noise`, `-measuretext-noise` and `fingerprinting-client-rects-noise` (`components/ungoogled/ungoogled_switches.cc`) are command-line flags, off by default, and not seeded per eTLD+1. |
| WebGL readback noise | Same | None | **needs a Haze patch** | No noise on WebGL `readPixels` in Chromium or ungoogled. |
| AudioContext noise | Same | None | **needs a Haze patch** | None in Chromium or ungoogled. |
| WebGL unmasked vendor/renderer | Generic values | Real GPU strings | **needs a Haze patch** | `webgl_rendering_context_base.cc` returns spoofed strings only with ungoogled's `kSpoofWebGLInfo`, which is `FEATURE_DISABLED_BY_DEFAULT` (`third_party/blink/common/features.cc`). |
| `navigator.hardwareConcurrency` | Coarse buckets | Real core count | **needs a Haze patch** | `navigator_base.cc` returns a fixed 2 only with ungoogled's `kReducedSystemInfo`, off by default; buckets are not implemented. |
| Battery Status API | Off | Always reports a charging, full battery | **covered** by ungoogled | `services/device/battery/battery_status_service.cc`: `AddCallback` always passes the default `BatteryStatus()`, and no real status is ever forwarded (inox `0019-disable-battery-status-service`). `navigator.getBattery()` still exists and returns the same values for everyone, which reveals nothing. |
| User-Agent | Chromium's reduced UA, no Haze token | Reduced UA, no Haze token | **covered** by Chromium | `ReduceUserAgentMinorVersion` is `stable`; step 5 verified `Chrome/158.0.0.0` and UA-CH brands `Chromium 158` in the running browser. |
| Per-site off switch | In the Shield panel | — | **needs a Haze patch** | Part of the Shield UI. |

## Requests Haze makes on its own

SPEC allows filter list updates, update checks and Chrome Web Store traffic.
Secure DNS adds one more, decided in step 9 because SPEC asks for automatic
upgrade, which cannot work without it:

| Request | When | Why | How to turn it off |
|---|---|---|---|
| DoH probe: one DNS-over-HTTPS query for `example.com` | Only when the system's DNS server is one of the known providers in `net/dns/public/doh_provider_entry.cc` (e.g. 1.1.1.1, 9.9.9.9, 194.242.2.2), at startup and after network changes, with backoff while the server fails. It goes to that same provider's DoH endpoint, never to anyone else. Never with a router or ISP resolver Chromium does not know. | Automatic mode only switches to DoH once a probe has succeeded | Settings → Privacy and security → Security → "Use secure DNS" off |
| Filter list updates | — (content blocker not built yet) | | |
| Update checks (Windows, macOS) | — (no updater yet) | | |
| Chrome Web Store | — | only when the user installs or updates an extension | |

## Network check

`scripts/netcheck.sh` starts the browser with a brand-new profile on
`about:blank`, leaves it idle for five minutes and lists everything that went
out, from two independent sources: a NetLog (URL requests with the traffic
annotation that names the code behind them, host name lookups, TCP/UDP
connects) and `ss`, sampled every second for sockets owned by the browser's
processes, which also sees traffic outside the network service.

**Result on Linux x64, 2026-11-27: zero requests**, both on the step-8
build and again after step 9's defaults (Secure DNS automatic,
DuckDuckGo, GPC). The DoH probe did not fire here because the system
resolver is the router, which is not a known DoH provider.

| | |
|---|---|
| Build | `out/Dev`, Chromium 158.0.8127.88 + ungoogled + 10 Haze patches |
| Profile | new, first run included (no `--no-first-run`), idle on `about:blank` for 300 s, then a clean shutdown |
| URL requests | 0 |
| Host name lookups | 0 |
| TCP/UDP connections | 0 |
| Sockets seen by `ss` | 0 |
| NetLog events in total | 17, all local: cookie store load and close, HTTP server properties, network quality, QUIC pool shutdown |

The tool was checked against a positive control: the same run on
`https://example.org` reports both URL requests with their annotations
(`navigation_url_loader` in `content/browser/loader/navigation_url_loader_impl.cc`,
`blink_resource_loader` in `third_party/blink/renderer/platform/loader/fetch/fetch_utils.cc`),
the host name lookups, the TCP and QUIC connections, and `ss` sees the same two
sockets. The annotation hash matches Chromium's own test value
(`"test"` → 3556498).

Limits: five minutes catches startup and early timers, not tasks scheduled
hours later. Only Linux has been measured; `netcheck.sh` needs another way to
sample sockets on macOS and Windows.

```sh
scripts/netcheck.sh            # dev build, 5 min; exit 0 = zero requests
HAZE_NETCHECK_SECONDS=60 scripts/netcheck.sh   # shorter, for a quick look
```

## Notes

- **Crashpad's local database.** Crashpad keeps its database, including a
  client ID in `settings.dat`, in the default profile directory, even with
  `--user-data-dir` (`chrome/common/chrome_paths.cc`, crbug.com/40447560).
  Nothing is uploaded, but the client ID is a stable local identifier.
