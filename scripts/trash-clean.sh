#!/bin/bash
# ------------------------------------------------------------
# 回收站清理：删掉 TRASH_DIR 下超过 N 天的条目
#
# 为什么要有回收站：`trash > rm` 是硬规矩 —— 删除先进回收站，
# 超期才真正清掉，给"删错了"留一个后悔窗口。
#
# 用法：trash-clean.sh [--dry-run]
#
# 配置（ops.conf）：TRASH_DIR MEMORY_KEEP_DAYS LOG_DIR
# 阈值默认（来自实战）：TRASH_DIR 超 30 天清理
# ------------------------------------------------------------
set -u

DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

CONF="${OPS_CONF:-/etc/openclaw-ops/ops.conf}"
# shellcheck disable=SC1090
[ -f "$CONF" ] && . "$CONF"

TRASH="${TRASH_DIR:-}"
KEEP_DAYS="${TRASH_KEEP_DAYS:-${MEMORY_KEEP_DAYS:-30}}"
LOG="${LOG_DIR:-/var/log}/trash-clean.log"
TS=$(date '+%F %T')

if [ -z "$TRASH" ]; then
  echo "$TS  未配置 TRASH_DIR，跳过（见 ops.conf.example）"
  exit 0
fi

mkdir -p "$(dirname "$LOG")"

if [ ! -d "$TRASH" ]; then
  echo "$TS  trash 目录不存在，跳过：$TRASH" >> "$LOG"
  exit 0
fi

CNT=$(find "$TRASH" -mindepth 1 -maxdepth 1 -mtime +"$KEEP_DAYS" 2>/dev/null | wc -l | tr -d ' ')

if [ "$DRY" = "1" ]; then
  echo "$TS  [dry] trash 超${KEEP_DAYS}天待删：${CNT} 项（$TRASH）"
  exit 0
fi

# 日志超上限先截断，保留尾部
if [ -f "$LOG" ] && [ "$(stat -c%s "$LOG" 2>/dev/null || echo 0)" -gt 1048576 ]; then
  tail -n 1000 "$LOG" > "$LOG.tmp" && cat "$LOG.tmp" > "$LOG" && rm -f "$LOG.tmp"
fi

find "$TRASH" -mindepth 1 -maxdepth 1 -mtime +"$KEEP_DAYS" -exec rm -rf {} + 2>/dev/null
LEFT=$(find "$TRASH" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')
echo "$TS  清理 trash 超${KEEP_DAYS}天：删除 ${CNT} 项 | 剩余 ${LEFT} 项" >> "$LOG"
echo "已清理 ${CNT} 项，剩余 ${LEFT} 项"
exit 0
