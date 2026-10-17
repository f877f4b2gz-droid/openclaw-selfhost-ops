#!/bin/bash
# ------------------------------------------------------------
# cache-trace 缓存轨迹瘦身：保留最近 N 天 + 全局大小硬上限
#
# 背景：cache-trace.jsonl 会持续增长（单文件曾涨到 400MB+），
#       它记录 prompt 缓存命中轨迹，属于"高频变更、不该进上下文"的运行数据。
#       本脚本原地截断写回 —— 保持 inode，writer 用 O_APPEND 追加是安全的。
#
# 用法：cache-trace-trim.sh [--dry-run] [FILE] [DAYS]
#   --dry-run   只报告会裁掉多少，不写回
#   FILE/DAYS   覆盖 ops.conf 里的 CT_FILE / CT_KEEP_DAYS
#
# 配置（ops.conf）：CT_FILE CT_KEEP_DAYS CT_CAP_BYTES
# 阈值默认（来自实战）：保留 7 天；上限 4 GiB
# ------------------------------------------------------------
set -euo pipefail

DRY=0
if [ "${1:-}" = "--dry-run" ]; then DRY=1; shift; fi

CONF="${OPS_CONF:-/etc/openclaw-ops/ops.conf}"
# shellcheck disable=SC1090
[ -f "$CONF" ] && . "$CONF"

# 要裁的文件必须明确（命令行参数 或 CT_FILE）；不给默认值 ——
# 这脚本会**原地重写**目标文件，猜错目标的代价太大。
FILE="${1:-${CT_FILE:-}}"
if [ -z "$FILE" ]; then
  echo "未指定要裁剪的文件（命令行给路径，或在 ops.conf 里设 CT_FILE）；拒绝运行。" >&2
  exit 2
fi
DAYS="${2:-${CT_KEEP_DAYS:-7}}"
CAP="${CT_CAP_BYTES:-$((4 * 1024 * 1024 * 1024))}"

[ -f "$FILE" ] || { echo "$(date '+%F %T') 目标文件不存在，跳过。"; exit 0; }

CUT=$(date -u -d "$DAYS days ago" +%Y-%m-%dT%H:%M:%S)
BEFORE=$(stat -c%s "$FILE")
TMP=$(mktemp "${FILE}.trim.XXXXXX")
trap 'rm -f "$TMP"' EXIT

CHANGED=$(python3 - "$FILE" "$TMP" "$CUT" <<'PY'
import re
import sys

src, tmp, cut = sys.argv[1], sys.argv[2], sys.argv[3]
# 注意：真实数据里 ts 后面常有空格（`"ts": "..."`），正则必须容忍空白，
# 否则一行都匹配不上 → 按天数裁剪形同失效（只剩大小上限兜底）。
rx = re.compile(r'"ts"\s*:\s*"([^"]{1,40})"')
kept = dropped = 0
with open(src, errors="ignore") as f, open(tmp, "w") as o:
    for line in f:
        m = rx.search(line)
        if m and m.group(1) < cut:
            dropped += 1
            continue
        o.write(line)
        kept += 1
print(f"{kept} {dropped} {1 if dropped else 0}")
PY
)
KEPT=$(echo "$CHANGED" | cut -d' ' -f1)
DROPPED=$(echo "$CHANGED" | cut -d' ' -f2)
NEED=$(echo "$CHANGED" | cut -d' ' -f3)

# 大小上限：超上限只保留尾部 CAP（丢首行以免截断成半行 JSON）
SZ=$(stat -c%s "$TMP")
if [ "$SZ" -gt "$CAP" ]; then
  tail -c "$CAP" "$TMP" | tail -n +2 > "$TMP.2" && mv "$TMP.2" "$TMP"
  NEED=1
fi

if [ "$NEED" = "1" ]; then
  if [ "$DRY" = "1" ]; then
    echo "$(date '+%F %T') [dry] would trim: kept=$KEPT dropped=$DROPPED  $((BEFORE/1024/1024))MiB -> $((SZ/1024/1024))MiB (cutoff $CUT)"
  else
    cat "$TMP" > "$FILE"
    AFTER=$(stat -c%s "$FILE")
    echo "$(date '+%F %T') trim ok: kept=$KEPT dropped=$DROPPED  $((BEFORE/1024/1024))MiB -> $((AFTER/1024/1024))MiB (cutoff $CUT)"
  fi
else
  echo "$(date '+%F %T') trim noop: kept=$KEPT (all within $DAYS days, $((SZ/1024/1024))MiB)"
fi
