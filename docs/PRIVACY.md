# Haze privacy status

The privacy rules come from `docs/SPEC.md` §3. This file tracks each one
against what the code actually does, and lists every request Haze makes on its
own.

**Status values**

- **covered**: the pinned tree already behaves as SPEC asks. "By ungoogled"
  or "by Chromium" says who made it so.
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
| HTTPS | HTTPS-First, warn before loading HTTP | HTTPS upgrades and "balanced" mode on; the strict mode that warns before every HTTP page is off | **needs a Haze patch** | `chrome/browser/ui/browser_ui_prefs.cc`: `kHttpsOnlyModeEnabled` = `false`. `kHttpsUpgrades` and `kHttpsFirstBalancedModeAutoEnable` are enabled (`chrome/common/chrome_features.cc`), so HTTP is upgraded where possible and warned about only on some sites. |
| Secure DNS | Automatic upgrade; picker with Quad9, Mullvad, Cloudflare, custom | **Off** | **needs a Haze patch** | ungoogled's `doh-changes.patch` sets the default to `SecureDnsMode::kOff` in `chrome/browser/net/default_dns_over_https_config_source.cc` (Chromium's is `kAutomatic`). `net/dns/public/doh_provider_entry.cc` lists Quad9 and Cloudflare but no Mullvad. |
| Search engine | Chosen on first run, no preselection; DuckDuckGo, Startpage, Brave Search, Qwant, Ecosia, Kagi, custom; no Google default | Default is "No Search"; offered: DuckDuckGo, Brave, Bing, Ecosia; no first-run choice | **needs a Haze patch** | Read from `chrome://settings/searchEngines` in a fresh profile (region: Germany; the prepopulated list depends on the region). ungoogled's `replace-google-search-engine-with-nosearch.patch` puts "No Search" where Google was, so there is no Google default and no preselection that sends queries anywhere. Missing: the first-run chooser, Startpage, Qwant and Kagi; Bing is offered although SPEC does not list it. |
| Search suggestions | Off (opt-in) | Off | **covered** by ungoogled | `chrome/browser/profiles/profile.cc`: `kSearchSuggestEnabled` registered `false` (inox `0006`). |
| Preloading / network prediction | Off | Off | **covered** by ungoogled | `chrome/browser/preloading/preloading_prefs.h`: `NetworkPredictionOptions::kDefault = kDisabled` (inox `0006`; Chromium's is wifi-only). |
| WebRTC | `default_public_interface_only` | `disable_non_proxied_udp` | **needs a Haze patch** | `chrome/browser/ui/browser_ui_prefs.cc`: `kWebRTCIPHandlingPolicy` = `kWebRTCIPHandlingDisableNonProxiedUdp` (ungoogled `default-webrtc-ip-handling-policy`). Stricter than SPEC: without a proxy, WebRTC gets no UDP at all, which breaks or degrades calls. SPEC's policy hides local IPs and keeps calls working. |
| Global Privacy Control | On: `Sec-GPC: 1` and `navigator.globalPrivacyControl` | Off | **needs a Haze patch** | `kGlobalPrivacyControlApi` and `kGlobalPrivacyControlForce` are both `FEATURE_DISABLED_BY_DEFAULT` (generated from `runtime_enabled_features.json5`, status `experimental`). Without them `IsGlobalPrivacyControlFeatureAndSettingEnabled()` returns false, and neither the header (`content/renderer/render_frame_impl.cc`, `content/browser/loader/browser_initiated_resource_request.cc`) nor the JS property is set. |
| Tracking parameters | Stripped from top-level navigations | Not stripped | **needs a Haze patch** | Nothing in Chromium or ungoogled removes `utm_*`, `fbclid`, `gclid`, `msclkid`. |
| Content blocking | On (native adblock-rust) | None | **needs a Haze patch** | Not part of Chromium or ungoogled; planned in `haze/components/`. |
| Fingerprinting protection | Standard | Partial and off by default | **needs a Haze patch** | See the fingerprinting table below. |
| AI features | Disabled and hidden | Model downloads removed; Gemini and "Help me write" still on | **needs a Haze patch** | ungoogled's `disable-ai.patch` removes the on-device model components (Screen AI, speech models, page content annotations, the AI parts of the PDF viewer). It does not touch the entry points: `kGlic` (Gemini in the browser) is `FEATURE_ENABLED_BY_DEFAULT` on macOS and Windows (`chrome/common/chrome_features.cc`), `kEnableCompose` ("Help me write") is enabled everywhere (`components/compose/core/browser/compose_features.cc`). Without Google keys they cannot work, which is the opposite of hidden. `kHistoryEmbeddings` (AI history search) is disabled by default. |
| Privacy Sandbox ad APIs | Off | Removed or inert | **covered** by Chromium | By M158 Chromium itself has retired them: `document.browsingTopics()` always throws `NotSupportedError` (`browsing_topics_document_supplement.cc`), `joinAdInterestGroup()` resolves without doing anything (`navigator_auction.cc`), the Attribution Reporting browser code is gone (`content/browser/attribution_reporting/` holds only metadata), and `PrivacySandboxSettingsImpl` no longer has per-API gates. The M1 prefs that once gated them are still registered `false`. |
| Clear data on exit | Available, off by default | Available as a flag, off | **covered** by ungoogled | `chrome/browser/browser_features.cc`: `kClearDataOnExit` `FEATURE_DISABLED_BY_DEFAULT`, flag `clear-data-on-exit`; it deletes all browsing data in `chrome_browsing_data_lifetime_manager.cc`. Chromium's own "delete cookies and site data on close" setting also exists. A visible setting belongs to the settings UI step, not here. |
| Telemetry | None, not even opt-in | None | **covered** by ungoogled | UMA consent defaults to `GoogleUpdateSettings::GetCollectStatsConsent()`, which on Linux is true only if a client-ID backup file exists, so false on a fresh profile (`chrome/installer/util/google_update_settings_posix.cc`); the upload hosts are domain-substituted. The settings toggle sits inside `<if expr="_google_chrome">` in `personalization_options.html`, so a Chromium-branded build has no opt-in at all. |
| Crash upload | None | None | **covered** by ungoogled | Upload consent mirrors the metrics consent (`chrome/app/chrome_crash_reporter_client.cc`), and the upload URL is domain-substituted (`https://clients2.9oo91e.qjz9zk/cr/report` in `components/crash/core/app/crash_reporter_client.cc`). Crashpad still keeps a local database (see notes). |
| Field trials | None | None | **covered** by ungoogled | `components/variations/service/variations_service.cc`: `IsFetchingEnabled()` returns `false`; the seed URL is domain-substituted; `disable_fieldtrial_testing_config=true` in ungoogled's `flags.gn`. |

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

None yet. SPEC allows exactly three kinds, each to be listed here with what,
when, why and how to turn it off once it exists:

| Request | When | Why | How to turn it off |
|---|---|---|---|
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

**Result on Linux x64, 2026-11-27: zero requests.**

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
