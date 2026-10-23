#!/bin/bash
# ------------------------------------------------------------
# log-fingerprint.sh — 日志报错指纹（归一化 + 脱敏 + 短哈希）
#
# 读 stdin 每行日志 → 输出 "<fp12>\t<归一化样本(≤140字符)>"
#
# 归一化规则：
#   时间戳 / PID / 路径 / 数字 / 十六进制 / 引号内容 一律抹平；
#   token、JWT、长 blob 一律替换为占位符（不落明文密钥）。
# 目的：同一类错误无论出现多少次，都得到同一个短哈希。
#
# 实现说明：正则与哈希在单个 python3 进程内完成。
#   bash 版逐行 spawn md5sum，1000 行要 5.7 秒；日志量一大巡检就会被拖住。
# ------------------------------------------------------------
set -uo pipefail
umask 077

read -r -d '' PYCODE <<'PY'

import hashlib, re, sys

RULES = [
    (re.compile(r'\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}[.,+\d:]*'), ''),      # 时间戳
    (re.compile(r'\b\d{2}:\d{2}:\d{2}(?:[.,]\d+)?'), ''),                      # 纯时间
    (re.compile(r'(?i)\b(access_token|refresh_token|token|secret|password|passwd|apikey|api_key|authorization|sig|signature)=[^ "&]{3,}'), r'\1=<REDACTED>'),
    (re.compile(r'\beyJ[A-Za-z0-9._-]{10,}\b'), '<JWT>'),                       # JWT
    (re.compile(r'\b[0-9a-fA-F]{8,}\b'), '<HEX>'),                              # 长十六进制
    (re.compile(r'\b\d+\b'), '<N>'),                                            # 数字
    (re.compile(r'(?:/[A-Za-z0-9._@-]+){2,}'), '/<PATH>'),                      # 绝对路径
    (re.compile(r'\b[A-Za-z0-9_-]{40,}\b'), '<BLOB>'),                          # 长串（密钥形）
    (re.compile(r'"[^"]*"'), '"<Q>"'),                                          # 引号内容
]

CTRL = re.compile(r'[\x00-\x1f\x7f]')
WS = re.compile(r'\s+')


def fingerprint(line: str) -> str:
    n = line
    for pat, rep in RULES:
        n = pat.sub(rep, n)
    n = CTRL.sub('', n)
    n = WS.sub(' ', n).strip()[:140]
    return n


for raw in sys.stdin:
    line = raw.rstrip('\n')
    if not line:
        continue
    norm = fingerprint(line)
    if not norm:
        continue
    fp = hashlib.md5(norm.encode('utf-8')).hexdigest()[:12]
    sys.stdout.write(f'{fp}\t{norm}\n')
PY
exec python3 -c "$PYCODE" "$@"
