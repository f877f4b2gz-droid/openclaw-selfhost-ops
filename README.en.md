# OpenClaw Self-Host Ops Governance

<p align="left">
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-green.svg" alt="License: MIT"></a>
  <img src="https://img.shields.io/badge/platform-Linux-blue.svg" alt="Platform: Linux">
  <img src="https://img.shields.io/badge/status-draft%20v0-lightgrey.svg" alt="Status: draft v0">
</p>

[简体中文](README.md) ｜ **English**

> Asset governance for a **long-running self-hosted AI assistant** (OpenClaw and the like): keep docs, config, backups, skills, memory, and logs **filed, recorded, and self-checking** — low-maintenance, rollback-ready, without bloating your disk or your context window.

*Note: the `docs/` specs are currently written in Chinese; this file is the English overview.*

## Contents

- [Why "integration"](#why-integration-not-yet-another-point-tool)
- [1. The problem (before)](#1-the-problem-before)
- [2. What it does (after)](#2-what-it-does-after)
- [3. Results (measurable)](#3-results-measurable)
- [4. Priority tiers](#4-priority-tiers)
- [5. Layout](#5-layout)
- [6. Document index](#6-document-index)
- [7. Quick start](#7-quick-start)
- [8. Who it's for](#8-who-its-for)
- [9. FAQ](#9-faq)
- [10. License](#10-license)

---

## Why "integration", not yet another point tool

The hard part of running a resident AI assistant long-term isn't features — it's **operational order**. Point solutions are everywhere: backups, memory, skills, cost — each has off-the-shelf projects, **but nobody hangs them together into one system**.

This project is that integration: **unified governance for 5+1 asset classes** (full lifecycle + weekly auto-reconciliation + a rollback-ready ledger). It **doesn't compete with point tools on "my backup is better than yours"** — it does one thing: make scattered practices **filed, connected, and self-checking**.

## 1. The problem (before)

The "chronic diseases" that almost always show up after long uptime:

| Pain point | Consequence |
|---|---|
| Docs scattered, no index, no status marker; new drafts overwrite old ones | You can't tell which is authoritative — effectively no docs |
| Config changed with no backup, no record | No way to roll back; start over |
| Logs grow without bound (e.g. a 400MB+ single `cache-trace` file; uncapped service logs) | Silently fills the disk |
| Backups mixed together, random names, no retention policy | What you need is missing; what should go piles up |
| No versions for skills; `MEMORY` grows ever thicker | Changes untraceable; a bloated context burns tokens every turn |
| Session residue (`*.trajectory.jsonl` / `*.bak-*` / `*.checkpoint.*`) accumulates | Wastes disk, slows things down |

## 2. What it does (after)

Assets are split into **5+1 classes**, plus two add-ons: "trash" and "self-check". Each class defines: **single location · naming rule · retention/archival policy · change log**.

1. **Docs** → `docs/` as the single source of truth: a unified status header (title / updated / status), an index, old versions moved to `archive/`.
2. **Backups** → script output and manual backups **filed separately**; naming `name.bak.YYYYMMDD-HHMMSS`; a hard retention cap; operations recorded in a `ledger.md`.
3. **Config** → `.bak` before every change; a **daily full core snapshot** (keep 30); a persistent `.last-good`.
4. **Skills** → enforce `VERSION` + `CHANGELOG.md`; register in an inventory; disable by moving to `_disabled/` (never delete).
5. **Memory** → `MEMORY.md` holds only **pointers / red lines**, not the body; daily notes archived after 30 days.
6. **Logs** → `cache-trace` over 300MB is rewritten in place, keeping only the latest **20%**; service logs truncated over 50MB; rotated files cleaned after 7/14/30 days.

- **Add-on · Trash** → `trash/` keeps 30 days, **prefer trash over rm**.
- **Add-on · Self-check** → weekly `asset-audit`: checks all 5+1 classes, **alerts on anything unregistered or over-limit** (pushed to IM).

## 3. Results (measurable)

- **`cache-trace.jsonl`**: uncapped → **steady 170–300MB** (auto-shrinks past the threshold).
- **Core snapshots**: none → **1/day, 30 kept**.
- **Config rollback**: from "none" to "**one `cp` command**".
- **Docs**: from scattered → indexed + **weekly auto-reconciliation** (instant alert on unregistered files).
- **Context / tokens**: only **small fixed files** are injected; high-churn files (logs, state) live outside the context (rules in `docs/规范-上下文与缓存.md`).
- **Disk**: logs, session residue, and old backups all have definite caps and cleanup cycles.

> The concrete numbers here and in each spec are **example defaults (from real use)** — values tuned by long-running practice, not theory; adjust per each doc's "4. How to adjust".

## 4. Priority tiers

Every spec carries a tier in its header:

- **Required** — skipping it will cause trouble (backup, config, redaction, logs).
- **Recommended** — skipping it accumulates debt that rots over time (docs, skills, inspection, context & cache).
- **Optional** — case by case (e.g. memory archival details).

> Note: anything labeled "optional" is done by nobody, and the rule dies. So only things that truly depend on personal preference are demoted.

## 5. Layout

```text
openclaw-selfhost-ops/
├── README.md               Chinese README
├── README.en.md            English README (this file)
├── LICENSE
├── docs/                   9 documents (8 specs + inspection guide)
├── scripts/
│   ├── ops.conf.example    Path & threshold template (install to /etc/openclaw-ops/ops.conf)
│   ├── asset-audit.sh      Asset health check (5+1 classes; alert on gaps/over-limit)
│   ├── log-rotate.sh       Log rotation / session-residue cleanup / backup slimming
│   └── core-backup.sh      Full core snapshot (retention configurable)
└── cron/
    └── ops.cron.example    Example crontab
```

## 6. Document index

| Document | Scope | Tier | Purpose |
|---|---|---|---|
| docs/规范-文档.md | 5+1 assets | Recommended | Single source of truth, status header, index, archive |
| docs/规范-配置.md | 5+1 assets | Required | Back up before change, snapshots, `.last-good`, syntax check |
| docs/规范-备份.md | 5+1 assets | Required | Filing, naming, retention, ledger, restore |
| docs/规范-技能.md | 5+1 assets | Recommended | VERSION + CHANGELOG + inventory, disable via `_disabled/` |
| docs/规范-记忆.md | 5+1 assets | Optional | MEMORY as pointers only, archive stale notes |
| docs/规范-日志.md | 5+1 assets | Required | Log caps, rotation, expiry cleanup |
| docs/规范-脱敏.md | Cross-cutting | Required | Pre-publish redaction: placeholders, ignore rules, secret scan |
| docs/巡检.md | Cross-cutting | Recommended | Periodic auto health check, alert only on anomalies |
| docs/规范-上下文与缓存.md | Cross-cutting | Recommended | What not to put in context, when cache breaks, change discipline |

> Document filenames are Chinese on purpose (they're the spec titles); the content is in Chinese as noted above.

## 7. Quick start

1. **Prepare config**: `sudo install -Dm644 scripts/ops.conf.example /etc/openclaw-ops/ops.conf`, then edit paths and thresholds for your host (scripts read here by default). **Without root**, place it anywhere and point `OPS_CONF=/path/ops.conf` at it.
2. **Run a check**: `chmod +x scripts/*.sh` and run `./scripts/asset-audit.sh`; see the output (report written to `$WORKSPACE/logs/asset-audit.log`).
3. **Schedule it**: following `cron/ops.cron.example`, add the three jobs to `<crontab>` (for OpenClaw users, usually `/etc/cron.d/`).
4. **Set up alerts**: point `ALERT_CMD` at your notification script (IM / email / webhook — anything). Leave it empty to log only.
5. **(Optional) Verify alerts work**: once `ALERT_CMD` is set, run `asset-audit.sh` and confirm you get a test push; without it the tool still works — anomalies just go to the log.

> One extra step for contributors: before submitting, self-check with `docs/规范-脱敏.md` — never commit real paths / domains / credentials.

## 8. Who it's for

- Individuals self-hosting a **resident assistant** like OpenClaw / Claude-Code;
- NAS / small-host tinkerers (limited resources, more afraid of runaway logs);
- **People already using scattered backup / memory tools that don't talk to each other** — if you want "one system instead", this is it;
- Anyone who wants "rollback-ready, traceable, low-maintenance".

## 9. FAQ

**Q: I don't have root. Can I still run it?**
Yes. Scripts read `/etc/openclaw-ops/ops.conf` by default; without root, use `OPS_CONF=/your/path/ops.conf`. Alerts can be skipped too (`ALERT_CMD` empty).

**Q: I only want backups / only log rotation. Can I use just that?**
Yes — the three scripts are independent; pick what you need. Still, the value here is **integration + self-check**; see the top of this README for the point-tool comparison.

**Q: Will it delete my files by mistake?**
Destructive scripts support `--dry-run`: run it first to see "what would move", and only drop the flag once you're sure. Deletions always go to `trash/` first, and files are `.bak`'d before any change.

**Q: My directories / services differ from the examples.**
Everything is parameterized. Paths, thresholds, and the log list live in `ops.conf`; docs use placeholders (e.g. `<workspace>`).

**Q: How does it relate to those point tools (backup / memory / cost)?**
Not a replacement — they can coexist. This project doesn't chase "stronger at one thing"; it manages every asset class as **filed, reconciled, rollback-ready**.

**Q: Is it resource-hungry?**
Lightweight. The audit only `stat`s and counts; rotation and backup run on cron, taking seconds to tens of seconds.

**Q: Does it work on Windows / macOS?**
The scripts target Linux (NAS / small hosts), relying on `bash`, `cron`, `find`, `tar`. The ideas are portable — test any port yourself.

**Q: What if I break something?**
Every change is `.bak`'d first, and the ledger records the **restore command**; for config it's a single `cp`.

## 10. License

MIT, see [LICENSE](LICENSE).

---

**Status**: draft v0 (content finalized, pending release). Done: specs finalized (incl. context & cache), scripts parameterized + verified on a real host, GitHub duplication check, security audit, FAQ. TODO: release.
