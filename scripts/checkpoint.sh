#!/bin/bash
# ------------------------------------------------------------
# checkpoint.sh — 会话检查点
#
# 目的：切换模型 / 上下文压缩 / 会话重置时，把「已做·在做·待做」落到文件，
#       下次接续时先读文件，不靠记忆回忆，避免丢进度。
#
# 用法：
#   checkpoint.sh "已做" "在做" "待做"    # 追加一条（最新在最上面）
#   checkpoint.sh --show                # 看最近 3 条
#   checkpoint.sh --last                # 只看最后一条
#
# 落盘位置：$WORKSPACE/state/checkpoint.md
# ------------------------------------------------------------
set -u
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/ops_lib.sh
. "$SELF_DIR/../lib/ops_lib.sh"
ops_require_ws 2>/dev/null || true

OUT="${WORKSPACE:-.}/state/checkpoint.md"
mkdir -p "$(dirname "$OUT")" 2>/dev/null
[ -f "$OUT" ] || printf '# 会话检查点\n\n> 切换模型 / 上下文压缩前落盘。最新在最上面。\n\n' > "$OUT"

case "${1:-}" in
  --show) awk '/^## /{n++} n<=3' "$OUT" | head -60; exit 0 ;;
  --last) awk '/^## /{n++} n<=1' "$OUT" | head -40; exit 0 ;;
  "")     echo "用法: $0 \"已做\" \"在做\" \"待做\"" >&2; exit 2 ;;
esac

TS=$(date '+%Y-%m-%d %H:%M')
BLOCK="## $TS
- 已做：${1:-}
- 在做：${2:-}
- 待做：${3:-}

"

python3 - "$OUT" "$BLOCK" << 'PY'
import sys, re
p, block = sys.argv[1], sys.argv[2]
s = open(p, encoding='utf-8').read()
m = re.search(r'^## ', s, re.M)
s = (s[:m.start()] + block + s[m.start():]) if m else (s.rstrip() + "\n\n" + block)
open(p, 'w', encoding='utf-8').write(s)
PY
echo "已落盘 $OUT"
