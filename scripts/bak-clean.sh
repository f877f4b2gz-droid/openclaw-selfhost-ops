#!/bin/bash
# ------------------------------------------------------------
# .bak 清理：每个目标文件只留最近 N 份
#
# 背景：改配置前先 `名字.bak.YYYYMMDD-HHMMSS` 是硬规矩，代价是 .bak 会堆积。
#       本脚本按"去掉 .bak* 后缀后的原名"归组，每组只留最新 N 份，其余删除。
#       最近 BAK_KEEP_RECENT_H 小时内产生的一律不动（防误删正在改的东西）。
#
# 用法：bak-clean.sh [--dry-run]
#
# 配置（ops.conf）：BAK_ROOTS BAK_KEEP_RECENT_H BAK_KEEP_PER_TARGET LOG_DIR
# 阈值默认（来自实战）：扫描 /etc /usr/local/bin /opt；每目标留 1 份；6h 内不动
#
# 安全：删除前先列清单；不跨文件系统（-xdev）；支持 --dry-run 预览。
# ------------------------------------------------------------
set -u

DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

CONF="${OPS_CONF:-/etc/openclaw-ops/ops.conf}"
# shellcheck disable=SC1090
[ -f "$CONF" ] && . "$CONF"

# 本脚本只依赖 BAK_ROOTS / BAK_KEEP_*，不依赖 WORKSPACE。
# 删除范围**必须显式配置**：不给默认值，避免"没配就扫了系统目录"这种事。
[ -n "${BAK_ROOTS:-}" ] || {
  echo "未配置 BAK_ROOTS（要清理 .bak 的根目录，见 ops.conf.example）；拒绝运行。" >&2
  exit 2
}
ROOTS="$BAK_ROOTS"
KEEP_RECENT_H="${BAK_KEEP_RECENT_H:-6}"
KEEP_N="${BAK_KEEP_PER_TARGET:-1}"
LOG="${LOG_DIR:-/var/log}/bak-clean.log"

cut=$(( $(date +%s) - KEEP_RECENT_H * 3600 ))
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

# 按修改时间倒序，同组只输出第 N+1 个之后（即该删的）
# shellcheck disable=SC2086
find $ROOTS -xdev -type f -name '*.bak*' ! -newermt "@$cut" -printf '%T@|%p\n' 2>/dev/null \
  | sort -t'|' -k1,1nr \
  | awk -F'|' -v keep="$KEEP_N" '{p=$2; b=p; sub(/\.bak.*$/,"",b); if (seen[b]++ >= keep) print p}' > "$TMP"

n=$(grep -c . "$TMP" || true)

if [ "$DRY" = 1 ]; then
  echo "[dry-run] 将删除 $n 个（每目标留最新 $KEEP_N 份；${KEEP_RECENT_H}h 内不动）："
  cat "$TMP"
else
  [ "$n" -gt 0 ] && xargs -r -a "$TMP" rm -f
  mkdir -p "$(dirname "$LOG")"
  echo "$(date '+%F %T')  .bak 清理 $n 个（每目标留最新 $KEEP_N 份；${KEEP_RECENT_H}h 内不动）" >> "$LOG"
  echo "已清理 $n 个"
fi
