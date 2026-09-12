#!/bin/sh
# 一時プロジェクト内で検証し、実際のGitHubやプレイヤーの保存先には触れません。
set -eu
exec python3 "$(dirname "$0")/verify.py"
