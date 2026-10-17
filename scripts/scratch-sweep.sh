#!/bin/bash
# ------------------------------------------------------------
# scratch-sweep.sh — 草稿区兜底清理
#
# 用途：对 scratch/ 做存活期巡检。新进文件存活 ≥30 天、被引次数 =0
#       且连续两轮 =0 → 移入 trash；机制上线前已存在的存量文件豁免，
#       仅输出清单交人工复核；首轮扫描只出清单、不删除。
#
# 用法：scratch-sweep.sh [--dry-run]
#   --dry-run  只列出到期候选，不移动文件、不更新状态判定
#
# 配置（ops.conf，见 templates/ops.conf.example）：
#   WORKSPACE 草稿区所在的工作区根；TRASH_DIR 回收站；WK_STATE_DIR 状态目录
# 状态：${WK_STATE_DIR:-/var/lib/scratch-sweep}/（seen.tsv / rounds / launch_date）
# ------------------------------------------------------------
set -u
source "$(dirname "${BASH_SOURCE[0]}")/../lib/ops_lib.sh"
WK_NAME=scratch-sweep

ops_require_ws
SCRATCH="$WS/scratch"
STATE_DIR="${WK_STATE_DIR:-/var/lib/scratch-sweep}"
SEEN="$STATE_DIR/seen.tsv"
ROUNDS_F="$STATE_DIR/rounds"
LAUNCH_F="$STATE_DIR/launch_date"
TRASH="${TRASH_DIR:-${WK_TRASH:-$WS/trash}}"
SURVIVE_DAYS="${SCRATCH_SURVIVE_DAYS:-30}"
ZERO_ROUNDS_TO_CLEAR="${SCRATCH_ZERO_ROUNDS:-2}"
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
  echo "scratch/ 无到期候选（存量豁免=$exempt 保留=$kept 轮次=$rounds）"
fi
