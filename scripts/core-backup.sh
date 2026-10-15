#!/bin/bash
# ------------------------------------------------------------
# 核心备份 —— 三级：① core 快速回滚包  ② 每日增量快照  ③ 每周加密包（可选上云）
#
# ① core：把配置/脚本/定时表/工作区打成 tar.gz，用于"改坏了立刻回滚"
# ② 每日：rsync --link-dest 快照（外观全量、实际只占差异），保留 SELF_BACKUP_KEEP 份
# ③ 每周（周日）：恢复集 tar.zst → gpg 对称加密 → 本机 + 云端各留 WEEKLY_KEEP 份
#
# 用法：core-backup.sh [--dry-run]
#
# 配置（ops.conf）：
#   必填  WORKSPACE
#   选填  OPENCLAW_HOME BACKUP_ROOT ALERT_CMD LOG_DIR
#         SELF_BACKUP_ROOT（留空=跳过②③） CLOUD_DEST（留空=跳过云） ENC_PASSFILE（留空=不加密）
#   阈值  CORE_BACKUP_KEEP SELF_BACKUP_KEEP WEEKLY_KEEP
#
# 安全：加密口令从 ENC_PASSFILE 读（应 0600），**绝不入包**；
#       云端大小不符即视为失败并告警（避免"以为传上去了"）。
# ------------------------------------------------------------
set -u

DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

CONF="${OPS_CONF:-/etc/openclaw-ops/ops.conf}"
# shellcheck disable=SC1090
[ -f "$CONF" ] && . "$CONF"

: "${WORKSPACE:?未配置 WORKSPACE（见 ops.conf.example）}"
: "${OPENCLAW_HOME:=$HOME/.openclaw}"
: "${BACKUP_ROOT:=$WORKSPACE/backup}"
: "${CORE_BACKUP_KEEP:=30}"
: "${SELF_BACKUP_KEEP:=30}"
: "${WEEKLY_KEEP:=8}"
: "${ALERT_CMD:=}"
: "${SELF_BACKUP_ROOT:=}"
: "${CLOUD_DEST:=}"
: "${ENC_PASSFILE:=}"
# 备份要纳入的系统级路径（除工作区与助手目录外）；按需删改
: "${CORE_BACKUP_SRC:=/usr/local/bin /etc/cron.d}"

NOW=$(date +%Y%m%d_%H%M%S)
DAY=$(date +%F)
DOW=$(date +%u)
LOG="${LOG_DIR:-/var/log}/self-backup.log"

log() { printf '%s  %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG"; }
fail() {
  log "FAIL: $*"
  [ -n "$ALERT_CMD" ] && $ALERT_CMD "[自备份] $*"
  return 0
}

if [ "$DRY" = 1 ]; then
  echo "[dry-run] 配置=$CONF"
  echo "  core 包      → $BACKUP_ROOT/core/core_$NOW.tar.gz（保留 $CORE_BACKUP_KEEP 份）"
  echo "  快照根       → ${SELF_BACKUP_ROOT:-<未配置，跳过②③>}"
  echo "  云落点       → ${CLOUD_DEST:-<未配置，跳过云>}"
  echo "  加密口令文件 → ${ENC_PASSFILE:-<未配置，不加密>}"
  echo "[dry-run] 结束：无任何改动。"
  exit 0
fi

# ===== ① core：快速回滚包 =====
DST="$BACKUP_ROOT/core"
mkdir -p "$DST"
SRC=( $CORE_BACKUP_SRC "$WORKSPACE" "$OPENCLAW_HOME" )
EXC_ARGS=(
  "--exclude=$OPENCLAW_HOME/logs"
  "--exclude=$OPENCLAW_HOME/media"
  "--exclude=$OPENCLAW_HOME/npm"
  "--exclude=$OPENCLAW_HOME/browser"
  "--exclude=$OPENCLAW_HOME/agents/main/sessions"
  "--exclude=$OPENCLAW_HOME/delivery-queue"
  "--exclude=$OPENCLAW_HOME/session-delivery-queue"
  "--exclude=$WORKSPACE/plugins"
  "--exclude=$WORKSPACE/logs"
)
tar --ignore-failed-read -czf "$DST/core_$NOW.tar.gz" "${EXC_ARGS[@]}" "${SRC[@]}" 2>"$DST/.tar.err"
RET=$?
# 只把"读不了/打开失败"当问题：单个文件权限不足不该让整份备份作废，但要报出来
SKIPPED=$(grep -cE 'Cannot open|Permission denied|Cannot stat' "$DST/.tar.err" 2>/dev/null || true)
SKIPPED=${SKIPPED:-0}
rm -f "$DST/.tar.err"
ls -t "$DST"/core_*.tar.gz 2>/dev/null | tail -n +$((CORE_BACKUP_KEEP + 1)) | xargs -r rm -f
if [ $RET -ne 0 ]; then
  fail "core-backup 失败（tar exit=$RET）$NOW"
elif [ "$SKIPPED" -gt 0 ]; then
  log "core OK（有 $SKIPPED 个条目读不了已跳过；以 root 跑可避免）→ core_$NOW.tar.gz（$(du -h "$DST/core_$NOW.tar.gz" 2>/dev/null | cut -f1)，保留 $CORE_BACKUP_KEEP 份）"
else
  log "core OK → core_$NOW.tar.gz（$(du -h "$DST/core_$NOW.tar.gz" 2>/dev/null | cut -f1)，保留 $CORE_BACKUP_KEEP 份）"
fi

# ②③ 需要第二份存储；没配就到此为止
if [ -z "$SELF_BACKUP_ROOT" ]; then
  log "未配置 SELF_BACKUP_ROOT，跳过每日快照与每周加密包"
  exit 0
fi

SB="$SELF_BACKUP_ROOT"
SRCS=( "$WORKSPACE" "$OPENCLAW_HOME" $CORE_BACKUP_SRC )
EXC=( --exclude=logs/ --exclude=npm/ --exclude=browser/ --exclude=media/
      --exclude=delivery-queue/ --exclude=session-delivery-queue/
      --exclude=plugins/ --exclude=.local/ --exclude=.cache/
      --exclude='restart-sentinel*.tmp' )

# ===== ② 每日 link-dest 快照 =====
if mountpoint -q "$SB"; then
  mkdir -p "$SB/daily"
  prev=$(ls -1dt "$SB"/daily/*/ 2>/dev/null | head -1)
  LD=""
  [ -n "$prev" ] && LD="--link-dest=$prev"
  if rsync -a --delete --relative $LD "${EXC[@]}" "${SRCS[@]}" "$SB/daily/$DAY/" 2>>"$LOG"; then
    log "自备份-每日 OK → $SB/daily/$DAY （$(du -sh "$SB/daily/$DAY" 2>/dev/null | cut -f1)）"
    ls -1dt "$SB"/daily/*/ 2>/dev/null | tail -n +$((SELF_BACKUP_KEEP + 1)) | xargs -r rm -rf
  else
    fail "自备份-每日 rsync 失败"
  fi
else
  fail "第二存储未挂载（$SB），跳过每日快照"
fi

# ===== ③ 每周（周日）加密包 → 本机 + 云 =====
if [ "$DOW" = 7 ]; then
  mkdir -p "$SB/weekly"
  PKG="openclaw-$NOW.tar.zst"
  tar -C / --exclude='*/logs/*' --exclude='*/npm/*' --exclude='*/browser/*' --exclude='*/media/*' \
      --exclude='*/plugins/*' --exclude='*/.venv/*' --exclude='*/delivery-queue/*' \
      --exclude='*/.local/*' --exclude='*/.cache/*' --exclude='*/restart-sentinel*.tmp' \
      --use-compress-program='zstd -19 -T0' -cf "/tmp/$PKG" "${SRCS[@]}" 2>/dev/null

  if [ ! -s "/tmp/$PKG" ]; then
    fail "每周包生成失败"
  elif [ -z "$ENC_PASSFILE" ] || [ ! -f "$ENC_PASSFILE" ]; then
    fail "缺加密口令文件（$ENC_PASSFILE），未加密；包留 /tmp/$PKG"
  elif gpg --batch --yes --symmetric --cipher-algo AES256 --passphrase-file "$ENC_PASSFILE" \
        -o "$SB/weekly/$PKG.gpg" "/tmp/$PKG" 2>>"$LOG"; then
    log "每周加密包 → $SB/weekly/$PKG.gpg （$(du -h "$SB/weekly/$PKG.gpg" | cut -f1)）"
    if [ -n "$CLOUD_DEST" ]; then
      if [ -d "$CLOUD_DEST" ]; then
        mkdir -p "$CLOUD_DEST"
        if cp -f "$SB/weekly/$PKG.gpg" "$CLOUD_DEST/" && sync; then
          s1=$(stat -c%s "$SB/weekly/$PKG.gpg" 2>/dev/null || echo 0)
          s2=$(stat -c%s "$CLOUD_DEST/$PKG.gpg" 2>/dev/null || echo 0)
          if [ "$s1" = "$s2" ]; then
            log "云上传 OK（校验 $s2 B）→ $CLOUD_DEST/$PKG.gpg"
            ls -1t "$CLOUD_DEST"/*.gpg 2>/dev/null | tail -n +$((WEEKLY_KEEP + 1)) | xargs -r rm -f
          else
            fail "云上传大小不符：本地 $s1 / 云 $s2"
          fi
        else
          fail "云上传失败"
        fi
      else
        fail "云落点不存在（$CLOUD_DEST），云上传跳过"
      fi
    fi
    ls -1t "$SB"/weekly/*.gpg 2>/dev/null | tail -n +$((WEEKLY_KEEP + 1)) | xargs -r rm -f
  else
    fail "gpg 加密失败"
  fi
  rm -f "/tmp/$PKG"
fi

exit 0
