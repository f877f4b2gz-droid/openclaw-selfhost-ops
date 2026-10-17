#!/bin/bash
# scratch-sweep.sh — scratch/ 兜底清理（P4）
# 用途：对 workspace/scratch/ 保存活期巡检——新进文件≥30天且被引=0、且连续两轮=0 → 移 trash；
#       存量（机制上线日已在的文件）豁免，只出清单人工审；首轮只出清单不删。
# 用法：scratch-sweep.sh [--dry-run]
# 状态：/var/lib/scratch-sweep/（seen.tsv / rounds / launch_date）
# 日志：/var/log/scratch-sweep.log
# 开源包：v2.0 发布整理 2026-10-17（源文件创建日期不详）
# 规则：docs/规则库.md @存活期@scratch@被引次数；scratch/README.md
set -u
if [ -f /usr/local/lib/wk.sh ]; then source /usr/local/lib/wk.sh; else echo "WARN: 未找到 /usr/local/lib/wk.sh，部分功能将受限" >&2; fi
# 降级兜底：私有库缺失时提供最小实现，保证主流程不中断
if ! declare -F wk_log >/dev/null 2>&1; then
  wk_log() { printf '[%s] %s\n' "$(date +%F\ %T)" "$*" >&2; }
  wk_notify() { printf '[notify] %s\n' "$*" >&2; }
fi
WK_NAME=scratch-sweep

WS="${WUKONG_WS:-<OPENCLAW_PATH>}"
SCRATCH="$WS/scratch"
STATE_DIR="${WK_STATE_DIR:-/var/lib/scratch-sweep}"
SEEN="$STATE_DIR/seen.tsv"
ROUNDS_F="$STATE_DIR/rounds"
LAUNCH_F="$STATE_DIR/launch_date"
TRASH="${WK_TRASH:-$WS/trash}"
SURVIVE_DAYS=30
ZERO_ROUNDS_TO_CLEAR=2
DRY=0; [ "${1:-}" = "--dry-run" ] && DRY=1

mkdir -p "$STATE_DIR" 2>/dev/null || { wk_log "无法建状态目录 $STATE_DIR"; exit 1; }
[ -d "$SCRATCH" ] || { wk_log "无 scratch/ 目录：$SCRATCH"; exit 0; }

now=$(date +%s); today=$(date +%F)
[ -f "$LAUNCH_F" ] || echo "$today" > "$LAUNCH_F"
launch=$(cat "$LAUNCH_F")
rounds=$(cat "$ROUNDS_F" 2>/dev/null || echo 0); rounds=$((rounds+1)); echo "$rounds" > "$ROUNDS_F"
FIRST_ROUND=0; [ "$rounds" -eq 1 ] && FIRST_ROUND=1

# 被引扫描范围（只读既有文件）
SCAN_DIRS=(/etc/cron.d /usr/local/bin "$WS/tools" "$WS/scripts" "$WS/docs" "$WS/projects")

tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
declare -A OLD
[ -f "$SEEN" ] && while IFS=$'\t' read -r f fs zr; do OLD["$f"]="$fs	$zr"; done < "$SEEN"

: > "$tmp"
cand=0; exempt=0; kept=0
info_lines=()
while IFS= read -r path; do
  rel="${path#$SCRATCH/}"
  base=$(basename "$path")
  # 首个字段=first_seen；若未见 → 记录（若今日=上线日 ⇒ 存量）
  if [ -n "${OLD[$rel]:-}" ]; then
    fs="${OLD[$rel]%%$'\t'*}"; zr="${OLD[$rel]##*$'\t'}"
    [ "$fs" = "$launch" ] && is_stock=1 || is_stock=0
  else
    fs="$today"; zr=0
    [ "$today" = "$launch" ] && is_stock=1 || is_stock=0
  fi
  # 被引次数
  refc=0
  for d in "${SCAN_DIRS[@]}"; do
    [ -d "$d" ] || continue
    c=$(grep -rl -- "$base" "$d" 2>/dev/null | grep -v "^$path$" | wc -l)
    refc=$((refc+c))
  done
  # zero_rounds 更新
  if [ "$refc" -eq 0 ]; then zr=$((zr+1)); else zr=0; fi
  age=$(( (now - $(date -d "$fs" +%s)) / 86400 ))
  printf '%s\t%s\t%s\n' "$rel" "$fs" "$zr" >> "$tmp"
  # 判定
  if [ "$is_stock" -eq 1 ]; then exempt=$((exempt+1)); continue; fi
  if [ ! -f "$SEEN" ] || [ "$FIRST_ROUND" -eq 1 ]; then kept=$((kept+1)); continue; fi
  if [ "$age" -ge "$SURVIVE_DAYS" ] && [ "$zr" -ge "$ZERO_ROUNDS_TO_CLEAR" ]; then
    cand=$((cand+1))
    info_lines+=("$rel  (age=${age}d ref=0 zeroRounds=$zr)")
    if [ "$DRY" -eq 0 ]; then
      mkdir -p "$TRASH/scratch-sweep-$(date +%Y%m%d)" && mv -- "$path" "$TRASH/scratch-sweep-$(date +%Y%m%d)/" 2>/dev/null && wk_log "移回收: $rel"
    fi
  else
    kept=$((kept+1))
  fi
done < <(find "$SCRATCH" -maxdepth 1 -type f | sort)

cp "$tmp" "$SEEN"

wk_log "scratch-sweep rounds=$rounds dry=$DRY 存量豁免=$exempt 保留=$kept 候选清理=$cand"
if [ "$cand" -gt 0 ]; then
  msg="scratch/ 到期候选 $cand 个（$([ $DRY -eq 1 ] && echo 预演 || echo 已移回收)）：$(printf '%s; ' "${info_lines[@]}")"
  wk_notify info scratch-sweep "$msg"
  echo "$msg"
else
  echo "scratch/ 无到期候选（存量豁免=$exempt 保留=$kept 轮次=$rounds${DRY:+ dry-run}）"
fi
