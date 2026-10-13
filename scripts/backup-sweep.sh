#!/bin/bash
# ------------------------------------------------------------
# 全盘备份去重：扫本地文件系统里的"备份类"条目，按（所在目录 + 去日期文件名）
# 判定"同一份备份的新旧版本"，每组保留最新 SWEEP_KEEP 份，其余删除。
#
# 识别对象：*.bak / *.orig / *.sql(.gz) / *.dump / *.tar.gz / *.tgz / *.zip
#           / *-backup* 文件，以及 *-YYYYMMDD(或 YYYY-MM-DD) 形式的快照目录。
#
# 用法：backup-sweep.sh [--dry-run] [--apply]
#   默认         只报告"会删哪些"，不动任何文件
#   --dry-run    同上（显式写法）
#   --apply      真删
#   ⚠️ 默认不删是有意的：这个脚本会递归全盘，误判的代价是文件消失。
#
# 配置（ops.conf）：SWEEP_ROOTS SWEEP_KEEP SWEEP_MAXAGE SWEEP_EXCLUDE
# 阈值默认（来自实战）：每组留 3 份；不按龄清理
# ------------------------------------------------------------
set -u

DRY=1
for a in "$@"; do
  case "$a" in
    --apply)   DRY=0 ;;
    --dry-run) DRY=1 ;;
    *) echo "未知参数: $a（支持 --dry-run / --apply）" >&2; exit 2 ;;
  esac
done

CONF="${OPS_CONF:-/etc/openclaw-ops/ops.conf}"
# shellcheck disable=SC1090
[ -f "$CONF" ] && . "$CONF"

# 这个脚本会递归全盘并删文件，所以 WORKSPACE 必填 ——
# 宁可报错停下，也不要因为配置缺失而扫错目录。
: "${WORKSPACE:?未配置 WORKSPACE（见 ops.conf.example）}"
SWEEP_ROOTS="${SWEEP_ROOTS:-/etc /home /opt /srv}"
SWEEP_LOG="${SWEEP_LOG:-$WORKSPACE/logs/backup-sweep.log}"
KEEP="${SWEEP_KEEP:-3}"
MAXAGE="${SWEEP_MAXAGE:-0}"
LOG="$SWEEP_LOG"
TS=$(date '+%F %T')
mkdir -p "$(dirname "$LOG")"
log() { printf '%s  %s\n' "$TS" "$*" >> "$LOG"; }

# 跳过的重目录：依赖、容器、媒体、以及用户追加的 SWEEP_EXCLUDE
PRUNE=( -name node_modules -o -name .git -o -name overlay2 -o -name movie -o -name Photos
        -o -name media -o -name downloads -o -name ebooks -o -name self-backup )
if [ -n "${SWEEP_EXCLUDE:-}" ]; then
  for d in $SWEEP_EXCLUDE; do PRUNE+=( -o -name "$d" ); done
fi

# 备份类文件名（数组保留引号语义）
FILES=( -name '*.bak' -o -name '*.bak.*' -o -name '*.bak-*' -o -name '*_bak*'
        -o -name '*.orig' -o -name '*.orig-*' -o -name '*.save'
        -o -name '*.sql' -o -name '*.sql.gz' -o -name '*.dump'
        -o -name '*.tar.gz' -o -name '*.tgz' -o -name '*.zip' -o -name '*-backup*' )

TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT
# -xdev：不跨文件系统（自动避开网络盘/挂载盘）
# shellcheck disable=SC2086
find $SWEEP_ROOTS -xdev \( "${PRUNE[@]}" \) -prune -o \
  -type f \( "${FILES[@]}" \) -printf '%T@\t%p\n' -o \
  -type d -regextype posix-extended -regex '.*[-_.]20[0-9]{6}([-_.][0-9]{6})?$' -printf '%T@\t%p\n' \
  2>/dev/null > "$TMP"

TOTAL=$(grep -c . "$TMP" || true)

DEL=$(awk -F'\t' -v keep="$KEEP" -v maxage="$MAXAGE" '
function fam(p,  b,a,n){
  n=split(p,a,"/"); b=a[n];
  gsub(/\.(tar\.gz|tgz|sql\.gz|sql|dump|zip|7z|bak|orig|save|old)$/,"",b);
  gsub(/[._-]?20[0-9][0-9][0-9][0-9][0-9][0-9]([-_.][0-9][0-9][0-9][0-9][0-9][0-9])?/,"",b);
  gsub(/[._-]?20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]/,"",b);
  gsub(/[._-]+$/,"",b); return b;
}
{
  mt=$1+0; p=$2; d=p; n=split(p,a,"/"); sub("/"a[n]"$","",d);
  key=d "/" fam(p); C[key]++; A[key SUBSEP C[key]]=mt "\t" p;
}
END{
  now=systime();
  for(k in C){
    n=C[k];
    for(i=1;i<=n;i++) for(j=i+1;j<=n;j++){
      split(A[k SUBSEP i],x,"\t"); split(A[k SUBSEP j],y,"\t");
      if(x[1]+0 < y[1]+0){ t=A[k SUBSEP i]; A[k SUBSEP i]=A[k SUBSEP j]; A[k SUBSEP j]=t; }
    }
    for(i=1;i<=n;i++){
      split(A[k SUBSEP i],z,"\t");
      if(i>keep || (maxage>0 && (now-z[1])/86400 > maxage)) print z[2];
    }
  }
}' "$TMP")

NDEL=$(printf '%s\n' "$DEL" | grep -c . || true)
LBL=$([ "$DRY" = 1 ] && echo "[dry] " || echo "")
log "${LBL}扫描 ${TOTAL} 个备份条目，判出可清理 ${NDEL} 个（KEEP=$KEEP MAXAGE=$MAXAGE）"
printf '%s\n' "$DEL" | while IFS= read -r p; do
  [ -z "$p" ] && continue
  if [ "$DRY" = 1 ]; then log "[dry] 删 $p"; else rm -rf -- "$p" && log "删 $p"; fi
done
printf '%s\n' "$DEL" | grep -v '^$' | head -50
echo "---"
echo "扫描条目 $TOTAL，待清理 $NDEL（$([ "$DRY" = 1 ] && echo 预览 || echo 已清理)）"
exit 0
