#!/bin/bash
# ------------------------------------------------------------
# ref-count.sh — 脚本被引次数静态扫描
#
# 用途：对未沉淀脚本（scratch/、临时脚本区、工作区散落脚本）统计
#       【被引次数 + 引用方 + 层级】，供分层考核。层级采用建筑隐喻
#       （与 docs/架构设计与复用体系.md §七 P6 一致）：
#       砖=共享层(被引≥3，永不自动清理、仅展示) / 墙=被引层 / 房=依赖外部的出口层 /
#       未提纯=未沉淀层（=0 且 30 天未动 → 清理候选）；豁免层不参与考核。
#
# 用法：ref-count.sh [--list-zero] [--json]
#   --list-zero  只列被引 =0 的脚本
#   --json       每行输出一个 JSON 对象（供程序消费）
#
# 输出：层级<TAB>被引次数<TAB>脚本路径<TAB>引用方(逗号分隔)
# 只读，不删除任何文件。
# 配置（ops.conf）：WORKSPACE
# ------------------------------------------------------------
set -u
source "$(dirname "${BASH_SOURCE[0]}")/../lib/ops_lib.sh"
WK_NAME=ref-count

ops_require_ws
LIST_ZERO=0; JSON=0
for arg in "$@"; do case "$arg" in --list-zero) LIST_ZERO=1;; --json) JSON=1;; esac; done

# 引用扫描范围（只读既有文件）
SCAN_DIRS=(/etc/cron.d /usr/local/bin "$WS/tools" "$WS/scripts" "$WS/scratch" "$WS/docs" "$WS/projects")
# 扫描时排除的目录/文件类型（降噪 + 防二进制误匹配）
GREP_X=(--exclude-dir=node_modules --exclude-dir=.git --exclude-dir=backup --exclude-dir=state --exclude-dir=logs --exclude-dir=.venv --exclude-dir=archive --exclude-dir=dist --exclude-dir=assets --binary-files=without-match)
# 豁免层（不参与"=0 即清"考核）
EXEMPT_PREFIX=("$WS/tools/" "/usr/local/bin/")
EXEMPT_NAME=("wk.sh" "qq-send.sh")

is_exempt_dir(){ local p="$1"; for x in "${EXEMPT_PREFIX[@]}"; do [[ "$p" == "$x"* ]] && return 0; done; return 1; }

# 目标：未沉淀层 = scratch/（临时脚本区）+ 工作区根散落脚本；只统计 .sh/.py
TARGETS=()
while IFS= read -r f; do [ -n "$f" ] && TARGETS+=("$f"); done < <(
  { find "$WS/scratch" -maxdepth 1 -type f \( -name '*.sh' -o -name '*.py' \) 2>/dev/null
    find "$WS" -maxdepth 1 -type f \( -name '*.sh' -o -name '*.py' \) 2>/dev/null
  } | sort -u )

refs_of(){ # $1=file → 打印引用方（换行）
  local self="$1" base; base=$(basename "$self")
  for d in "${SCAN_DIRS[@]}"; do
    [ -d "$d" ] || continue
    grep -rl "${GREP_X[@]}" -- "$base" "$d" 2>/dev/null | grep -v "^${self}$"
  done | sort -u
}

calls_others(){ # $1=file
  local f="$1" base; base=$(basename "$f")
  [ -f "$f" ] || return 1
  grep -q "wk\.sh" "$f" && return 0
  grep -qE "(/usr/local/bin/|scratch/|tools/)[A-Za-z0-9._-]+\.(sh|py)|wk-(find|rule|notify)" "$f" && return 0
  return 1
}

total=0; zeros=0; exempt_n=0
printf '%s\n' "层级	被引	脚本	引用方"
for f in "${TARGETS[@]}"; do
  total=$((total+1))
  mapfile -t refs < <(refs_of "$f")
  rc=${#refs[@]}
  if is_exempt_dir "$f" || [[ " ${EXEMPT_NAME[*]} " == *" $(basename "$f") "* ]]; then lvl="豁免"; exempt_n=$((exempt_n+1))
  else
    if   [ "$rc" -ge 3 ]; then lvl="砖"
    elif [ "$rc" -gt 0 ]; then lvl="墙"
    elif calls_others "$f"; then lvl="房"
    else lvl="未提纯"; fi
  fi
  [ "$rc" -eq 0 ] && zeros=$((zeros+1))
  [ "$LIST_ZERO" -eq 1 ] && [ "$rc" -ne 0 ] && continue
  refstr=$(IFS=,; echo "${refs[*]:-}")
  if [ "$JSON" -eq 1 ]; then
    printf '{"level":"%s","refs":%d,"path":"%s","referrers":"%s"}\n' "$lvl" "$rc" "$f" "$refstr"
  else
    printf '%s\t%s\t%s\t%s\n' "$lvl" "$rc" "$f" "$refstr"
  fi
done

wk_log "ref-count targets=$total zero=$zeros exempt=$exempt_n"
{
  echo "扫描脚本 $total 个；0 被引 $zeros 个；豁免层 $exempt_n 个。"
  echo "判据：未提纯层 =0 且 30 天没动 → 候选清理（首扫只出清单）；砖层永不自动清；墙/房不考核。"
} >&2
