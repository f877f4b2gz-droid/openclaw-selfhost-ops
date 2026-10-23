#!/bin/bash
# ------------------------------------------------------------
# log-error-kb.sh — 日志报错知识库（Runbook 登记）
#
# 只登记「结论」，不执行任何处置动作。
#
# 用法：
#   log-error-kb.sh status <fp>      → known-harmless | known-manual | new
#   log-error-kb.sh get <fp>         → 该指纹的整条 JSON
#   log-error-kb.sh list             → 全部条目
#   log-error-kb.sh pending          → 待研究清单（新指纹自动追加）
#   log-error-kb.sh add --fp X --src Y [--sample S] \
#        [--status known-harmless|known-manual|new] [--cause C] [--impact I] \
#        [--action A] [--ref R] [--conf A|B|C]
#
# 数据位置：$WORKSPACE/knowledge/log-errors/{kb.jsonl,pending.tsv}
# 与 log-fingerprint.sh 配套：指纹负责归一化，本脚本负责记结论。
# ------------------------------------------------------------
set -u
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/ops_lib.sh
. "$SELF_DIR/../lib/ops_lib.sh"
ops_require_ws 2>/dev/null || true

DIR="${KB_DIR:-$WORKSPACE/knowledge/log-errors}"
KB="$DIR/kb.jsonl"
PEND="$DIR/pending.tsv"
mkdir -p "$DIR" 2>/dev/null
touch "$KB" "$PEND" 2>/dev/null

cmd="${1:-}"; shift || true
case "$cmd" in
  status)
    fp="${1:-}"
    [ -z "$fp" ] && { echo new; exit 0; }
    line=$(grep -F "\"fp\":\"$fp\"" "$KB" 2>/dev/null | head -1 || true)
    if [ -z "$line" ]; then echo new
    else echo "$line" | sed -E 's/.*"status":"([^"]+)".*/\1/'
    fi
    ;;
  get)
    grep -F "\"fp\":\"${1:-}\"" "$KB" 2>/dev/null | head -1 || true ;;
  list)
    cat "$KB" ;;
  pending)
    cat "$PEND" ;;
  add)
    fp=""; src=""; sample=""; status="new"; cause=""; impact=""; action=""; ref=""; conf="C"
    while [ $# -gt 0 ]; do
      case "$1" in
        --fp) fp="$2"; shift 2;; --src) src="$2"; shift 2;; --sample) sample="$2"; shift 2;;
        --status) status="$2"; shift 2;; --cause) cause="$2"; shift 2;;
        --impact) impact="$2"; shift 2;; --action) action="$2"; shift 2;;
        --ref) ref="$2"; shift 2;; --conf) conf="$2"; shift 2;;
        *) shift;;
      esac
    done
    [ -z "$fp" ] && { echo "缺少 --fp" >&2; exit 2; }
    # 覆盖同 fp 旧条目（先删后加），避免知识库无限堆积
    tmp=$(mktemp)
    grep -vF "\"fp\":\"$fp\"" "$KB" > "$tmp" 2>/dev/null || true
    mv "$tmp" "$KB"
    printf '{"fp":"%s","src":"%s","sample":"%s","first":"%s","status":"%s","cause":"%s","impact":"%s","action":"%s","ref":"%s","conf":"%s","review":"%s"}\n' \
      "$fp" "$src" "$sample" "$(date +%F)" "$status" "$cause" "$impact" "$action" "$ref" "$conf" \
      "$(date -d '+180 days' +%F 2>/dev/null || date +%F)" >> "$KB"
    echo "added $fp ($status)"
    ;;
  *)
    echo "用法: log-error-kb.sh {status|get|list|pending|add} ..." >&2; exit 2 ;;
esac
