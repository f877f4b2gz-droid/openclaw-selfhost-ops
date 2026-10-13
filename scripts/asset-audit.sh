#!/bin/bash
# ------------------------------------------------------------
# 信息资产体检（5+1 类 + 项目 + 自备份）
#
# 目的：把"资产有没有乱"变成可自动回答的问题 —— 漏登记、超限、缺状态头、超期未更新，
#       逐项查出来并告警。正常时保持静默（只写日志）。
#
# 用法：asset-audit.sh [--dry-run]
#   --dry-run  只打印报告，不写日志、不推送
#
# 配置（ops.conf）：
#   必填  WORKSPACE
#   选填  OPENCLAW_HOME BACKUP_ROOT LOG_DIR ALERT_CMD
#         SKILLS_DIR SCRIPTS_LEDGER_DOC PROJECTS_DIR SELF_BACKUP_ROOT CLOUD_DEST
#         DOCS_LEDGER（留空=不查文档索引一致性）
#   阈值  LOG_SELF_MAX LOG_SELF_KEEP_LINES CORE_BACKUP_KEEP WS_BACKUP_MAX_MB
#         OC_BAK_KEEP MEMORY_KEEP_DAYS PROJECT_STALE_DAYS ROTATE_LOGS
#
# 结果写 $WORKSPACE/logs/asset-audit.log；仅在有异常且以 root 运行时推送 ALERT_CMD。
# ------------------------------------------------------------
set -u

DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

CONF="${OPS_CONF:-/etc/openclaw-ops/ops.conf}"
# shellcheck disable=SC1090
[ -f "$CONF" ] && . "$CONF"

: "${WORKSPACE:?未配置 WORKSPACE（见 ops.conf.example）}"
: "${OPENCLAW_HOME:=$HOME/.openclaw}"
: "${BACKUP_ROOT:=$WORKSPACE/backup}"
: "${CORE_BACKUP_KEEP:=30}"
: "${WS_BACKUP_MAX_MB:=512}"
: "${OC_BAK_KEEP:=15}"
: "${MEMORY_KEEP_DAYS:=30}"
: "${PROJECT_STALE_DAYS:=14}"
: "${LOG_SELF_MAX:=$((1024 * 1024))}"
: "${LOG_SELF_KEEP_LINES:=1000}"
: "${ALERT_CMD:=}"
: "${SKILLS_DIR:=$WORKSPACE/skills}"
: "${SCRIPTS_DIR:=/usr/local/bin}"
: "${SCRIPTS_LEDGER_DOC:=}"
: "${PROJECTS_DIR:=$WORKSPACE/projects}"
: "${DOCS_LEDGER:=$WORKSPACE/docs/README.md}"
: "${SELF_BACKUP_ROOT:=}"
: "${CLOUD_DEST:=}"
: "${ROTATE_LOGS:=}"
: "${OCLOG_DIR:=/tmp/openclaw}"

DOCS_DIR="$WORKSPACE/docs"
MEMORY_DIR="$WORKSPACE/memory"
WS_BACKUP_DIR="$WORKSPACE/backup"
OC="$OPENCLAW_HOME/openclaw.json"
CT="$OPENCLAW_HOME/logs/cache-trace.jsonl"
LOG_DIR="${LOG_DIR:-$WORKSPACE/logs}"
LOG_FILE="$LOG_DIR/asset-audit.log"
TS=$(date '+%F %T')
ALERTS=()

mkdir -p "$LOG_DIR"

if [ "$DRY" -eq 1 ]; then
  echo "[dry-run] 配置=$CONF"
  echo "[dry-run] WORKSPACE=$WORKSPACE OPENCLAW_HOME=$OPENCLAW_HOME BACKUP_ROOT=$BACKUP_ROOT"
fi

# 自限：巡检日志本身超上限先截断，否则它会成为新的磁盘问题
if [ "$DRY" -eq 0 ] && [ -f "$LOG_FILE" ] && [ "$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)" -gt "$LOG_SELF_MAX" ]; then
  tail -n "$LOG_SELF_KEEP_LINES" "$LOG_FILE" > "$LOG_FILE.tmp" && cat "$LOG_FILE.tmp" > "$LOG_FILE" && rm -f "$LOG_FILE.tmp"
fi

run_audit() {

echo "==================== $TS ===================="

# ---------- 1 文档 ----------
echo "[1] 文档"
dtot=0; dhead=0; dunreg=0
if [ -d "$DOCS_DIR" ]; then
  for f in "$DOCS_DIR"/*.md; do
    [ -f "$f" ] || continue
    b=$(basename "$f")
    [ "$b" = "README.md" ] && continue
    dtot=$((dtot + 1))
    case "$(head -1 "$f")" in \#*) : ;; *) echo "  ⚠ 无标题: $b"; dhead=$((dhead + 1)) ;; esac
    if ! grep -qE '更新日期|最后更新|^日期|状态：' "$f"; then echo "  ⚠ 无状态头: $b"; dhead=$((dhead + 1)); fi
    if [ -n "$DOCS_LEDGER" ] && [ -f "$DOCS_LEDGER" ] && ! grep -q "$b" "$DOCS_LEDGER"; then
      echo "  ⚠ 未登记索引: $b"; dunreg=$((dunreg + 1))
    fi
  done
fi
echo "  文档=$dtot  archive=$([ -d "$DOCS_DIR/archive" ] && echo 有 || echo 无)  未登记=$dunreg  问题=$dhead"
[ "$dhead" -gt 0 ] && ALERTS+=("文档缺标题/状态头：${dhead} 项")
[ "$dunreg" -gt 0 ] && ALERTS+=("docs 未登记到索引：${dunreg} 篇")

# ---------- 1b 自建脚本登记（检索键：一个脚本一行，才能被搜到）----------
echo "[1b] 自建脚本台账"
if [ -n "$SCRIPTS_LEDGER_DOC" ] && [ -f "$SCRIPTS_LEDGER_DOC" ]; then
  shot=0; sunreg=0; smiss=()
  for f in "$SCRIPTS_DIR"/*.sh "$SCRIPTS_DIR"/*.py; do
    [ -f "$f" ] || continue
    b=$(basename "$f")
    case "$b" in *".bak."*|"*.bak-"*) continue ;; esac
    shot=$((shot + 1))
    if ! grep -q -- "$b" "$SCRIPTS_LEDGER_DOC" 2>/dev/null; then smiss+=("$b"); sunreg=$((sunreg + 1)); fi
  done
  echo "  自建脚本=$shot  台账未登记=$sunreg"
  if [ "$sunreg" -gt 0 ]; then
    for x in "${smiss[@]}"; do echo "  ⚠ 未登记台账: $x"; done
    ALERTS+=("自建脚本未登记台账：${sunreg}/${shot}（如 ${smiss[0]}）")
  fi
else
  echo "  （未配置 SCRIPTS_LEDGER_DOC，跳过）"
fi

# ---------- 2 备份 ----------
echo "[2] 备份"
core=$(ls "$BACKUP_ROOT"/core/core_*.tar.gz 2>/dev/null | wc -l | tr -d ' ')
echo "  core 快照=$core 份（上限 $CORE_BACKUP_KEEP）"
[ "${core:-0}" -gt "$CORE_BACKUP_KEEP" ] && ALERTS+=("core 备份超 $CORE_BACKUP_KEEP 份：$core")
wsm=$(du -sm "$WS_BACKUP_DIR" 2>/dev/null | cut -f1); wsm=${wsm:-0}
echo "  手工备份=${wsm}MB（软上限 ${WS_BACKUP_MAX_MB}MB）"
[ "$wsm" -gt "$WS_BACKUP_MAX_MB" ] && ALERTS+=("手工备份超 ${WS_BACKUP_MAX_MB}MB：${wsm}MB")
if [ -f "$WS_BACKUP_DIR/台账.md" ]; then
  age=$(( ($(date +%s) - $(stat -c %Y "$WS_BACKUP_DIR/台账.md")) / 86400 ))
  echo "  台账.md 最后修改=${age} 天前"
else
  echo "  ⚠ 缺 台账.md"; ALERTS+=("缺 backup/台账.md（变更无记录）")
fi
[ -d "$WORKSPACE/backups" ] && { echo "  ⚠ 出现规范外目录 backups/"; ALERTS+=("疑似新建规范外 backups/ 目录"); }

# ---------- 3 配置 ----------
echo "[3] 配置"
nb=$(ls "$(dirname "$OC")"/openclaw.json.bak* 2>/dev/null | wc -l | tr -d ' ')
echo "  openclaw.json 备份=$nb 份（上限 $OC_BAK_KEEP）  .last-good=$([ -f "$OC.last-good" ] && echo 有 || echo 无)"
[ "${nb:-0}" -gt "$OC_BAK_KEEP" ] && ALERTS+=("openclaw.json 备份过多：$nb 份")
# 清理类任务若无日志重定向，出问题就无从追溯 → 视为异常
for spec in $ROTATE_LOGS; do
  f="${spec%%:*}"; b=$(basename "$f" .log)
  if [ -f "/etc/cron.d/$b" ] && ! grep -q "$(basename "$f")" "/etc/cron.d/$b"; then
    echo "  ⚠ $b 无日志重定向"; ALERTS+=("$b 缺日志重定向（失败无从追溯）")
  fi
done
[ -f "${LOG_DIR}/log-rotate.log" ] || ALERTS+=("缺 log-rotate 日志（轮转无记录）")

# ---------- 4 技能（只体检自建；git/市场装的跳过，它们有自己的版本来源）----------
echo "[4] 技能"
stot=0; snov=0; snoc=0; third=0
if [ -d "$SKILLS_DIR" ]; then
  for d in "$SKILLS_DIR"/*/; do
    [ -d "$d" ] || continue
    n=$(basename "$d")
    case "$n" in _disabled) continue ;; esac
    [ -d "$d/.git" ] && { third=$((third + 1)); continue; }
    stot=$((stot + 1))
    [ -f "$d/VERSION" ] || snov=$((snov + 1))
    [ -f "$d/CHANGELOG.md" ] || snoc=$((snoc + 1))
  done
fi
echo "  自建技能=$stot  第三方(git/市场)=$third  自建缺VERSION=$snov  自建缺CHANGELOG=$snoc"
[ "$snov" -gt 0 ] && ALERTS+=("自建技能缺 VERSION：${snov}/${stot}")
[ "$snoc" -gt 0 ] && ALERTS+=("自建技能缺 CHANGELOG：${snoc}/${stot}")

# ---------- 5 记忆 ----------
echo "[5] 记忆"
mtot=0; mold=0
if [ -d "$MEMORY_DIR" ]; then
  mtot=$(find "$MEMORY_DIR" -maxdepth 1 -type f -name '20*.md' 2>/dev/null | wc -l | tr -d ' ')
  mold=$(find "$MEMORY_DIR" -maxdepth 1 -type f -name '20*.md' -mtime +"$MEMORY_KEEP_DAYS" 2>/dev/null | wc -l | tr -d ' ')
fi
echo "  日记=$mtot  超${MEMORY_KEEP_DAYS}天未归档=$mold  archive=$([ -d "$MEMORY_DIR/archive" ] && echo 有 || echo 无)"
[ "${mold:-0}" -gt 0 ] && ALERTS+=("memory 超 ${MEMORY_KEEP_DAYS} 天未归档：$mold 篇")

# ---------- 6 日志 ----------
echo "[6] 日志"
for f in "$CT" "${OCLOG_DIR}/openclaw-$(date +%F).log" "${LOG_DIR}/log-rotate.log"; do
  [ -f "$f" ] && echo "  $f = $(du -h "$f" 2>/dev/null | cut -f1)"
done
ctsz=$(stat -c%s "$CT" 2>/dev/null || echo 0)
[ "$ctsz" -gt 1073741824 ] && ALERTS+=("cache-trace 超 1GB：$((ctsz / 1048576))MB（瘦身未生效？）")

# ---------- 7 项目 ----------
echo "[7] 项目"
if [ -n "$PROJECTS_DIR" ] && [ -d "$PROJECTS_DIR" ]; then
  ptot=0; pmiss=0; pstale=0; pproto=0; punreg=0; pbad=0
  for d in "$PROJECTS_DIR"/*/; do
    [ -d "$d" ] || continue
    n=$(basename "$d"); ptot=$((ptot + 1))
    for need in README.md STATUS.md decisions.md CHANGELOG.md; do
      [ -f "$d$need" ] || { echo "  ⚠ $n 缺 $need"; pmiss=$((pmiss + 1)); }
    done
    [ -f "$d/PROTOCOL.md" ] && pproto=$((pproto + 1))
    [ -f "$d/design/PROTOCOL.md" ] && { echo "  ⚠ $n 协议错位（应在项目根）"; pbad=$((pbad + 1)); }
    if [ -f "$d/STATUS.md" ]; then
      age=$(( ($(date +%s) - $(stat -c %Y "$d/STATUS.md")) / 86400 ))
      [ "$age" -gt "$PROJECT_STALE_DAYS" ] && { echo "  ⚠ $n STATUS ${age} 天未更新"; pstale=$((pstale + 1)); }
    fi
    if [ -f "$PROJECTS_DIR/README.md" ] && ! grep -q "$n" "$PROJECTS_DIR/README.md"; then
      echo "  ⚠ $n 未登记 projects/README.md"; punreg=$((punreg + 1))
    fi
  done
  echo "  项目=$ptot  有协议=$pproto  缺固定文件=$pmiss  STATUS超期=$pstale  未登记=$punreg"
  [ "$pmiss" -gt 0 ] && ALERTS+=("项目区缺固定文件：${pmiss} 项")
  [ "$pstale" -gt 0 ] && ALERTS+=("项目 STATUS 超期未更新：${pstale} 个")
  [ "$punreg" -gt 0 ] && ALERTS+=("项目未登记索引：${punreg} 个")
  [ "$pbad" -gt 0 ] && ALERTS+=("项目协议错位（应在根）：${pbad} 个")
else
  echo "  （未配置或无 projects/ 目录）"
fi

# ---------- 8 自备份（可选：第二存储 + 云）----------
echo "[8] 自备份"
if [ -z "$SELF_BACKUP_ROOT" ]; then
  echo "  （未配置 SELF_BACKUP_ROOT，跳过）"
else
  if mountpoint -q "$SELF_BACKUP_ROOT" 2>/dev/null; then
    echo "  第二存储已挂载  daily=$(ls -1d "$SELF_BACKUP_ROOT"/daily/*/ 2>/dev/null | wc -l | tr -d ' ') 份  weekly=$(ls -1 "$SELF_BACKUP_ROOT"/weekly/*.gpg 2>/dev/null | wc -l | tr -d ' ') 份"
    latest=$(ls -1dt "$SELF_BACKUP_ROOT"/daily/*/ 2>/dev/null | head -1)
    if [ -n "$latest" ]; then
      age=$(( ($(date +%s) - $(stat -c %Y "$latest")) / 86400 ))
      echo "  最近 daily=$(basename "$latest")（${age} 天前）"
      [ "$age" -gt 2 ] && ALERTS+=("自备份 daily 超 2 天未更新")
    else
      ALERTS+=("自备份无 daily 快照")
    fi
  else
    echo "  ⚠ 第二存储未挂载：$SELF_BACKUP_ROOT"; ALERTS+=("第二存储未挂载（自备份中断）")
  fi
  if [ -n "$CLOUD_DEST" ]; then
    [ -d "$CLOUD_DEST" ] && echo "  云 落点=$(ls -1 "$CLOUD_DEST"/*.gpg 2>/dev/null | wc -l | tr -d ' ') 份" \
      || ALERTS+=("云落点不存在/未挂载")
  fi
fi

echo "  异常项=${#ALERTS[@]}"
}

if [ "$DRY" -eq 1 ]; then
  run_audit
  echo "[dry-run] 结束：未写日志、未推送。异常项=${#ALERTS[@]}"
  exit 0
fi

run_audit >> "$LOG_FILE" 2>&1

# ---------- 告警：只在 root 且有异常时推送（正常保持静默）----------
if [ "${#ALERTS[@]}" -gt 0 ] && [ "$(id -u)" -eq 0 ] && [ -n "$ALERT_CMD" ]; then
  MSG="【资产体检 $TS】共 ${#ALERTS[@]} 项异常"
  for a in "${ALERTS[@]}"; do
    MSG="$MSG
- $a"
  done
  $ALERT_CMD "$MSG"
fi
exit 0
