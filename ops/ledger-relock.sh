#!/usr/bin/env bash
# ledger-relock.sh — 仅重建 ops/ledger-protected.lock,不提交不推送。
# 等价于 ledger-push.sh --relock-only。仅限身份 主R。
# 用于在 主R 对台账中的保护条目(🔒 / codex 终审边界细则)做过一次经授权的改动后,
# 更新保护清单,使后续 ledger-push.sh 能通过校验。
#
# 用法: 在台账仓 clone 内运行:
#   BTD_GROUP=主R ./ops/ledger-relock.sh
# 只重建锁文件,不提交不推送。之后必须用 ledger-push.sh -m "提交说明" --relock
# 一并提交推送——**不许手工 git commit/push 台账仓(红线第21条)**。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/ledger-push.sh" --relock-only
