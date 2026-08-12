#!/bin/sh
# この部品だけを確かめる。
#
# リポジトリ直下に project.godot は置けない。取り込む側が
# addons/gmorn_issue_maker へ submodule として入れるため、そこに project.godot が
# あるとGodotが「別のプロジェクト」と見なしてフォルダごと書き出しから外す。
# 実際にそれで、書き出したビルドから報告ボタンが消えていた。
#
# 代わりに、一時の置き場へ最小のプロジェクトを作って、その中へこの部品を写して回す。
set -eu

addon_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
godot_bin=${GODOT_BIN:-$(command -v godot 2>/dev/null || echo /Applications/Godot.app/Contents/MacOS/Godot)}
work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

mkdir -p "$work_dir/addons/gmorn_issue_maker"
cp "$addon_dir"/*.gd "$addon_dir"/plugin.cfg "$work_dir/addons/gmorn_issue_maker/"
cp "$addon_dir/verify.gd" "$work_dir/verify.gd"
# plugin.cfg は根にも置く。確認は版を突き合わせるために `res://plugin.cfg` を
# 読むが、下の sed が書き換えるのは `res://gmorn_` で始まる置き場だけなので、
# 根に無いと読めずにそこで止まる。
cp "$addon_dir/plugin.cfg" "$work_dir/plugin.cfg"
# 部品の中の相対参照に合わせるため、確認用の読み込み先も addons/ を指す。
sed -i '' 's|res://gmorn_|res://addons/gmorn_issue_maker/gmorn_|g' "$work_dir/verify.gd" 2>/dev/null \
  || sed -i 's|res://gmorn_|res://addons/gmorn_issue_maker/gmorn_|g' "$work_dir/verify.gd"

cat > "$work_dir/project.godot" <<'PROJECT'
config_version=5

[application]

config/name="GMornIssueMaker Verify"
config/version="0.2.1"
config/features=PackedStringArray("4.7")

[gmorn_issue_maker]

endpoint=""
PROJECT

"$godot_bin" --headless --path "$work_dir" --script verify.gd
