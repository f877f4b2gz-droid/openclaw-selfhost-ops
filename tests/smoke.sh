#!/bin/bash
# ------------------------------------------------------------
# tests/smoke.sh — 冒烟测试：不依赖真实环境，用临时目录跑一遍核心逻辑
#
# 用法：bash tests/smoke.sh [-v]
# 退出码：0 全部通过 / 1 有失败
# ------------------------------------------------------------
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERBOSE=0
[ "${1:-}" = "-v" ] && VERBOSE=1

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); [ "$VERBOSE" = 1 ] && printf '  PASS %s\n' "$1"; return 0; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }

cat > "$TMP/ops.conf" <<EOF
WORKSPACE="$TMP/ws"
OPENCLAW_HOME="$TMP/ws/.openclaw"
LOG_DIR="$TMP/logs"
KB_DIR="$TMP/ws/knowledge/log-errors"
INSPECT_MOUNTS="/"
SMART_DISKS=""
INSPECT_SERVICES=""
INSPECT_PORTS=""
INSPECT_PROCS=""
INSPECT_NOTIFY_CMD=""
LOG_SCAN_DIRS="$TMP/logs"
EOF
mkdir -p "$TMP/ws/state" "$TMP/logs/app"
export OPS_CONF="$TMP/ops.conf"

echo "== 1. 指纹归一化 =="
a=$(printf '2026-10-23T10:00:00 host app: conn refused to 10.0.0.5:5432\n' | "$ROOT/scripts/log-fingerprint.sh" | cut -f1)
b=$(printf '2026-10-24T11:11:11 host app: conn refused to 10.9.9.9:5432\n' | "$ROOT/scripts/log-fingerprint.sh" | cut -f1)
c=$(printf '2026-10-23T10:00:00 host app: disk read error\n' | "$ROOT/scripts/log-fingerprint.sh" | cut -f1)
[ -n "$a" ] && [ "$a" = "$b" ] && ok "同类错误同指纹" || no "同类错误同指纹（$a vs $b）"
[ "$a" != "$c" ] && ok "不同错误不同指纹" || no "不同错误不同指纹"
printf 'x token=SECRETVALUE12345 failed\n' | "$ROOT/scripts/log-fingerprint.sh" | grep -q 'SECRETVALUE' \
  && no "令牌必须脱敏" || ok "令牌必须脱敏"

echo "== 2. 知识库 =="
"$ROOT/scripts/log-error-kb.sh" add --fp f1 --src a.log --status known-harmless --sample 'msg="x"	y' >/dev/null
[ "$("$ROOT/scripts/log-error-kb.sh" status f1)" = "known-harmless" ] && ok "登记后可查" || no "登记后可查"
"$ROOT/scripts/log-error-kb.sh" add --fp f1 --src a.log --status known-manual >/dev/null
[ "$("$ROOT/scripts/log-error-kb.sh" status f1)" = "known-manual" ] && ok "同指纹覆盖" || no "同指纹覆盖"
[ "$(wc -l < "$TMP/ws/knowledge/log-errors/kb.jsonl")" = "1" ] && ok "覆盖不堆积" || no "覆盖不堆积"
python3 -c "import json,sys;[json.loads(l) for l in open(sys.argv[1])]" "$TMP/ws/knowledge/log-errors/kb.jsonl" 2>/dev/null \
  && ok "JSON 合法（含引号/制表符样本）" || no "JSON 合法"
[ "$(stat -c '%a' "$TMP/ws/knowledge/log-errors/kb.jsonl")" = "600" ] && ok "知识库权限 600" || no "知识库权限 600"

echo "== 3. 检查点 =="
"$ROOT/scripts/checkpoint.sh" "做完 A" "在做 B" "待做 C" >/dev/null
"$ROOT/scripts/checkpoint.sh" --last | grep -q "待做：待做 C" && ok "落盘并可回读" || no "落盘并可回读"

echo "== 4. 巡检 =="
printf '2026-10-23T10:00:00 level=error msg="db down"\n2026-10-23T10:01:00 level=error msg="db down"\n' > "$TMP/logs/app/error.log"
out=$("$ROOT/scripts/inspect-daily.sh" --dry 2>/dev/null)
printf '%s' "$out" | grep -q "报错分类: 新1" && ok "两条同类错误折成一条" || no "两条同类错误折成一条"
fp=$(printf '2026-10-23T10:00:00 level=error msg="db down"\n' | "$ROOT/scripts/log-fingerprint.sh" | cut -f1)
"$ROOT/scripts/log-error-kb.sh" add --fp "$fp" --src app/error.log --status known-harmless >/dev/null
out2=$("$ROOT/scripts/inspect-daily.sh" --dry 2>/dev/null)
printf '%s' "$out2" | grep -q "报错分类: 新0" && ok "已登记后不再算新" || no "已登记后不再算新"

echo "== 5. 非法输入 =="
"$ROOT/scripts/log-error-kb.sh" add --fp f9 --src a.log --status known-harless >/dev/null 2>&1
[ $? -eq 2 ] && ok "状态写错被拒（退出码 2）" || no "状态写错被拒"
"$ROOT/scripts/log-error-kb.sh" status f9 | grep -q '^new$' && ok "非法状态不入库" || no "非法状态不入库"

echo "== 6. 缺配置的报错 =="
env -u WORKSPACE OPS_CONF=/nonexistent "$ROOT/scripts/checkpoint.sh" >/dev/null 2>&1
[ $? -eq 2 ] && ok "配置缺失退出码 2" || no "配置缺失退出码 2"

echo
echo "结果：PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
