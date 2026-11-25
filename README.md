# Haze

A desktop browser built on Chromium and ungoogled-chromium, with a focus on
privacy, security and performance. The UI is calm and sidebar-first on a
translucent window, and native on each platform.

macOS, Windows and Linux. Mobile is planned, not built.

## Status

Early. The repo is set up and the base is pinned; there is nothing to run yet.
Progress is tracked in [docs/PROGRESS.md](docs/PROGRESS.md).

| | |
|---|---|
| Chromium | 158.0.8127.88 |
| ungoogled-chromium | 158.0.8127.88-1 |

## How it works

Haze is a patch set on top of Chromium stable and ungoogled-chromium, not a
hard fork. Keeping rebases cheap is what keeps it secure.

- `overlay/` — Haze's own sources, synced into the Chromium tree at build time
- `patches/` — changes to existing Chromium files, applied in `patches/series`
- `tokens/haze.json` — design tokens, the source of truth for the UI
- `scripts/` — fetch, prepare, patch, build and packaging
- `build/` — gitignored: Chromium source, build output, logs, test profiles

## Documentation

- [docs/SPEC.md](docs/SPEC.md) — what Haze is and what it has to do
- [docs/PATCHES.md](docs/PATCHES.md) — every patch and why it exists
- [docs/PROGRESS.md](docs/PROGRESS.md) — what works so far

## Building

Not yet. The pipeline lands in later steps; `docs/PROGRESS.md` says what is
usable at any point.

## License

[MIT](LICENSE). Chromium and ungoogled-chromium keep their own licenses.
