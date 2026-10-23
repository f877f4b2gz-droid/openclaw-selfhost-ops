# Changelog

All notable changes to this repository are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/); versions follow [SemVer](https://semver.org/).

## [2.1.0] - 2026-10-23

### Added

- `scripts/inspect-daily.sh` — daily check covering disk, SMART, temperature, load, backup freshness, containers, systemd services, listening ports, processes and log health. Reports by error fingerprint instead of raw line count.
- `scripts/log-fingerprint.sh` — log normalization and redaction; collapses a class of errors into a stable ten-character hash. Tokens, JWTs and long blobs are redacted before anything is stored.
- `scripts/log-error-kb.sh` — error knowledge base. Each fingerprint is classified once (`known-harmless` / `known-manual` / `new`) with cause, impact, action and a 180-day re-review date.
- `scripts/model-guard.sh` — model spend guard. Verifies the primary model is still on the free tier, the endpoint is reachable, the paid balance is above the floor, no active session is pinned to a paid model, and 24-hour real spend is under the cap.
- `scripts/checkpoint.sh` — session checkpoint writing done / doing / next to disk before a model switch, compaction or reset.
- `docs/巡检.md` — new sections on fingerprint-based error governance and the two hard requirements for alert de-noising.
- `templates/ops.conf.example` — configuration keys for the scripts above.

### Changed

- README (Chinese and English) rewritten around symptoms and mechanisms rather than a component list, with measured before/after numbers.
- `cron/ops.cron.example` — added the daily check and hourly spend guard, with a note on why the guard must not run every few minutes.

### Performance

- `log-fingerprint.sh` rewritten as a single python3 process. Per-line `md5sum` spawning took 5.7 s per 1,000 lines; the current version takes 57 ms.

### Notes

- The daily check deliberately excludes the assistant's own logs. Scanning them turns every alert the assistant emits into the next day's "system fault".

## [2.0.0] - 2026-10-17

### Added

- `scripts/scratch-sweep.sh` — survival-window review and reclamation for the scratch area.
- `scripts/ref-count.sh` — static reference counting for reusable assets, with tiered verdicts.
- `scripts/exp-scan.sh` — offline clustering of repeated mistakes into a bounded feedback queue.
- `lib/ops_lib.sh` — shared library: config loading, dependency degradation, path validation.
- `templates/ops.conf.example` — single configuration file for all scripts.
- Specs: asset management, architecture and reuse, two-machine collaboration, and per-topic specs for docs, config, backup, skills, memory, logs and redaction.

## [1.0.0] - 2026-10-13

### Added

- Initial public release: backup, log rotation, cache trimming, trash cleanup and asset audit scripts.
