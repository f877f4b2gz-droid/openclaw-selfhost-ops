#!/bin/bash
# core 全量快照：配置 / 脚本 / 定时表 / 工作区 → $BACKUP_ROOT/core/core_<时间>.tar.gz
# 超过保留份数删最旧。cron：每日 02:30（见 cron/ 示例）。
#
# 用法：core-backup.sh [--dry-run]    --dry-run 只报告"会动哪些文件"，不实际改动
#
# 需配置（环境变量，或写进 ops.conf；详见 ops.conf.example）——无硬编码真实路径/凭据：
#   必填  WORKSPACE               工作区根（纳入快照）
#   选填  OPENCLAW_HOME           默认 $HOME/.openclaw
#   选填  BACKUP_ROOT             快照输出根（默认 $WORKSPACE/backup）
#   选填  ALERT_CMD               失败告警命令（留空=不推送）
#   阈值  CORE_BACKUP_KEEP        保留份数（默认 30）
# 读配置：$OPS_CONF（默认 /etc/openclaw-ops/ops.conf）。
set -u

DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

CONF="${OPS_CONF:-/etc/openclaw-ops/ops.conf}"
[ -f "$CONF" ] && . "$CONF"
: "${WORKSPACE:?未配置 WORKSPACE（见 ops.conf.example）}"
: "${OPENCLAW_HOME:=$HOME/.openclaw}"
: "${BACKUP_ROOT:=$WORKSPACE/backup}"
: "${CORE_BACKUP_KEEP:=30}"
: "${ALERT_CMD:=}"

DST="$BACKUP_ROOT/core"
TS=$(date +%Y%m%d_%H%M%S)

# 快照内容与排除项（按需修改）
SRC=(/usr/local/bin /etc/cron.d "$WORKSPACE" "$OPENCLAW_HOME")
EXC=(
  "$OPENCLAW_HOME/logs"
  "$OPENCLAW_HOME/media"
  "$OPENCLAW_HOME/npm"
  "$OPENCLAW_HOME/agents/main/sessions"
)

if [ "$DRY" -eq 1 ]; then
  echo "[dry-run] 配置=$CONF"
  echo "  [dry-run] 将创建 $DST/core_$TS.tar.gz"
  echo "  [dry-run]   内容: ${SRC[*]}"
  echo "  [dry-run]   排除: ${EXC[*]}"
  n=$(ls "$DST"/core_*.tar.gz 2>/dev/null | wc -l | tr -d ' ')
  will=$((n + 1 - CORE_BACKUP_KEEP)); [ "$will" -lt 0 ] && will=0
  echo "  [dry-run]   现有 $n 份，保留 $CORE_BACKUP_KEEP 份；本次将删最旧 ${will} 份"
  echo "[dry-run] 结束：无任何改动。"
  exit 0
fi

mkdir -p "$DST"
EXC_ARGS=()
for e in "${EXC[@]}"; do EXC_ARGS+=("--exclude=$e"); done

tar czf "$DST/core_$TS.tar.gz" "${EXC_ARGS[@]}" "${SRC[@]}" 2>/dev/null
RET=$?

# 保留最近 N 份，删最旧
ls -t "$DST"/core_*.tar.gz 2>/dev/null | tail -n +$((CORE_BACKUP_KEEP + 1)) | xargs -r rm -f

[ "$RET" -ne 0 ] && [ -n "$ALERT_CMD" ] && $ALERT_CMD "core-backup 失败 $TS"
exit 0
