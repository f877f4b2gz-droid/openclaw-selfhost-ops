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
#
# 实现约定：
#   - 读写统一走 python 的 json 模块。日志样本里必然带引号、制表符、反斜杠，
#     用 grep/printf 拼 JSON 一定会写出坏行（踩过）。
#   - 文件权限 600（umask 077），样本可能残留主机信息。
# ------------------------------------------------------------
set -u
umask 077
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/ops_lib.sh
. "$SELF_DIR/../lib/ops_lib.sh"

if [ -z "${WORKSPACE:-}" ]; then
  echo "ERROR: 未配置 WORKSPACE（ops.conf 或环境变量，模板见 templates/ops.conf.example）" >&2
  exit 2
fi

DIR="${KB_DIR:-$WORKSPACE/knowledge/log-errors}"
KB="$DIR/kb.jsonl"
PEND="$DIR/pending.tsv"
mkdir -p "$DIR" 2>/dev/null
touch "$KB" "$PEND" 2>/dev/null

cmd="${1:-}"; shift || true
case "$cmd" in
  status)
    python3 - "$KB" "${1:-}" <<'PY'
import json, sys
kb, fp = sys.argv[1], sys.argv[2]
if not fp:
    print('new'); raise SystemExit
try:
    f = open(kb, encoding='utf-8', errors='replace')
except OSError:
    print('new'); raise SystemExit
for line in f:
    try: row = json.loads(line)
    except Exception: continue
    if row.get('fp') == fp:
        print(row.get('status') or 'new'); raise SystemExit
print('new')
PY
    ;;
  get)
    python3 - "$KB" "${1:-}" <<'PY'
import json, sys
kb, fp = sys.argv[1], sys.argv[2]
try:
    f = open(kb, encoding='utf-8', errors='replace')
except OSError:
    raise SystemExit
for line in f:
    try: row = json.loads(line)
    except Exception: continue
    if row.get('fp') == fp:
        print(json.dumps(row, ensure_ascii=False)); raise SystemExit
PY
    ;;
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
    python3 - "$KB" "$fp" "$src" "$sample" "$status" "$cause" "$impact" "$action" "$ref" "$conf" <<'PY'
import json, sys, datetime
kb, fp, src, sample, status, cause, impact, action, ref, conf = sys.argv[1:11]

rows = {}
kept = []
try:
    with open(kb, encoding='utf-8', errors='replace') as f:
        lines = f.readlines()
except OSError:
    lines = []
for line in lines:
    line = line.rstrip('\n')
    if not line:
        continue
    try:
        row = json.loads(line)
    except Exception:
        kept.append(line)      # 坏行原样保留，便于事后修
        continue
    if row.get('fp') != fp:
        kept.append(line)

today = datetime.date.today()
rows = {
    'fp': fp, 'src': src, 'sample': sample, 'first': today.isoformat(),
    'status': status, 'cause': cause, 'impact': impact, 'action': action,
    'ref': ref, 'conf': conf,
    'review': (today + datetime.timedelta(days=180)).isoformat(),
}
with open(kb, 'w', encoding='utf-8') as f:
    for line in kept:
        f.write(line + '\n')
    f.write(json.dumps(rows, ensure_ascii=False) + '\n')
PY
    echo "added $fp ($status)"
    ;;
  *)
    echo "用法: log-error-kb.sh {status|get|list|pending|add} ..." >&2; exit 2 ;;
esac
