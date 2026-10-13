#!/bin/bash
# ------------------------------------------------------------
# 统一清理：服务日志截断 + 会话残留 + 手工备份瘦身 + 附件/媒体 + 日志压缩
#
# 每一步独立，任一步失败不影响其他步骤（清理任务不该因为一步报错就整体停摆）。
#
# 用法：log-rotate.sh [--dry-run] [--media-only]
#   --media-only  只跑「附件/媒体清理」与「日志压缩」两节（适合高频跑，如每 30 分钟）
#   --dry-run     只报告"会动哪些文件"，不实际改动（自动蕴含 --media-only）
#
# 配置（ops.conf）：WORKSPACE OPENCLAW_HOME LOG_DIR ROTATE_LOGS
#   MEDIA_DIR MEDIA_VOICE_MIN MEDIA_IMG_DAYS TMP_KEEP_DAYS
#   OCLOG_DIR OCLOG_ARCHIVE_DAYS OCLOG_BUSY_HOURS
#   LOG_SERVICE_MAX LOG_SERVICE_KEEP_LINES SESS_KEEP_DAYS WS_BAK_KEEP
#   SYSDISK_CLEAN（留空=跳过系统盘清理这一节）
#
# 阈值默认（来自实战）：服务日志 50MB；会话残留 7 天；手工备份每类留 1 份；
#                       语音转文字后 60 分钟内删；其他附件 7 天；归档 14 天
# ------------------------------------------------------------
set -u

MEDIA_ONLY=0
DRY=0
for a in "$@"; do
  case "$a" in
    --media-only) MEDIA_ONLY=1 ;;
    --dry-run)    DRY=1 ;;
    -h|--help)    sed -n '2,20p' "$0"; exit 0 ;;
  esac
done
[ "$DRY" = 1 ] && MEDIA_ONLY=1

CONF="${OPS_CONF:-/etc/openclaw-ops/ops.conf}"
# shellcheck disable=SC1090
[ -f "$CONF" ] && . "$CONF"

: "${WORKSPACE:?未配置 WORKSPACE（见 ops.conf.example）}"
: "${OPENCLAW_HOME:=$HOME/.openclaw}"
: "${LOG_SERVICE_MAX:=$((50 * 1024 * 1024))}"
: "${LOG_SERVICE_KEEP_LINES:=1000}"
: "${SESS_KEEP_DAYS:=7}"
: "${WS_BAK_KEEP:=1}"
: "${ROTATE_LOGS:=}"
: "${MEDIA_DIR:=$OPENCLAW_HOME/media}"
: "${MEDIA_VOICE_MIN:=60}"
: "${MEDIA_IMG_DAYS:=7}"
: "${TMP_KEEP_DAYS:=7}"
: "${OCLOG_DIR:=/tmp/openclaw}"
: "${OCLOG_ARCHIVE_DAYS:=14}"
: "${OCLOG_BUSY_HOURS:=24}"
: "${SYSDISK_CLEAN:=}"

STAMP_FILE="${STAMP_FILE:-/var/lib/log-rotate.last-logclean}"
LOG_TS() { date '+%F %T'; }

# ===== §A 附件 / 媒体 / 临时文件 =====
clean_media() {
  local DAYS="$MEDIA_IMG_DAYS"
  local VMIN="$MEDIA_VOICE_MIN"
  local list cnt bytes f

  if [ -d "$MEDIA_DIR" ]; then
    # A.0 语音：转文字后即删（留 VMIN 分钟缓冲；配合高频跑）
    list=$(find "$MEDIA_DIR" -maxdepth 3 -type f \( -iname '*.wav' -o -iname '*.mp3' \) -mmin +"$VMIN" 2>/dev/null)
    cnt=$(printf '%s\n' "$list" | grep -c . || true)
    bytes=0
    while IFS= read -r f; do [ -n "$f" ] && bytes=$((bytes + $(stat -c%s "$f" 2>/dev/null || echo 0))); done <<< "$list"
    if [ "$DRY" = 1 ]; then
      echo "[dry] 语音(转文字后即删，>${VMIN}min)：待删 ${cnt} 个 / $((bytes / 1048576))MB"
      printf '%s\n' "$list" | grep . | head -6 | sed 's/^/      /'
    else
      printf '%s\n' "$list" | grep . | while IFS= read -r f; do rm -f "$f"; done
      [ "$cnt" -gt 0 ] && echo "[log-rotate $(LOG_TS)] 语音清理(>${VMIN}min)：删 ${cnt} 个 / 释放 $(numfmt --to=iec --suffix=B "$bytes" 2>/dev/null || echo "${bytes}B")"
    fi

    # A.1 其他附件（保留 DAYS 天）：出站/入站/摄像头推送副本
    list=$(find "$MEDIA_DIR" -maxdepth 3 -type f \
             \( -name 'cam_*.jpg' -o -name 'night_*.mp4' -o -path '*/outbound/*' -o -path '*/inbound/*' \) \
             -mtime +"$DAYS" 2>/dev/null)
    cnt=$(printf '%s\n' "$list" | grep -c . || true)
    bytes=0
    while IFS= read -r f; do [ -n "$f" ] && bytes=$((bytes + $(stat -c%s "$f" 2>/dev/null || echo 0))); done <<< "$list"
    if [ "$DRY" = 1 ]; then
      echo "[dry] 其他附件(保留 ${DAYS} 天)：待删 ${cnt} 个 / $((bytes / 1048576))MB"
    else
      printf '%s\n' "$list" | grep . | while IFS= read -r f; do rm -f "$f"; done
      [ "$cnt" -gt 0 ] && echo "[log-rotate $(LOG_TS)] 其他附件清理(保留 ${DAYS} 天)：删 ${cnt} 个 / 释放 $(numfmt --to=iec --suffix=B "$bytes" 2>/dev/null || echo "${bytes}B")"
    fi
  fi

  # A.2 工作区根临时文件（本次工作遗留）
  local WS="$WORKSPACE"
  list=$(find "$WS" -maxdepth 1 -type f \( -name 'tmp_*.py' -o -name 'tmp_*.sh' -o -name '*_build.log' \) -mtime +"$DAYS" 2>/dev/null)
  cnt=$(printf '%s\n' "$list" | grep -c . || true)
  if [ "$DRY" = 1 ]; then
    echo "[dry] workspace 临时(保留 ${DAYS} 天)：待删 ${cnt} 个"
  else
    printf '%s\n' "$list" | grep . | while IFS= read -r f; do rm -f "$f"; done
    [ "$cnt" -gt 0 ] && echo "[log-rotate $(LOG_TS)] workspace 临时清理：删 ${cnt} 个"
  fi

  # A.3 /tmp 临时文件（仅当前用户属主、maxdepth1；不动系统/服务目录）
  local me; me=$(id -un)
  list=$(find /tmp -maxdepth 1 -type f -user "$me" \
           \( -name '*.py' -o -name '*.sh' -o -name '*.log' -o -name '*.txt' -o -name '*.json' \) \
           -mtime +"$DAYS" 2>/dev/null)
  cnt=$(printf '%s\n' "$list" | grep -c . || true)
  if [ "$DRY" = 1 ]; then
    echo "[dry] /tmp 临时(保留 ${DAYS} 天)：待删 ${cnt} 个"
  else
    printf '%s\n' "$list" | grep . | while IFS= read -r f; do rm -f "$f"; done
    [ "$cnt" -gt 0 ] && echo "[log-rotate $(LOG_TS)] /tmp 临时清理：删 ${cnt} 个"
  fi
}

# ===== §B 助手运行日志压缩归档（忙=每天；闲=隔 ~3 天）=====
clean_logs() {
  local act run f n dn
  [ -d "$OCLOG_DIR" ] || return 0

  act=$(find "$OCLOG_DIR" -maxdepth 1 -type f -name '*.log' -mmin -$((OCLOG_BUSY_HOURS * 60)) 2>/dev/null | wc -l | tr -d ' ')
  act=${act:-0}
  if [ "$act" -gt 0 ]; then
    run=1
  elif [ -f "$STAMP_FILE" ] && [ -n "$(find "$STAMP_FILE" -mtime -3 2>/dev/null)" ]; then
    run=0
  else
    run=1
  fi

  if [ "$run" != 1 ]; then
    echo "[log-rotate $(LOG_TS)] 日志压缩：低活动且距上次<3天，跳过"
    return 0
  fi

  n=0
  for f in "$OCLOG_DIR"/openclaw-*.log; do
    [ -f "$f" ] || continue
    case "$f" in *"$(date +%F)"*) continue ;; esac
    if [ "$DRY" = 1 ]; then
      echo "[dry] gzip $f"
    else
      gzip -f "$f" 2>/dev/null && n=$((n + 1))
    fi
  done

  if [ "$DRY" = 1 ]; then
    find "$OCLOG_DIR" -maxdepth 1 -name 'openclaw-*.log.gz' -mtime +"$OCLOG_ARCHIVE_DAYS" -print | sed 's/^/[dry] del /'
  else
    dn=$(find "$OCLOG_DIR" -maxdepth 1 -name 'openclaw-*.log.gz' -mtime +"$OCLOG_ARCHIVE_DAYS" 2>/dev/null | wc -l | tr -d ' ')
    find "$OCLOG_DIR" -maxdepth 1 -name 'openclaw-*.log.gz' -mtime +"$OCLOG_ARCHIVE_DAYS" -delete 2>/dev/null
    mkdir -p "$(dirname "$STAMP_FILE")" 2>/dev/null || true
    touch "$STAMP_FILE" 2>/dev/null || true
    { [ "$n" -gt 0 ] || [ "${dn:-0}" -gt 0 ]; } && echo "[log-rotate $(LOG_TS)] 日志压缩：gzip ${n} 个 / 删过老归档 ${dn:-0} 个"
  fi
}

# ===== 主流程（--media-only 时跳过）=====
if [ "$MEDIA_ONLY" != 1 ]; then

  # 1) 服务日志截断 + 轮转件按天数清理
  for spec in $ROTATE_LOGS; do
    f="${spec%%:*}"
    days="${spec##*:}"
    [ -f "$f" ] || continue
    sz=$(stat -c%s "$f" 2>/dev/null || echo 0)
    if [ "$sz" -gt "$LOG_SERVICE_MAX" ]; then
      if [ "$DRY" -eq 1 ]; then
        echo "  [dry-run] 截断 $f （${sz} 字节 → 保留最近 $LOG_SERVICE_KEEP_LINES 行）"
      else
        tail -n "$LOG_SERVICE_KEEP_LINES" "$f" > "$f.tmp" && mv "$f.tmp" "$f"
      fi
    fi
    if [ -n "$days" ] && [ "$days" != "$f" ]; then
      rn=$(find "$(dirname "$f")" -maxdepth 1 -name "$(basename "$f").*" -mtime +"$days" 2>/dev/null | wc -l | tr -d ' ')
      if [ "${rn:-0}" -gt 0 ]; then
        if [ "$DRY" -eq 1 ]; then
          echo "  [dry-run] 清理轮转件 $f.* 共 ${rn} 个（>${days}天）"
        else
          find "$(dirname "$f")" -maxdepth 1 -name "$(basename "$f").*" -mtime +"$days" -delete 2>/dev/null
        fi
      fi
    fi
  done

  # 2) 会话残留（trajectory/bak/checkpoint，超期删；不动主 .jsonl 与 .reset.*）
  SESS_DIR="$OPENCLAW_HOME/agents/main/sessions"
  SESS_CNT=0
  SESS_BYTES=0
  if [ -d "$SESS_DIR" ]; then
    SESS_CNT=$(find "$SESS_DIR" -maxdepth 1 -type f \( -name "*.trajectory.jsonl" -o -name "*.bak-*" -o -name "*.checkpoint.*" \) -mtime +"$SESS_KEEP_DAYS" 2>/dev/null | wc -l | tr -d ' ')
    SESS_BYTES=$(find "$SESS_DIR" -maxdepth 1 -type f \( -name "*.trajectory.jsonl" -o -name "*.bak-*" -o -name "*.checkpoint.*" \) -mtime +"$SESS_KEEP_DAYS" -printf '%s\n' 2>/dev/null | awk '{s+=$1} END{print s+0}')
    SESS_CNT=${SESS_CNT:-0}
    SESS_BYTES=${SESS_BYTES:-0}
    if [ "$DRY" -eq 1 ]; then
      echo "  [dry-run] 会话残留（>$SESS_KEEP_DAYS 天）将删 ${SESS_CNT} 个 / ${SESS_BYTES} 字节"
    else
      find "$SESS_DIR" -maxdepth 1 -type f -name "*.trajectory.jsonl" -mtime +"$SESS_KEEP_DAYS" -delete 2>/dev/null
      find "$SESS_DIR" -maxdepth 1 -type f -name "*.bak-*" -mtime +"$SESS_KEEP_DAYS" -delete 2>/dev/null
      find "$SESS_DIR" -maxdepth 1 -type f -name "*.checkpoint.*" -mtime +"$SESS_KEEP_DAYS" -delete 2>/dev/null
    fi
  fi

  # 3) 工作区手工备份瘦身（带时间戳的 *.bak.<ts> / *.bak-<ts> 每类保留最新 WS_BAK_KEEP 份）
  WS_CNT=0
  WS_BYTES=0
  if [ -d "$WORKSPACE" ]; then
    LIST=$(mktemp)
    find "$WORKSPACE" -maxdepth 1 -type f \( -name "*.bak.[0-9]*" -o -name "*.bak-[0-9]*" \) -printf '%T@\t%p\n' 2>/dev/null \
      | sort -rn \
      | awk -F'\t' -v keep="$WS_BAK_KEEP" '{t=$2; sub(/\.bak[.-][0-9][0-9-]*$/,"",t); if (seen[t]++ >= keep) print $2}' > "$LIST"
    WS_CNT=$(grep -c . "$LIST" || true)
    WS_BYTES=$(tr '\n' '\0' < "$LIST" 2>/dev/null | xargs -0 -r stat -c%s 2>/dev/null | awk '{s+=$1} END{print s+0}')
    WS_BYTES=${WS_BYTES:-0}
    if [ "$DRY" -eq 1 ]; then
      echo "  [dry-run] 手工备份将删 ${WS_CNT} 个 / ${WS_BYTES} 字节"
    else
      tr '\n' '\0' < "$LIST" 2>/dev/null | xargs -0 -r rm -f 2>/dev/null
    fi
    rm -f "$LIST"
  fi

  # 4) 系统盘清理（可选：把 sysdisk-clean.sh 之类的路径配在 SYSDISK_CLEAN 里）
  if [ -n "$SYSDISK_CLEAN" ] && [ -x "$SYSDISK_CLEAN" ]; then
    if [ "$DRY" = 1 ]; then
      "$SYSDISK_CLEAN" --dry-run 2>&1 | sed 's/^/[dry] /'
    else
      "$SYSDISK_CLEAN" >/dev/null 2>&1
      echo "[log-rotate $(LOG_TS)] 系统盘清理完成"
    fi
  fi

fi  # end of MEDIA_ONLY guard

clean_media
clean_logs

if [ "$MEDIA_ONLY" != 1 ]; then
  if [ "$DRY" -eq 1 ]; then
    echo "[dry-run] 结束：无任何改动。"
    exit 0
  fi
  SESS_H=$(numfmt --to=iec --suffix=B "$SESS_BYTES" 2>/dev/null || echo "${SESS_BYTES}B")
  WS_H=$(numfmt --to=iec --suffix=B "$WS_BYTES" 2>/dev/null || echo "${WS_BYTES}B")
  TOT_CNT=$((SESS_CNT + WS_CNT))
  TOT_H=$(numfmt --to=iec --suffix=B "$((SESS_BYTES + WS_BYTES))" 2>/dev/null || echo "$((SESS_BYTES + WS_BYTES))B")
  echo "[log-rotate $(LOG_TS)] 清理完成 | 会话残留 ${SESS_CNT} 个/释放 ${SESS_H} | 手工备份 ${WS_CNT} 个/释放 ${WS_H} | 合计 ${TOT_CNT} 个/释放 ${TOT_H}"
fi
