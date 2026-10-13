#!/bin/bash
# 全盘备份扫描清理：扫本地文件系统里的“备份类”条目（.bak / .orig / .sql / .dump /
# .tar.gz / .zip / 带日期快照目录等），按（所在目录 + 去日期文件名）判定“同一份备份的
# 新旧版本”，每组保留最新 KEEP 份、删更老的重复；超 MAXAGE 天的一并清理。
#
# 用法：backup-sweep.sh [--dry-run]   --dry-run 只报告“会删哪些”，不实际改动
#
# 需配置（环境变量，或写进 ops.conf；无硬编码真实路径/凭据）：
#   SWEEP_ROOTS     扫描根，空格分隔（默认 "/etc /home /opt /srv"）
#   SWEEP_LOG       日志文件（默认 $WORKSPACE/logs/backup-sweep.log）
#   SWEEP_KEEP      每个“同源”保留最新 N 个（默认 3；0=不限）
#   SWEEP_MAXAGE    超过 N 天删除（默认 0=不按龄）
#   SWEEP_EXCLUDE   额外跳过的目录名，空格分隔（媒体/依赖/容器等）
# 读配置：$OPS_CONF（默认 /etc/openclaw-ops/ops.conf）。
set -u

DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

CONF="${OPS_CONF:-/etc/openclaw-ops/ops.conf}"
[ -f "$CONF" ] && . "$CONF"
: "${WORKSPACE:?未配置 WORKSPACE（见 ops.conf.example）}"
SWEEP_ROOTS="${SWEEP_ROOTS:-/etc /home /opt /srv}"
SWEEP_LOG="${SWEEP_LOG:-$WORKSPACE/logs/backup-sweep.log}"
SWEEP_KEEP="${SWEEP_KEEP:-3}"
SWEEP_MAXAGE="${SWEEP_MAXAGE:-0}"
LOG="$SWEEP_LOG"
TS=$(date '+%F %T'); mkdir -p "$(dirname "$LOG")"
log(){ printf '%s  %s\n' "$TS" "$*" >> "$LOG"; }

read -ra ROOTS <<< "$SWEEP_ROOTS"

# 默认跳过的重目录（媒体/依赖/容器）+ 用户追加
PRUNE=( -name node_modules -o -name .git -o -name .cache -o -name overlay2 )
for x in ${SWEEP_EXCLUDE:-}; do PRUNE+=( -o -name "$x" ); done

# 备份类文件名（数组保留引号语义，避免 glob 被 shell 提前展开）
FILES=( -name '*.bak' -o -name '*.bak.*' -o -name '*.bak-*' -o -name '*_bak*'
        -o -name '*.orig' -o -name '*.orig-*' -o -name '*.save'
        -o -name '*.sql' -o -name '*.sql.gz' -o -name '*.dump'
        -o -name '*.tar.gz' -o -name '*.tgz' -o -name '*.zip' -o -name '*-backup*' )

TMP=$(mktemp)
# -xdev：不跨文件系统（自动避开网络盘/挂载盘）
find "${ROOTS[@]}" -xdev \( "${PRUNE[@]}" \) -prune -o \
  -type f \( "${FILES[@]}" \) -printf '%T@\t%p\n' -o \
  -type d -regextype posix-extended -regex '.*[-_.]20[0-9]{6}([-_.][0-9]{6})?$' -printf '%T@\t%p\n' \
  2>/dev/null > "$TMP"

TOTAL=$(grep -c . "$TMP")
# 判重：同目录 + 去日期文件名 = 同一份；保留最新 KEEP，其余输出
DEL=$(awk -F'\t' -v keep="$SWEEP_KEEP" -v maxage="$SWEEP_MAXAGE" '
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
rm -f "$TMP"

NDEL=$(printf '%s\n' "$DEL" | grep -c . )
LBL=$([ "$DRY" = 1 ] && echo "[dry] " || echo "")
log "${LBL}扫描 ${TOTAL} 个备份条目，可清理 ${NDEL} 个（KEEP=$SWEEP_KEEP MAXAGE=$SWEEP_MAXAGE）"
printf '%s\n' "$DEL" | while IFS= read -r p; do
  [ -z "$p" ] && continue
  if [ "$DRY" = 1 ]; then log "[dry] 删 $p"; else rm -rf -- "$p" && log "删 $p"; fi
done
printf '%s\n' "$DEL" | grep -v '^$' | head -50
echo "---"
echo "扫描条目 $TOTAL，可清理 $NDEL（$([ "$DRY" = 1 ] && echo 预览 || echo 已清理)）"
exit 0
