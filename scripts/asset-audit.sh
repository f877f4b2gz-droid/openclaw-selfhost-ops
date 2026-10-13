#!/bin/bash
# 资产体检（5+1 类）—— 见 docs/规范-*.md 与 docs/巡检.md
# 结果写 $LOG_FILE；发现异常且以 root 运行时，经 $ALERT_CMD 推送。
# cron：每周日 05:00（见 cron/ 示例）。
#
# 需配置（环境变量，或写进 ops.conf；详见 ops.conf.example）——无硬编码真实路径/凭据：
#   必填  WORKSPACE                 工作区根（docs/ memory/ backup/ skills/ 所在）
#   选填  OPENCLAW_HOME             默认 $HOME/.openclaw
#   选填  BACKUP_ROOT               默认 $WORKSPACE/backup
#   选填  ALERT_CMD                 告警命令（留空=只写日志）
#   阈值  LOG_SELF_MAX LOG_SELF_KEEP_LINES CORE_BACKUP_KEEP WS_BACKUP_MAX_MB
#         OC_BAK_KEEP MEMORY_KEEP_DAYS ROTATE_LOGS
# 读配置：$OPS_CONF（默认 /etc/openclaw-ops/ops.conf）。
set -u

CONF="${OPS_CONF:-/etc/openclaw-ops/ops.conf}"
[ -f "$CONF" ] && . "$CONF"
: "${WORKSPACE:?未配置 WORKSPACE（见 ops.conf.example）}"
: "${OPENCLAW_HOME:=$HOME/.openclaw}"
: "${BACKUP_ROOT:=$WORKSPACE/backup}"
: "${ALERT_CMD:=}"
: "${LOG_SELF_MAX:=$((1024 * 1024))}"
: "${LOG_SELF_KEEP_LINES:=1000}"
: "${CORE_BACKUP_KEEP:=30}"
: "${WS_BACKUP_MAX_MB:=512}"
: "${OC_BAK_KEEP:=15}"
: "${MEMORY_KEEP_DAYS:=30}"
: "${ROTATE_LOGS:=}"

DOCS_DIR="$WORKSPACE/docs"
SKILLS_DIR="$WORKSPACE/skills"
MEMORY_DIR="$WORKSPACE/memory"
WS_BACKUP_DIR="$WORKSPACE/backup"
OC="$OPENCLAW_HOME/openclaw.json"
CT="$OPENCLAW_HOME/logs/cache-trace.jsonl"
LOG_FILE="$WORKSPACE/logs/asset-audit.log"
TS=$(date '+%F %T')
ALERTS=()

mkdir -p "$(dirname "$LOG_FILE")"

# 自限：巡检日志超上限先截断
if [ -f "$LOG_FILE" ] && [ "$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)" -gt "$LOG_SELF_MAX" ]; then
  tail -n "$LOG_SELF_KEEP_LINES" "$LOG_FILE" > "$LOG_FILE.tmp" && cat "$LOG_FILE.tmp" > "$LOG_FILE" && rm -f "$LOG_FILE.tmp"
fi

{
echo "==================== $TS ===================="

# ---------- 1 文档 ----------
echo "[1] 文档 $DOCS_DIR"
dmiss=0; dtot=0; dunreg=0
for f in "$DOCS_DIR"/*.md; do
  [ -f "$f" ] || continue
  b=$(basename "$f"); [ "$b" = "README.md" ] && continue
  dtot=$((dtot + 1))
  case "$(head -1 "$f")" in \#*) : ;; *) echo "  ⚠ 无标题: $b"; dmiss=$((dmiss + 1));; esac
  if ! grep -qE '更新日期|最后更新|^日期|状态：' "$f"; then echo "  ⚠ 无状态头: $b"; dmiss=$((dmiss + 1)); fi
  if ! grep -q "$b" "$DOCS_DIR/README.md" 2>/dev/null; then echo "  ⚠ 未登记索引: $b"; dunreg=$((dunreg + 1)); fi
done
echo "  文档=$dtot  archive=$([ -d "$DOCS_DIR/archive" ] && echo 有 || echo 无)  未登记=$dunreg  问题=$dmiss"
[ "$dmiss" -gt 0 ] && ALERTS+=("文档缺标题/状态头：${dmiss} 项")
[ "$dunreg" -gt 0 ] && ALERTS+=("docs 未登记到 README 索引：${dunreg} 篇")

# ---------- 2 备份 ----------
echo "[2] 备份"
core=$(ls "$BACKUP_ROOT"/core/core_*.tar.gz 2>/dev/null | wc -l)
echo "  $BACKUP_ROOT/core=$core 份（上限 $CORE_BACKUP_KEEP）"
[ "$core" -gt "$CORE_BACKUP_KEEP" ] && ALERTS+=("core 备份超 ${CORE_BACKUP_KEEP} 份：$core")
wsm=$(du -sm "$WS_BACKUP_DIR" 2>/dev/null | cut -f1); wsm=${wsm:-0}
echo "  $WS_BACKUP_DIR=${wsm}MB（软上限 ${WS_BACKUP_MAX_MB}）"
[ "$wsm" -gt "$WS_BACKUP_MAX_MB" ] && ALERTS+=("手工备份超 ${WS_BACKUP_MAX_MB}MB：${wsm}MB")
if [ -f "$WS_BACKUP_DIR/台账.md" ]; then
  age=$(( ($(date +%s) - $(stat -c %Y "$WS_BACKUP_DIR/台账.md")) / 86400 ))
  echo "  台账.md 最后修改=${age} 天前"
else
  echo "  ⚠ 缺 $WS_BACKUP_DIR/台账.md"; ALERTS+=("缺 backup/台账.md")
fi

# ---------- 3 配置 ----------
echo "[3] 配置"
nb=$(ls "$(dirname "$OC")"/openclaw.json.bak* 2>/dev/null | wc -l)
echo "  openclaw.json 备份=$nb 份  .last-good=$([ -f "$OC.last-good" ] && echo 有 || echo 无)"
[ "$nb" -gt "$OC_BAK_KEEP" ] && ALERTS+=("openclaw.json 备份过多：$nb 份")

# ---------- 4 技能（只体检自建；git/市场装的跳过，它们有自己的版本来源）----------
echo "[4] 技能"
LOCK="$WORKSPACE/.clawhub/lock.json"
stot=0; snov=0; snoc=0; third=0
for d in "$SKILLS_DIR"/*/; do
  [ -d "$d" ] || continue
  n=$(basename "$d")
  case "$n" in _disabled) continue;; esac
  if [ -d "$d/.git" ]; then third=$((third + 1)); continue; fi
  if [ -f "$LOCK" ] && grep -q "\"$n\"" "$LOCK"; then third=$((third + 1)); continue; fi
  stot=$((stot + 1))
  [ -f "$d/VERSION" ] || snov=$((snov + 1))
  [ -f "$d/CHANGELOG.md" ] || snoc=$((snoc + 1))
done
echo "  自建技能=$stot  第三方(git/市场)=$third  自建缺VERSION=$snov  自建缺CHANGELOG=$snoc"
[ "$snov" -gt 0 ] && ALERTS+=("自建技能缺 VERSION：${snov}/${stot}")

# ---------- 5 记忆 ----------
echo "[5] 记忆"
mold=$(find "$MEMORY_DIR" -maxdepth 1 -type f -name '20*.md' -mtime +"$MEMORY_KEEP_DAYS" 2>/dev/null | wc -l)
mtot=$(find "$MEMORY_DIR" -maxdepth 1 -type f -name '20*.md' 2>/dev/null | wc -l)
echo "  memory 日记=$mtot  超${MEMORY_KEEP_DAYS}天=$mold  archive=$([ -d "$MEMORY_DIR/archive" ] && echo 有 || echo 无)"
[ "$mold" -gt 0 ] && ALERTS+=("memory 超 ${MEMORY_KEEP_DAYS} 天未归档：$mold 篇")

# ---------- 6 日志 ----------
echo "[6] 日志"
[ -f "$CT" ] && echo "  $CT = $(du -h "$CT" 2>/dev/null | cut -f1)"
for spec in $ROTATE_LOGS; do
  f="${spec%%:*}"; [ -f "$f" ] && echo "  $f = $(du -h "$f" 2>/dev/null | cut -f1)"
done
ctsz=$(stat -c%s "$CT" 2>/dev/null || echo 0)
[ "$ctsz" -gt 1073741824 ] && ALERTS+=("cache-trace 超 1GB：$((ctsz / 1048576))MB（轮转未生效？）")

echo "  异常项=${#ALERTS[@]}"
} >> "$LOG_FILE" 2>&1

# ---------- 告警（仅 root 且配置了 ALERT_CMD 时推送）----------
if [ "${#ALERTS[@]}" -gt 0 ] && [ "$(id -u)" -eq 0 ] && [ -n "$ALERT_CMD" ]; then
  MSG="【资产体检 $TS】共 ${#ALERTS[@]} 项异常"
  for a in "${ALERTS[@]}"; do MSG="$MSG
- $a"; done
  $ALERT_CMD "$MSG"
fi
exit 0
