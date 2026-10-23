# OpenClaw Self-Host Ops

<p align="left">
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-green.svg" alt="License: MIT"></a>
  <img src="https://img.shields.io/badge/platform-Linux-blue.svg" alt="Platform: Linux">
  <img src="https://img.shields.io/badge/status-v2.1-blue.svg" alt="Status: v2.1">
  <img src="https://img.shields.io/badge/deps-system--only-brightgreen.svg" alt="Dependencies: system only">
</p>

[简体中文](README.md) ｜ **English**

> Governance for a **long-running self-hosted AI agent**: assets stop drifting, logs stop flooding, alerts stop being ignored, lessons stop being re-learned the hard way.

Plain bash scripts plus written specs, distilled from a multi-agent production setup that runs every day. Pure bash plus tools already on the system (python3, curl, ss). No third-party libraries, no daemon, every script usable on its own; hardware checks skip themselves when a tool is missing.

*Note: the `docs/` specs are written in Chinese; this file is the English overview.*

> **Built on one real OpenClaw setup.** Every number in this README (53 → 11 errors, 40% false positives) is measured, not estimated.
>
> It is not tied to that product: all six environment facts (data root / logs / sessions / media / config / alert command) are replaceable in the config file, so **in principle any agent runtime with a similar shape can be adapted**. See [`ADAPT.md`](ADAPT.md) for the agent-facing procedure.

**Not running OpenClaw?** Hand the repo to your AI and point it at [`ADAPT.md`](ADAPT.md) — an adaptation sheet written for agents rather than humans: probe the environment, fill in six variables, run.

---

## Do these symptoms look familiar

- The same setting is written in two places; you change one, forget the other, and two weeks later nobody knows which is correct.
- Thirty ad-hoc scripts pile up. Nobody dares delete them, and nobody knows which are still called.
- The daily check pushes forty "errors" a day. You ignore it within three days — and then miss a real failure inside the noise.
- The model silently leaves the free tier for a paid one. You find out from the monthly bill.
- Context compaction erases what you were doing, so the same mistake gets made twice.
- Hard-won debugging conclusions live in chat scrollback. A week later they are unsearchable, which means they were never recorded.

None of this is inexperience. It is the absence of **governance mechanisms**. That is what this repo is.

---

## Four layers, mapped to those symptoms

### 1. Assets stop drifting

- **Single source of truth** — every fact lives in exactly one place; everything else holds a pointer, never a copy of the body.
- **Dictionary-style index** — cross-category lookup goes through an index, not memory.
- **Survival-window sweep** — `scratch-sweep.sh` flags drafts that are "older than 30 days, referenced zero times, for two consecutive rounds" for the trash. It only prints a list; it never deletes on its own.
- **Reference counting** — `ref-count.sh` sorts loose scripts into shared / referenced / dependency / unelevated / exempt tiers, so "can we delete this" is answered by evidence instead of instinct.

### 2. Logs stop flooding (the headline of this release)

The fastest way to kill a daily check is to report every line containing `error`. Twenty messages from the same root cause, three days in a row, and the report is dead weight.

This repo reports **by fingerprint**, not by line count:

| Stage | Script | What it does |
|---|---|---|
| Normalize | `log-fingerprint.sh` | Strips timestamps, PIDs, paths, numbers and quoted payloads; redacts tokens, JWTs and long blobs. The same class of error always collapses to one ten-character hash. |
| Record the verdict | `log-error-kb.sh` | Each fingerprint is classified once: `known-harmless` / `known-manual` / `new`, with cause, impact, action and a 180-day re-review date. |
| Report three numbers | `inspect-daily.sh` | The daily output carries only 「new N / manual N / ignored N」 plus at most three fresh samples. |

Measured on one machine: 53 lines of noise became 「new 11 / ignored 42」 — single digits actually needing a human.

There is a hidden trap, documented in `docs/巡检.md`: **the check must not scan itself.** If the assistant's own log is treated as a system fault, every alert it emits becomes tomorrow's alert. That loop accounted for roughly forty percent of all open items in testing.

### 3. Alerts stop being ignored

- **Cooldown state must be writable.** Deduplication reads a "last sent" file. If its directory is missing or read-only, cooldown silently fails and alerts repeat at the check interval. Scripts verify this on startup and say so loudly.
- **Thresholds sized per day, not per snack.** Cost alerts calibrated to a single meal will fire daily and teach everyone to ignore them.
- **Spend guard** (`model-guard.sh`): is the primary model still on the free tier, is the free endpoint reachable, is the paid balance bottoming out, is any session quietly pinned to a paid model, did 24-hour real spend exceed the cap. It alerts only when one of these is true.

### 4. Lessons stop evaporating

- **Experience scan** — `exp-scan.sh` clusters repeated mistakes and reusable patterns offline into a bounded queue (max 50 entries, 30-day expiry, overflow archived).
- **Session checkpoint** — `checkpoint.sh` writes done / doing / next to disk before a model switch, compaction or reset. On resume you read the file instead of reconstructing from memory.

---

## 60-second start

```bash
git clone https://github.com/f877f4b2gz-droid/openclaw-selfhost-ops.git && cd openclaw-selfhost-ops

# 1. Configure (the only file you edit, and it never enters the repo)
sudo install -Dm644 templates/ops.conf.example /etc/openclaw-ops/ops.conf
sudo editor /etc/openclaw-ops/ops.conf

# 2. Dry-run everything first — read-only by default
./scripts/inspect-daily.sh --dry
./scripts/model-guard.sh --dry-run
./scripts/scratch-sweep.sh --dry-run
./scripts/ref-count.sh --list-zero
./scripts/exp-scan.sh --dry-run

# 3. Only then wire up cron
crontab -e   # see cron/ops.cron.example
```

Self-check without touching the real system: `bash tests/smoke.sh`.

No root: `OPS_CONF=/path/to/ops.conf ./scripts/...`.
Missing dependencies never abort a run — private helpers such as a notification channel degrade to local log output with a warning.

---

## Layout

```text
openclaw-selfhost-ops/
├── scripts/
│   ├── inspect-daily.sh     daily check (disk/SMART/temp/services/ports/processes/logs, fingerprint reporting)
│   ├── log-fingerprint.sh   log normalization and redaction
│   ├── log-error-kb.sh      error knowledge base (harmless/manual/new, 180-day review)
│   ├── model-guard.sh       model spend guard (free-tier first, alert de-noising)
│   ├── checkpoint.sh        session checkpoint (survives context loss)
│   ├── scratch-sweep.sh     draft survival-window sweep
│   ├── ref-count.sh         static reference counting
│   ├── exp-scan.sh          experience scan and feedback queue
│   ├── asset-audit.sh       asset audit
│   ├── core-backup.sh       core asset backup
│   ├── backup-sweep.sh      backup dedup and rotation
│   ├── bak-clean.sh         expired backup cleanup
│   ├── trash-clean.sh       trash cleanup
│   ├── log-rotate.sh        log rotation
│   └── cache-trace-trim.sh  cache and trace trimming
├── lib/ops_lib.sh           config loading, dependency degradation, path checks
├── templates/ops.conf.example
├── docs/                    specs and design notes (Chinese)
└── cron/ops.cron.example    sample schedule
```

---

## Docs

| Doc | Contents |
|---|---|
| `docs/巡检.md` | Check items, fingerprint-based error governance, alert de-noising rules |
| `docs/信息资产管理规范.md` | Asset classes, single location, naming, retention, change, lookup keys |
| `docs/架构设计与复用体系.md` | Three-layer structure and the "elevation threshold" for reuse |
| `docs/双机协作规范.md` | Orchestrator/executor boundaries and script ownership |
| `docs/规范-*.md` | Per-topic specs: docs, config, backup, skills, memory, logs, redaction |

---

## Fit and non-fit

**Fits**: self-hosted AI agents that run for months, multi-machine collaboration, and estates where assets and logs are already out of hand.
**Does not fit**: a toy chatbot you will not maintain. These mechanisms are shaped by "survive a year of operations"; short-term use will feel heavy.

---

## License

See [LICENSE](LICENSE). 简体中文: [README.md](README.md).
