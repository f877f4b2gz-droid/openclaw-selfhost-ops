#!/bin/bash
# ------------------------------------------------------------
# exp-scan.sh — 经验库反馈闭环扫描
#
# 用途：离线扫描经验沉淀三源（经验库 / 踩坑总表 / 报错知识库 kb.jsonl），
#       以 Jaccard 相似度聚类出"重复踩坑"、以关键词命中"可复用模式"，
#       产出候选追加至 scan/queue.md（状态=待处理）；队列上限 50 条，
#       待处理超 30 天标"过期"，超限的最老过期条目归档。
#       通知仅推送摘要与队列指针（对接统一推送入口，缺失时打印终端）。
#
# 用法：exp-scan.sh [--dry-run] [--force]
#   --dry-run  只打印候选，不写队列、不发通知、不更新状态
#   --force    忽略节流，立即执行
#
# 默认节流：距上次运行 ≥7 天，或新增候选 ≥5 条 → 执行（先到为准）
# 配置（ops.conf）：WORKSPACE  WK_STATE_DIR
# 状态：${WK_STATE_DIR:-/var/lib/exp-scan}/last_run
# ------------------------------------------------------------
set -u
source "$(dirname "${BASH_SOURCE[0]}")/../lib/ops_lib.sh"
WK_NAME=exp-scan

ops_require_ws
SCAN_DIR="$WS/scan"
QUEUE="$SCAN_DIR/queue.md"
ARCHIVE="$SCAN_DIR/queue-archive.md"
STATE_DIR="${WK_STATE_DIR:-/var/lib/exp-scan}"
DRY=0; FORCE=0
for arg in "$@"; do case "$arg" in --dry-run) DRY=1;; --force) FORCE=1;; esac; done
mkdir -p "$SCAN_DIR" "$STATE_DIR" 2>/dev/null || { wk_log "无法建目录"; exit 1; }

export WS DRY QUEUE ARCHIVE STATE_DIR FORCE
out=$(python3 - "$@" <<'PY'
import os,re,json,sys
WS=os.environ['WS']; DRY=os.environ['DRY']=='1'; FORCE=os.environ['FORCE']=='1'
QUEUE=os.environ['QUEUE']; ARCHIVE=os.environ['ARCHIVE']; SD=os.environ['STATE_DIR']
import datetime
TODAY=datetime.date.today().isoformat()

# ---- 1. 读取三源 ----
items=[]  # (来源, 文本)
p=os.path.join(WS,'docs','经验库.md')
if os.path.exists(p):
    for line in open(p,encoding='utf-8'):
        m=re.match(r'\s*(\d+)\.\s+(.+)',line)
        if m: items.append((f"docs/经验库.md#{m.group(1)}",m.group(2).strip()))
p=os.path.join(WS,'docs','踩坑总表.md')
if os.path.exists(p):
    stack={}
    for line in open(p,encoding='utf-8'):
        m=re.match(r'\s*-\s*\*\*(现象|根因|修法)\*\*：(.*)',line)
        if m:
            if m.group(1)=='现象':
                if stack.get('现象'): items.append(("docs/踩坑总表.md",stack['现象']))
                stack={'现象':m.group(2).strip()}
    if stack.get('现象'): items.append(("docs/踩坑总表.md",stack['现象']))
p=os.path.join(WS,'knowledge','log-errors','kb.jsonl')
if os.path.exists(p):
    for line in open(p,encoding='utf-8'):
        try: o=json.loads(line)
        except Exception: continue
        if o.get('cause'): items.append((f"kb:{o.get('fp','?')}",o['cause'].strip()))

# ---- 2. 指纹聚类（重复坑）+ 关键词（好用法） ----
def toks(s):
    s=s.lower()
    w=set(re.findall(r'[a-z0-9_.\-]{2,}',s))
    cj=re.findall(r'[\u4e00-\u9fff]',s)
    w|=set(''.join(cj[i:i+2]) for i in range(len(cj)-1))
    return w
def jac(a,b):
    if not a or not b: return 0
    return len(a&b)/len(a|b)
def norm(s): return re.sub(r'[\s`*_：:（）()【】\[\]，,。.\-]+','',s.lower())
def short(s,n=70): return s if len(s)<=n else s[:n]+'…'

T=[(src,txt,toks(txt)) for src,txt in items if len(txt)>=8]
N=len(T); used=[False]*N; dup=[]
for i in range(N):
    if used[i]: continue
    grp=[i]
    for j in range(i+1,N):
        if not used[j] and jac(T[i][2],T[j][2])>=0.5: grp.append(j); used[j]=True
    if len(grp)>=2:
        used[i]=True
        base=min((T[k][1] for k in grp),key=len)
        refs=','.join(sorted({T[k][0] for k in grp}))
        dup.append(("重复坑",short(base),refs,f"×{len(grp)}"))

KW=re.compile(r'复用|统一|抽象|封装|通用|模板|提纯|单一入口|套路|模式化|公共库')
good=[]
for src,txt,_ in T:
    if KW.search(txt): good.append(("好用法",short(txt),src,""))
seen=set()
cands=[]
for kind,summ,refs,extra in dup+good:
    key=norm(summ)
    if key in seen: continue
    seen.add(key); cands.append((kind,summ,refs,extra))

# ---- 3. 队列读写 ----
def parse_queue(fp):
    rows=[]
    if os.path.exists(fp):
        for line in open(fp,encoding='utf-8'):
            s=line.strip()
            if not s.startswith('|'): continue
            c=[x.strip() for x in s.strip('|').split('|')]
            if len(c)<5 or c[0] in ('编号',) or set(''.join(c))<=set('-: '): continue
            rows.append(c)
    return rows
q=parse_queue(QUEUE)
existing={norm(r[2]) for r in q}
news=[]
nid=max([int(r[0]) for r in q if r[0].isdigit()] or [0])
for kind,summ,refs,extra in cands:
    if norm(summ) in existing: continue
    nid+=1
    news.append([str(nid),kind,summ,'待处理',TODAY])
    existing.add(norm(summ))

# ---- 4. 节流（默认模式）----
lr=os.path.join(SD,'last_run'); last=None
if os.path.exists(lr):
    try: last=datetime.date.fromisoformat(open(lr).read().strip())
    except Exception: pass
due=(last is None) or ((datetime.date.today()-last).days>=7) or (len(news)>=5)
if not FORCE and not DRY and not due:
    print(f"节流：未到（上次 {last}，新增 {len(news)} 条 <5）；跳过。")
    sys.exit(0)

# ---- 5. 队列维护：30天没动→过期；满50→最老过期条目归档 ----
for r in q:
    if r[3]=='待处理':
        try:
            d=datetime.date.fromisoformat(r[4])
            if (datetime.date.today()-d).days>=30: r[3]='过期'
        except Exception: pass
allrows=q+news
arch=[]
while len(allrows)>50:
    exp=[r for r in allrows if r[3]=='过期']
    if not exp: break
    victim=min(exp,key=lambda r:r[4])
    allrows.remove(victim); arch.append(victim)

def emit(rows,title):
    out=[title,"",f"| 编号 | 来源 | 摘要 | 状态 | 日期 |","|---|---|---|---|---|"]
    for r in rows: out.append("| "+" | ".join(x.replace('|','/') for x in r)+" |")
    out.append(""); out.append("<!-- machine: 编号\t来源\t摘要\t状态\t日期 -->")
    for r in rows: out.append("<!-- machine: "+"\t".join(r)+" -->")
    return "\n".join(out)+"\n"

# ---- 6. 输出/落盘 ----
print(f"扫描源 {len(items)} 条 → 候选 {len(cands)}（重复坑 {len([c for c in cands if c[0]=='重复坑'])} / 好用法 {len([c for c in cands if c[0]=='好用法'])}）；新增 {len(news)}；队列 {len(allrows)} 条")
for r in news[:10]: print("  + ["+r[0]+"] "+r[1]+"："+r[2])
if arch: print(f"  归档 {len(arch)} 条 → queue-archive.md")

if DRY:
    print("dry-run：未写 queue.md、未发通知、未更新状态。")
    sys.exit(0)
open(QUEUE,'w',encoding='utf-8').write(emit(allrows,"# 经验队列\n\n由 `exp-scan.sh` 维护；状态：待处理/已采纳/已忽略/过期。上限 50，待处理超 30 天标过期。"))
if arch:
    prev=open(ARCHIVE,encoding='utf-8').read() if os.path.exists(ARCHIVE) else "# 经验库扫描队列 · 归档\n"
    open(ARCHIVE,'w',encoding='utf-8').write(prev+"\n"+emit(arch,"## "+TODAY+" 归档"))
open(lr,'w').write(TODAY)

# ---- 7. 通知（摘要+指针）----
pend=[r for r in allrows if r[3]=='待处理']
if pend and news:
    msg=f"exp-scan：{len(pend)} 条待处理\n"
    for i,r in enumerate(pend[:5],1): msg+=f"{i}. {short(r[2],50)}\n"
    msg+=f"详情见队列文件：{QUEUE}"
    print("NOTIFY>>>"+msg)
PY
)
printf '%s\n' "$out" | grep -v '^NOTIFY>>>' || true
if [ "${EXP_NO_NOTIFY:-0}" != "1" ] && [ "$DRY" -eq 0 ] && printf '%s\n' "$out" | grep -q '^NOTIFY>>>'; then
  msg=$(printf '%s\n' "$out" | sed -n 's/^NOTIFY>>>//p')
  if [ -x /usr/local/bin/qq-send.sh ]; then
    /usr/local/bin/qq-send.sh --key exp-scan-weekly "$msg" && wk_log "已推 qq-send" || wk_log "qq-send 失败"
  else
    echo "WARN: 未找到 /usr/local/bin/qq-send.sh，通知打印到终端：$msg" >&2
  fi
fi
