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
	for row in [
		["repository", "", TYPE_STRING, PROPERTY_HINT_PLACEHOLDER_TEXT, "owner/repo"],
		["endpoint", "", TYPE_STRING, PROPERTY_HINT_NONE, ""],
	]:
		var key: String = "gmorn_issue_maker/" + String(row[0])
		if not ProjectSettings.has_setting(key):
			ProjectSettings.set_setting(key, row[1])
		ProjectSettings.set_initial_value(key, row[1])
		ProjectSettings.add_property_info({
			"name": key, "type": row[2], "hint": row[3], "hint_string": row[4],
		})
		ProjectSettings.set_as_basic(key, true)
