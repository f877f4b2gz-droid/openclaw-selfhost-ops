#!/bin/bash
# ------------------------------------------------------------
# inspect-daily.sh — 每日综合巡检（建议 cron 每天一次）
#
# 一次跑完九项，输出一段可直接推送的纯文本：
#   磁盘 / SMART / 温度 / 负载 · 备份新鲜度 · 服务 · 端口 · 进程
#   日志体检（报错指纹分类）· 大日志 Top3
#
# 核心设计：
#   - 报错不按条数报，按「指纹」报：同一类错误只算一条，
#     用 log-fingerprint.sh 归一化，用 log-error-kb.sh 记结论。
#     于是报告里只剩三种：新N / 待人工N / 已忽略N。
#   - 只扫系统日志 + 各应用 error.log，**不扫运维助手自身的日志**，
#     否则会把自己每轮心跳产生的告警当成系统故障（实测能占一半噪声）。
#   - 白名单：手动停用的应用/容器不告警。
#
# 用法：inspect-daily.sh [--dry]      --dry 只打印，不推送
# 退出码：0 正常 / 1 有告警项
#
# 配置见 ops.conf：INSPECT_* 系列。
# ------------------------------------------------------------
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/ops_lib.sh
. "$SELF_DIR/../lib/ops_lib.sh"

DRY=0
[ "${1:-}" = "--dry" ] && DRY=1

WS="${WORKSPACE:-$PWD}"
KB_DIR="${KB_DIR:-$WS/knowledge/log-errors}"
KB="$KB_DIR/kb.jsonl"; PEND="$KB_DIR/pending.tsv"
mkdir -p "$KB_DIR" 2>/dev/null; touch "$KB" "$PEND" 2>/dev/null

FP_BIN="$SELF_DIR/log-fingerprint.sh"
KB_BIN="$SELF_DIR/log-error-kb.sh"

MOUNTS="${INSPECT_MOUNTS:-/}"
DISKS="${SMART_DISKS:-}"
SERVICES="${INSPECT_SERVICES:-}"
PORTS="${INSPECT_PORTS:-}"
PROCS="${INSPECT_PROCS:-}"
APP_IGNORE="${INSPECT_APP_IGNORE:-}"
DOCKER_IGNORE="${INSPECT_DOCKER_IGNORE:-}"
NOTIFY_CMD="${INSPECT_NOTIFY_CMD:-}"
LOG_HOURS="${INSPECT_LOG_HOURS:-24}"

# ---- 磁盘 ----
DISK_OUT=""
for m in $MOUNTS; do
  v=$(df -h "$m" 2>/dev/null | awk 'NR==2{print $3"/"$2" ("$5")"}')
  [ -z "$v" ] && v="挂载异常"
  DISK_OUT="$DISK_OUT $m $v ｜"
done
DISK_OUT="${DISK_OUT% ｜}"

# ---- 内存 / 负载 / 温度 ----
MEM=$(free -h 2>/dev/null | awk '/^Mem:/{print $3"/"$2}')
LOAD=$(awk '{print $1", "$2", "$3}' /proc/loadavg 2>/dev/null)
TEMP=$(sensors 2>/dev/null | awk '/Package id 0:/{gsub(/[+°C]/,"",$4); print $4; exit}')
[ -z "$TEMP" ] && TEMP="-"
TEMP_WARN=""
[ -n "$TEMP" ] && [ "$TEMP" != "-" ] && awk -v t="$TEMP" 'BEGIN{exit !(t>80)}' && TEMP_WARN="(偏高)"

# ---- SMART ----
SMART_BAD=""
for d in $DISKS; do
  [ -b "$d" ] || continue
  h=$(sudo -n smartctl -H "$d" 2>/dev/null | grep -oE 'PASSED|FAILED!' | head -1)
  [ "$h" = "FAILED!" ] && SMART_BAD="$SMART_BAD ${d##*/}"
done
[ -z "$SMART_BAD" ] && SMART_BAD="${DISKS:+全部PASSED}"

# ---- 备份新鲜度（目录约定：$BACKUP_CHECK_DIR/YYYY-MM-DD）----
TODAY=$(date +%F)
BK_ST="-"
if [ -n "${BACKUP_CHECK_DIR:-}" ]; then
  [ -d "$BACKUP_CHECK_DIR/$TODAY" ] && BK_ST="今日已备" || BK_ST="⚠️ 今日未备份"
fi

# ---- 容器 ----
DOCKER_BAD=""
if command -v docker >/dev/null 2>&1; then
  DOCKER_BAD=$(docker ps -a --format '{{.Names}}|{{.Status}}' 2>/dev/null | awk -F'|' -v ig="$DOCKER_IGNORE" '
    BEGIN{n=split(ig,a," ");for(i=1;i<=n;i++)if(a[i]!="")skip[a[i]]=1}
    $2 !~ /^(Up|Created|Restarting)/ && !($1 in skip){print $1}' | paste -sd, -)
  [ -z "$DOCKER_BAD" ] && DOCKER_BAD="全部在线"
fi

# ---- 服务 ----
SVC_BAD=""
for s in $SERVICES; do
  st=$(systemctl is-active "$s" 2>/dev/null)
  [ "$st" != "active" ] && SVC_BAD="$SVC_BAD $s($st)"
done
[ -z "$SVC_BAD" ] && SVC_BAD="${SERVICES:+全部 active}"

# ---- 端口 ----
PORT_BAD=""
for p in $PORTS; do
  ss -tln 2>/dev/null | awk '{print $4}' | grep -qE ":$p$" || PORT_BAD="$PORT_BAD $p"
done
[ -z "$PORT_BAD" ] && PORT_BAD="${PORTS:+全部在听}"

# ---- 进程（格式 匹配串:显示名）----
PROC_BAD=""
for spec in $PROCS; do
  pat="${spec%%:*}"; name="${spec##*:}"
  [ -z "$pat" ] && continue
  pgrep -f "$pat" >/dev/null 2>&1 || PROC_BAD="$PROC_BAD $name"
done
[ -z "$PROC_BAD" ] && PROC_BAD="${PROCS:+全部在跑}"

# ===== 日志体检 + 报错知识库 =====
LOG_TOTAL=$(du -sh /var/log 2>/dev/null | awk '{print $1}')
JOURNAL=$(journalctl --disk-usage 2>/dev/null | grep -oE '[0-9.]+ ?[KMGT]i?B?' | head -1)
[ -z "$JOURNAL" ] && JOURNAL="-"

RAW=$(mktemp); FPS=$(mktemp)
mapfile -t APP_ERRS < <(find ${LOG_SCAN_DIRS:-/var/log} -name "error.log" -mmin -$((LOG_HOURS*60)) 2>/dev/null | while IFS= read -r f; do [ -r "$f" ] && printf '%s\n' "$f"; done)
mapfile -t BIG_ERRS < <(find ${LOG_SCAN_DIRS:-/var/log} -name "error.log" -size +5M 2>/dev/null | while IFS= read -r f; do [ -r "$f" ] && printf '%s\n' "$f"; done)

# 注意：这里刻意不包含运维助手自身的日志文件（INSPECT_SELF_LOGS 显式指定才会扫）
for lf in /var/log/syslog /var/log/kern.log /var/log/auth.log /var/log/cron.log \
          ${INSPECT_SELF_LOGS:-} "${APP_ERRS[@]}"; do
  [ -f "$lf" ] || continue
  [ -r "$lf" ] || continue
  lab="${lf#/var/log/}"
  tail -n 800 "$lf" 2>/dev/null \
    | grep -aiE 'error|failed|failure|panic|critical|fatal|exception|traceback' \
    | grep -avE 'sudo: .*COMMAND=|^\{' \
    | while IFS= read -r l; do printf '%s\t%s\n' "$lab" "$l"; done >> "$RAW"
done

if [ -s "$RAW" ]; then
  paste -d'\t' <(cut -f1 "$RAW") <(cut -f2- "$RAW" | "$FP_BIN") 2>/dev/null | sort -u -k2,2 > "$FPS"
else
  : > "$FPS"
fi

NEWN=0; MANN=0; HARMN=0; NEWSAMP=""
while IFS=$'\t' read -r src fp sample; do
  [ -z "${fp:-}" ] && continue
  st=$("$KB_BIN" status "$fp")
  case "$st" in
    known-harmless) HARMN=$((HARMN+1)) ;;
    known-manual)   MANN=$((MANN+1)) ;;
    *)
      NEWN=$((NEWN+1))
      [ "$NEWN" -le 3 ] && NEWSAMP="$NEWSAMP ${src}:$(printf '%s' "$sample" | cut -c1-70)"
      grep -qF "$fp" "$PEND" 2>/dev/null || \
        printf '%s\t%s\t%s\t%s\n' "$fp" "$src" "$(printf '%s' "$sample" | cut -c1-120)" "$(date +%F)" >> "$PEND"
      ;;
  esac
done < "$FPS"
rm -f "$RAW" "$FPS"
[ -z "$NEWSAMP" ] && NEWSAMP=" 无"

BIG=$( { du -ah /var/log 2>/dev/null | grep -E '\.log$'; \
         [ "${#BIG_ERRS[@]}" -gt 0 ] && printf '%s\n' "${BIG_ERRS[@]}" | xargs -r du -h 2>/dev/null; } \
       | sort -u -k2,2 | sort -rh | head -3 \
       | awk '{gsub("/var/log/","",$2); printf "%s(%s) ", $2, $1}')
[ -z "$BIG" ] && BIG="-"

OUT="【每日巡检 $(date +%F)】
磁盘:$DISK_OUT
SMART: ${SMART_BAD:--} ｜ 温度: ${TEMP}°C$TEMP_WARN
内存+负载: $MEM, load $LOAD
备份: $BK_ST
容器异常: ${DOCKER_BAD:--}
服务异常:$SVC_BAD
端口未听:$PORT_BAD
进程缺失:$PROC_BAD
日志总量: $LOG_TOTAL / journald $JOURNAL
报错分类: 新${NEWN} / 待人工${MANN} / 已忽略${HARMN}
新报错:$NEWSAMP
大日志: $BIG"

if [ "$DRY" = "1" ] || [ -z "$NOTIFY_CMD" ]; then
  printf '%s\n' "$OUT"
  [ -z "$NOTIFY_CMD" ] && echo "（未配置 INSPECT_NOTIFY_CMD，仅打印不推送）" >&2
  exit 0
fi

printf '%s' "$OUT" | eval "$NOTIFY_CMD" >>"${LOG_DIR:-/var/log}/inspect-daily.log" 2>&1
