#!/bin/bash
set -uo pipefail
umask 077
# log-fingerprint.sh — 日志报错指纹（归一化 + 脱敏 + 短哈希）
# 读 stdin 每行日志 → 输出 "<fp10>\t<归一化样本(≤140字符)>"
# 规范：时间/PID/路径/数字/十六进制归一；token/JWT/长blob 一律脱敏为 <REDACTED>/<JWT>/<BLOB>（不落明文密钥）。

norm(){
  sed -E '
    s/[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9]{2}:[0-9]{2}:[0-9:.,+]*//g;
    s/[0-9]{2}:[0-9]{2}:[0-9]{2}([.,][0-9]+)?//g;
    s#(access_token|refresh_token|token|secret|password|passwd|apikey|api_key|authorization|sig|signature)=[^ "&]{3,}#\1=<REDACTED>#g;
    s/\beyJ[A-Za-z0-9._-]{10,}\b/<JWT>/g;
    s/\b[0-9a-fA-F]{8,}\b/<HEX>/g;
    s/\b[0-9]{1,}\b/<N>/g;
    s#(/[A-Za-z0-9._@-]+){2,}#/<PATH>#g;
    s/\b[A-Za-z0-9_-]{40,}\b/<BLOB>/g;
    s/"[^"]*"/"<Q>"/g;
    s/[[:space:]]+/ /g; s/^ //; s/ $//;
  '
}

while IFS= read -r line; do
  [ -z "$line" ] && continue
  n=$(printf '%s' "$line" | norm | tr -d '\000-\037\177' | cut -c1-140)
  [ -z "$n" ] && continue
  fp=$(printf '%s' "$n" | md5sum | cut -c1-10)
  printf '%s\t%s\n' "$fp" "$n"
done
exit 0
