@tool
extends EditorPlugin

## GMornIssueMaker をプロジェクトへ組み込むための入口。
##
## 常駐させたいものは自動読み込みに登録する。報告ボタンは画面のいちばん上へ
## 出す必要があり、遊びの画面を作り替えても消えないようにしたいので、
## 各シーンへ置くのではなく自動読み込みで持つ。

const AUTOLOAD_NAME := "GMornIssueMaker"

## 置き場所を決め打ちにしない。submodule で好きな名前の場所へ入れられるように、
## 自分の居場所から辿る。
func _autoload_path() -> String:
	return get_script().resource_path.get_base_dir().path_join("gmorn_issue_maker.gd")

func _enter_tree() -> void:
	_register_settings()
	# 既に登録済みなら足さない。毎回足すとエディタの起動ごとに「自動読み込みを追加」の
	# 履歴が（アドオンの数だけ）並ぶ。project.godot に書いてあれば、それで動く。
	if not ProjectSettings.has_setting("autoload/" + AUTOLOAD_NAME):
		add_autoload_singleton(AUTOLOAD_NAME, _autoload_path())

func _exit_tree() -> void:
	remove_autoload_singleton(AUTOLOAD_NAME)

## 設定の既定値と型をプロジェクト設定へ登録する。
##
## 登録が無いと「プロジェクト設定」画面で全項目に戻す印（回転の矢印）が付き、
## どれを変えたのか分からない。パスは選択の窓から、列挙は一覧から選べるようにする。
## 値は読む側（既定値）と同じにすること。読む側はここに依らず、無くても動く。
func _register_settings() -> void:
	# `labels` は文字列（`,` 区切り）でも配列でも読める。登録は書きやすい文字列のほう。
	for row in [
		["enabled", true, TYPE_BOOL, PROPERTY_HINT_NONE, ""],
		["repository", "", TYPE_STRING, PROPERTY_HINT_PLACEHOLDER_TEXT, "owner/repo"],
		["endpoint", "", TYPE_STRING, PROPERTY_HINT_NONE, ""],
		["labels", "bug, in-game-report", TYPE_STRING, PROPERTY_HINT_NONE, ""],
		["button_corner", "top_right", TYPE_STRING, PROPERTY_HINT_ENUM, "top_left,top_right,bottom_left,bottom_right"],
		["button_text", "", TYPE_STRING, PROPERTY_HINT_NONE, ""],
		["button_width", 40.0, TYPE_FLOAT, PROPERTY_HINT_RANGE, "8,400,1"],
		["button_height", 40.0, TYPE_FLOAT, PROPERTY_HINT_RANGE, "8,400,1"],
		["button_alpha", 0.75, TYPE_FLOAT, PROPERTY_HINT_RANGE, "0,1,0.01"],
		["canvas_layer", 512, TYPE_INT, PROPERTY_HINT_RANGE, "0,1024,1"],
		["font_path", "", TYPE_STRING, PROPERTY_HINT_FILE, "*.ttf,*.otf,*.woff,*.woff2,*.fnt,*.tres"],
	]:
		var key: String = "gmorn_issue_maker/" + String(row[0])
		if not ProjectSettings.has_setting(key):
			ProjectSettings.set_setting(key, row[1])
		ProjectSettings.set_initial_value(key, row[1])
		ProjectSettings.add_property_info({
			"name": key, "type": row[2], "hint": row[3], "hint_string": row[4],
		})
		ProjectSettings.set_as_basic(key, true)
