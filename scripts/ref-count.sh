#!/bin/bash
# ref-count.sh — 被引次数静态扫描（P6）
# 用途：对"未提纯层"（scratch/、临时脚本区、散落脚本）统计【被引次数 + 引用方 + 层级】，
#       供分层考核：未提纯层 =0 且 30 天没动 → 候选清理；砖层永不自动清（只展示）；墙/房不考核。
# 用法：ref-count.sh [--list-zero] [--json]
# 输出：层级<TAB>被引次数<TAB>脚本路径<TAB>引用方(逗号分隔)
# 只读，不删除。规则：docs/规则库.md @存活期@scratch@被引次数；docs/总纲.md
# 开源包：v2.0 发布整理 2026-10-17（源文件创建日期不详）
set -u
if [ -f /usr/local/lib/wk.sh ]; then source /usr/local/lib/wk.sh; else echo "WARN: 未找到 /usr/local/lib/wk.sh，部分功能将受限" >&2; fi
# 降级兜底：私有库缺失时提供最小实现，保证主流程不中断
if ! declare -F wk_log >/dev/null 2>&1; then
  wk_log() { printf '[%s] %s\n' "$(date +%F\ %T)" "$*" >&2; }
  wk_notify() { printf '[notify] %s\n' "$*" >&2; }
fi
WK_NAME=ref-count

WS="${WUKONG_WS:-<OPENCLAW_PATH>}"
LIST_ZERO=0; JSON=0
for a in "$@"; do case "$a" in --list-zero) LIST_ZERO=1;; --json) JSON=1;; esac; done

# 引用扫描范围（只读既有文件）
SCAN_DIRS=(/etc/cron.d /usr/local/bin "$WS/tools" "$WS/scripts" "$WS/scratch" "$WS/docs" "$WS/projects")
GREP_X=(--exclude-dir=node_modules --exclude-dir=.git --exclude-dir=backup --exclude-dir=state --exclude-dir=logs --exclude-dir=.venv --exclude-dir=archive --exclude-dir=dist --exclude-dir=assets --binary-files=without-match)
# 豁免层（不参与"=0就清"）
EXEMPT_PREFIX=("$WS/tools/" "/usr/local/bin/")
EXEMPT_NAME=("wk.sh" "qq-send.sh")

is_exempt_dir(){ local p="$1"; for x in "${EXEMPT_PREFIX[@]}"; do [[ "$p" == "$x"* ]] && return 0; done; return 1; }

# 目标：未提纯层 = scratch/（临时脚本区）+ 散落脚本（workspace 根）；只计脚本（.sh/.py）
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
