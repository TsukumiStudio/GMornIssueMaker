#!/bin/sh
# 一時プロジェクトで検証する。実際の GitHub やプレイヤーの保存先には触れない。
set -eu
exec python3 "$(dirname "$0")/verify.py"
