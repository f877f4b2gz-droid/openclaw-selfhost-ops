#!/bin/bash
# ------------------------------------------------------------
# model-guard.sh — 模型费用守卫
#
# 检查四件事，任何一项异常即告警（退出码 1）：
#   1) 主模型是否还走免费容器（防止悄悄切到付费通道）
#   2) 免费容器是否可达
#   3) 付费余额是否低于下限
#   4) 是否有会话/定时任务钉在付费模型上
# 另外按「余额 24h 跌幅」估算实付花费，超阈值告警。
#
# 用法：model-guard.sh [--notify] [--dry-run]
# 退出码：0 正常 / 1 有告警 / 2 配置缺失
#
# 设计要点（踩过的坑）：
#   - 告警去重靠 wk_notify 的冷却文件；冷却文件所在目录必须可写，
#     否则冷却不生效，会每轮重复推送。本脚本启动时自检并修复。
#   - 24h 花费从「切换免费模型之后」的样本起算，历史账不反复告警。
# ------------------------------------------------------------
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/ops_lib.sh
. "$SELF_DIR/../lib/ops_lib.sh"

DRY_RUN=0
NOTIFY=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY_RUN=1 ;;
    --notify)  NOTIFY=1 ;;
  esac
done

WS="${WORKSPACE:-$PWD}"
CFG="${OPENCLAW_CFG:-$OPENCLAW_HOME/openclaw.json}"
FREE_PROVIDER="${FREE_PROVIDER:-free-models}"
PAID_PROVIDER="${PAID_PROVIDER:-}"
PAID_BALANCE_URL="${PAID_BALANCE_URL:-}"
BALANCE_MIN="${BALANCE_MIN:-10}"
DAILY_MIN="${DAILY_MIN:-10}"

[ -r "$CFG" ] || { echo "读不到配置：$CFG" >&2; exit 2; }

# 配置无法解析时必须立刻停：否则下游会拿空值继续判断，
# 报出「主模型已不在免费容器（现: ）」这种误导性结论
if ! python3 -c "import json,sys;json.load(open(sys.argv[1]))" "$CFG" 2>/dev/null; then
  echo "配置无法解析（JSON 语法错误）：$CFG" >&2
  exit 2
fi

ALERT=0; MSGS=""
say(){ printf '%s\n' "$*"; }

# 冷却目录自检：不可写时 wk_notify 每轮都会重发
COOL_DIR="${HOME:-/tmp}/.local/state/openclaw-ops/notify"
[ -d "$COOL_DIR" ] || mkdir -p "$COOL_DIR" 2>/dev/null || true
[ -w "$COOL_DIR" ] || say "警告: 告警冷却目录不可写（$COOL_DIR），可能重复推送"

# ---- 1) 主模型与 provider ----
read -r PRIMARY PROVIDER < <(python3 - "$CFG" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
m=d.get('agents',{}).get('defaults',{}).get('model') or d.get('model') or ''
if isinstance(m,dict): m=m.get('primary') or m.get('id') or ''
print(m, (m.split('/')[0] if m else ''))
PY
)
PRIMARY="${PRIMARY:-}"; PROVIDER="${PROVIDER:-}"
say "主模型: ${PRIMARY:-未设}  provider: ${PROVIDER:-未知}"

if [ "$PROVIDER" = "$FREE_PROVIDER" ]; then
  say "状态: 走免费容器 ✅"
else
  say "状态: ⚠️ 不是免费容器（$PROVIDER）"
  ALERT=1; MSGS="${MSGS}主模型已不在免费容器（现: $PRIMARY）；"
fi

# ---- 2) 免费容器可达性 ----
read -r BASE FKEY < <(python3 - "$CFG" "$FREE_PROVIDER" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
p=d.get('models',{}).get('providers',{}).get(sys.argv[2],{}) or {}
print(p.get('baseUrl',''), p.get('apiKey') or p.get('api_key') or '')
PY
)
BASE="${BASE:-}"; FKEY="${FKEY:-}"
# 令牌不进命令行：/proc/<pid>/cmdline 对其他用户可读，-H 直接传会让密钥暴露
mk_header(){ local f; f=$(umask 077; mktemp) || return 1; printf 'Authorization: Bearer %s\n' "$1" > "$f"; printf '%s' "$f"; }

if [ -n "$BASE" ]; then
  HF=$(mk_header "$FKEY") && CODE=$(curl -s -o /dev/null -w '%{http_code}' -m 8 "$BASE/models" -H "@$HF" 2>/dev/null)
  [ -n "${HF:-}" ] && rm -f "$HF"
  CODE="${CODE:-000}"
  say "免费容器: $BASE → HTTP $CODE"
  [ "$CODE" != "200" ] && { ALERT=1; MSGS="${MSGS}免费容器不可达(HTTP $CODE)；"; }
else
  say "免费容器: 未配置 baseUrl，跳过可达性检查"
fi

# ---- 3) 付费余额 ----
LEFT="unknown"
if [ -n "$PAID_PROVIDER" ] && [ -n "$PAID_BALANCE_URL" ]; then
  DKEY=$(python3 - "$CFG" "$PAID_PROVIDER" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
p=d.get('models',{}).get('providers',{}).get(sys.argv[2],{}) or {}
print(p.get('apiKey') or p.get('api_key') or '')
PY
)
  if [ -n "$DKEY" ]; then
    B=""
    for _ in 1 2 3; do
      HF=$(mk_header "$DKEY") && B=$(curl -s -m 12 "$PAID_BALANCE_URL" -H "@$HF" 2>/dev/null)
      [ -n "${HF:-}" ] && rm -f "$HF"
      printf '%s' "$B" | grep -q total_balance && break
      sleep 2
    done
    LEFT=$(printf '%s' "$B" | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin); infos=d.get('balance_infos') or []
    print(infos[0]['total_balance'] if infos else 'unknown')
except Exception: print('unknown')" 2>/dev/null)
    say "付费余额: $LEFT"
    case "$LEFT" in
      unknown) say "余额查询失败（已重试 3 次，不计告警）" ;;
      *) awk -v a="$LEFT" -v b="$BALANCE_MIN" 'BEGIN{exit !(a<b)}' && {
           ALERT=1; MSGS="${MSGS}付费余额 $LEFT < $BALANCE_MIN；"; } ;;
    esac
  fi
else
  say "付费余额: 未配置，跳过"
fi

# ---- 4) 钉在付费模型上的活跃会话 ----
PAID="$(python3 - "$CFG" <<'PY'
import json,sys,os
d=json.load(open(sys.argv[1]))
provs=d.get('models',{}).get('providers') or {}
paid={k for k,v in provs.items() if any((m.get('cost') or {}).get('input') for m in (v.get('models') or []))}
base=os.path.dirname(os.path.abspath(sys.argv[1]))
f=os.path.join(base,'agents','main','sessions','sessions.json')
try: sess=json.load(open(f,encoding='utf-8'))
except Exception: sess={}
import time
now=time.time(); hits=[]
for k,v in sess.items():
    if not isinstance(v,dict): continue
    try: last=int(v.get('lastInteractionAt') or v.get('updatedAt') or 0)/1000
    except Exception: last=0
    if now-last > 3600: continue          # 只看最近 1 小时还在动的
    pv=v.get('providerOverride') or v.get('provider')
    mv=v.get('modelOverride') or v.get('model')
    if pv in paid or (isinstance(mv,str) and mv.split('/')[0] in paid):
        hits.append(k)
print(",".join(hits[:5]) + (f" 等{len(hits)}个" if len(hits)>5 else ""))
PY
)"
if [ -n "$PAID" ]; then
  say "付费会话: ⚠️ $PAID"; ALERT=1; MSGS="${MSGS}有会话钉在付费模型：$PAID；"
else
  say "付费会话: 无 ✅"
fi

# ---- 5) 24h 实付花费（余额跌幅）----
HB="$WS/state/balance-history.json"
DROP="$(python3 - "$HB" "${LEFT:-unknown}" <<'PY'
import json,sys,time,os
f,cur=sys.argv[1],sys.argv[2]
try: cur=float(cur)
except Exception: print("unknown"); raise SystemExit
os.makedirs(os.path.dirname(f) or '.',exist_ok=True)
try: hist=json.load(open(f,encoding='utf-8'))
except Exception: hist=[]
now=time.time()
hist=[h for h in hist if now-h.get('t',0) < 8*86400]
hist.append({'t':now,'balance':cur})
json.dump(hist,open(f,'w',encoding='utf-8'))
old=[h for h in hist if now-h['t']<=86400]
since=0
try: since=float(json.load(open(os.path.join(os.path.dirname(f),'free-since.json'),encoding='utf-8')).get('since',0))
except Exception: pass
if since: old=[h for h in old if h['t']>=since]
base=old[0]['balance'] if old else cur
print(round(base-cur,2))
PY
)"
say "24h 花费: ${DROP:-unknown} 元（阈值 $DAILY_MIN）"
case "$DROP" in
  unknown|"") : ;;
  *) awk -v a="${DROP#-}" -v b="$DAILY_MIN" 'BEGIN{exit !(a>b)}' && {
       ALERT=1; MSGS="${MSGS}24h 花费 ${DROP} 元超阈值；"; } ;;
esac

if [ "$ALERT" -eq 1 ]; then
  say "结论: ⚠️ $MSGS"
  if [ "$NOTIFY" -eq 1 ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
      echo "[dry-run] 将推送：$MSGS"
    else
      wk_notify warn model-guard "模型费用守卫：$MSGS"
    fi
  fi
  exit 1
fi
say "结论: 正常（免费容器在用，余额充足）"
exit 0
