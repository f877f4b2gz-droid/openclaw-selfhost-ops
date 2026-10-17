#!/bin/bash
# ------------------------------------------------------------
# ops_lib.sh — v2.0 治理脚本公共库
#
# 用途：统一三件事——
#   1) 加载 ops.conf 配置（OPS_CONF 环境变量可覆盖路径，默认 /etc/openclaw-ops/ops.conf）；
#   2) 可选加载私有辅助库 wk.sh（缺失时提供 wk_log / wk_notify 最小降级实现）；
#   3) 校验必填工作区路径（ops_require_ws）。
#
# 用法：脚本内 `source "$(dirname "${BASH_SOURCE[0]}")/../lib/ops_lib.sh"`
# 配置（ops.conf）：WORKSPACE  TRASH_DIR  WK_STATE_DIR
# 只读，不修改任何业务文件。
# ------------------------------------------------------------

# ---- 1. ops.conf ----
OPS_CONF="${OPS_CONF:-/etc/openclaw-ops/ops.conf}"
# shellcheck disable=SC1090
[ -f "$OPS_CONF" ] && . "$OPS_CONF"

# ---- 2. 私有辅助库（可选）----
if [ -f "${OPS_WK_LIB:-/usr/local/lib/wk.sh}" ]; then
  # shellcheck disable=SC1090
  source "${OPS_WK_LIB:-/usr/local/lib/wk.sh}"
else
  echo "WARN: 未找到 ${OPS_WK_LIB:-/usr/local/lib/wk.sh}，部分功能将受限" >&2
fi
# 缺失时降级：日志/通知回退到 stderr，主流程不中断
if ! declare -F wk_log >/dev/null 2>&1; then
  wk_log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" >&2; }
fi
if ! declare -F wk_notify >/dev/null 2>&1; then
  wk_notify() { printf '[notify] %s\n' "$*" >&2; }
fi

# ---- 3. 工作区校验 ----
ops_require_ws() {
  # WORKSPACE 必须来自 ops.conf 或环境变量；为空则报错退出
  WS="${WORKSPACE:-}"
  if [ -z "$WS" ]; then
    echo "ERROR: 未配置 WORKSPACE（ops.conf 或环境变量，模板见 templates/ops.conf.example）" >&2
    exit 1
  fi
  export WS
}
