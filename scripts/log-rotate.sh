#!/bin/bash
# 统一清理：服务日志截断 + 会话残留清理 + 手工备份瘦身 + cache-trace 重写。
# cron：每日 04:10（见 cron/ 示例）。任一步失败不影响其他步骤。
#
# 用法：log-rotate.sh [--dry-run]      --dry-run 只报告"会动哪些文件"，不实际改动
#
# 需配置（环境变量，或写进 ops.conf；详见 ops.conf.example）——无硬编码真实路径/凭据：
#   必填  WORKSPACE               工作区根（清理 *.bak.<ts> 用）
#   选填  OPENCLAW_HOME           默认 $HOME/.openclaw
#   选填  ROTATE_LOGS             服务日志清单，格式 "路径:保留天数"（空格分隔）
#   阈值  LOG_SERVICE_MAX LOG_SERVICE_KEEP_LINES SESS_KEEP_DAYS CT_LOG_MAX CT_KEEP_RATIO
# 读配置：$OPS_CONF（默认 /etc/openclaw-ops/ops.conf）。
set -u

DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

CONF="${OPS_CONF:-/etc/openclaw-ops/ops.conf}"
[ -f "$CONF" ] && . "$CONF"
: "${WORKSPACE:?未配置 WORKSPACE（见 ops.conf.example）}"
: "${OPENCLAW_HOME:=$HOME/.openclaw}"
: "${LOG_SERVICE_MAX:=$((50 * 1024 * 1024))}"
: "${LOG_SERVICE_KEEP_LINES:=1000}"
: "${SESS_KEEP_DAYS:=7}"
: "${CT_LOG_MAX:=$((300 * 1024 * 1024))}"
: "${CT_KEEP_RATIO:=5}"
: "${ROTATE_LOGS:=}"

[ "$DRY" -eq 1 ] && echo "[dry-run] 配置=$CONF WORKSPACE=$WORKSPACE OPENCLAW_HOME=$OPENCLAW_HOME"

# ===== 1) 服务日志截断 + 轮转件按天数清理 =====
for spec in $ROTATE_LOGS; do
  f="${spec%%:*}"; days="${spec##*:}"
  [ -f "$f" ] || continue
  sz=$(stat -c%s "$f" 2>/dev/null || echo 0)
  if [ "$sz" -gt "$LOG_SERVICE_MAX" ]; then
    if [ "$DRY" -eq 1 ]; then
      echo "  [dry-run] 截断 $f （${sz} 字节 → 保留最近 $LOG_SERVICE_KEEP_LINES 行）"
    else
      tail -n "$LOG_SERVICE_KEEP_LINES" "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    fi
  fi
  if [ -n "$days" ] && [ "$days" != "$f" ]; then
    rn=$(find "$(dirname "$f")" -maxdepth 1 -name "$(basename "$f").*" -mtime +"$days" 2>/dev/null | wc -l | tr -d ' ')
    if [ "${rn:-0}" -gt 0 ]; then
      if [ "$DRY" -eq 1 ]; then
        echo "  [dry-run] 清理轮转件 $f.* 共 ${rn} 个（>${days}天）"
      else
        find "$(dirname "$f")" -maxdepth 1 -name "$(basename "$f").*" -mtime +"$days" -delete 2>/dev/null
      fi
    fi
  fi
done

# ===== 2) openclaw 会话残留清理（trajectory/bak/checkpoint，超期删；不动主 .jsonl）=====
SESS_DIR="$OPENCLAW_HOME/agents/main/sessions"
SESS_CNT=$(find "$SESS_DIR" -maxdepth 1 -type f \( -name "*.trajectory.jsonl" -o -name "*.bak-*" -o -name "*.checkpoint.*" \) -mtime +"$SESS_KEEP_DAYS" 2>/dev/null | wc -l | tr -d ' ')
SESS_BYTES=$(find "$SESS_DIR" -maxdepth 1 -type f \( -name "*.trajectory.jsonl" -o -name "*.bak-*" -o -name "*.checkpoint.*" \) -mtime +"$SESS_KEEP_DAYS" -printf '%s\n' 2>/dev/null | awk '{s+=$1} END{print s+0}')
SESS_CNT=${SESS_CNT:-0}; SESS_BYTES=${SESS_BYTES:-0}
if [ "$DRY" -eq 1 ]; then
  echo "  [dry-run] 会话残留（>$SESS_KEEP_DAYS 天）将删 ${SESS_CNT} 个 / ${SESS_BYTES} 字节"
else
  find "$SESS_DIR" -maxdepth 1 -type f -name "*.trajectory.jsonl" -mtime +"$SESS_KEEP_DAYS" -delete 2>/dev/null
  find "$SESS_DIR" -maxdepth 1 -type f -name "*.bak-*" -mtime +"$SESS_KEEP_DAYS" -delete 2>/dev/null
  find "$SESS_DIR" -maxdepth 1 -type f -name "*.checkpoint.*" -mtime +"$SESS_KEEP_DAYS" -delete 2>/dev/null
fi

# ===== 3) 工作区手工备份瘦身（带时间戳的 *.bak.<ts> / *.bak-<ts> 每类保留最新 1 份）=====
WS_CNT=0; WS_BYTES=0
if [ -d "$WORKSPACE" ]; then
  find "$WORKSPACE" -maxdepth 1 -type f \( -name "*.bak.[0-9]*" -o -name "*.bak-[0-9]*" \) -printf '%T@\t%p\n' 2>/dev/null | sort -rn | awk -F'\t' '{t=$2; sub(/\.bak[.-][0-9][0-9-]*$/,"",t); if (seen[t]++) print $2}' > /tmp/.logrotate_ws_del.list
  WS_CNT=$(wc -l < /tmp/.logrotate_ws_del.list 2>/dev/null | tr -d ' '); WS_CNT=${WS_CNT:-0}
  WS_BYTES=$(tr '\n' '\0' < /tmp/.logrotate_ws_del.list 2>/dev/null | xargs -0 -r stat -c%s 2>/dev/null | awk '{s+=$1} END{print s+0}'); WS_BYTES=${WS_BYTES:-0}
  if [ "$DRY" -eq 1 ]; then
    echo "  [dry-run] 手工备份将删 ${WS_CNT} 个 / ${WS_BYTES} 字节"
  else
    tr '\n' '\0' < /tmp/.logrotate_ws_del.list 2>/dev/null | xargs -0 -r rm -f 2>/dev/null
  fi
  rm -f /tmp/.logrotate_ws_del.list 2>/dev/null
fi

# ===== 4) cache-trace 重写（超上限则原地重写，只保留最近 1/N 行）=====
CT_LOG="$OPENCLAW_HOME/logs/cache-trace.jsonl"
if [ -f "$CT_LOG" ]; then
  CT_SZ=$(stat -c%s "$CT_LOG" 2>/dev/null || echo 0)
  if [ "$CT_SZ" -gt "$CT_LOG_MAX" ]; then
    CT_TOTAL=$(wc -l < "$CT_LOG" 2>/dev/null | tr -d ' '); CT_TOTAL=${CT_TOTAL:-0}
    CT_KEEP=$((CT_TOTAL / CT_KEEP_RATIO))
    if [ "$CT_KEEP" -lt 1 ]; then
      echo "[log-rotate] cache-trace 超上限，但总行数=${CT_TOTAL}，跳过（防清空）"
    elif [ "$DRY" -eq 1 ]; then
      echo "  [dry-run] 重写 cache-trace（${CT_SZ} 字节 → 保留最近 1/${CT_KEEP_RATIO} 行：${CT_KEEP}/${CT_TOTAL}）"
    else
      tail -n "$CT_KEEP" "$CT_LOG" > "$CT_LOG.tmp" && cat "$CT_LOG.tmp" > "$CT_LOG" && rm -f "$CT_LOG.tmp"
      CT_NEW=$(stat -c%s "$CT_LOG" 2>/dev/null || echo 0)
      CT_H=$(numfmt --to=iec --suffix=B "$CT_NEW" 2>/dev/null || echo "${CT_NEW}B")
      echo "[log-rotate $(date '+%F %T')] cache-trace 超上限，原地重写保留最近 1/${CT_KEEP_RATIO} 行 (${CT_KEEP}/${CT_TOTAL}) -> ${CT_H}"
    fi
  fi
fi

# ===== 5) 汇总 =====
if [ "$DRY" -eq 1 ]; then
  echo "[dry-run] 结束：无任何改动。"
  exit 0
fi
SESS_H=$(numfmt --to=iec --suffix=B "$SESS_BYTES" 2>/dev/null || echo "${SESS_BYTES}B")
WS_H=$(numfmt --to=iec --suffix=B "$WS_BYTES" 2>/dev/null || echo "${WS_BYTES}B")
TOT_CNT=$((SESS_CNT + WS_CNT))
TOT_H=$(numfmt --to=iec --suffix=B "$((SESS_BYTES + WS_BYTES))" 2>/dev/null || echo "$((SESS_BYTES + WS_BYTES))B")
echo "[log-rotate $(date '+%F %T')] 清理完成 | 会话残留 ${SESS_CNT} 个/释放 ${SESS_H} | 手工备份 ${WS_CNT} 个/释放 ${WS_H} | 合计 ${TOT_CNT} 个/释放 ${TOT_H}"
