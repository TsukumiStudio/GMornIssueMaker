@tool
extends EditorPlugin

## 各シーンへ置かず自動読み込みで持つ。報告ボタンは画面を作り替えても消えてはいけない。

const AUTOLOAD_NAME := "GMornIssueMaker"

## 置き場所を決め打ちにしない。submodule で任意の場所へ入れられるよう自分の居場所から辿る。
func _autoload_path() -> String:
	return get_script().resource_path.get_base_dir().path_join("gmorn_issue_maker.gd")

func _enter_tree() -> void:
	_register_settings()
	# 登録済みなら足さない。毎回足すとエディタ起動ごとに「自動読み込みを追加」の履歴が並ぶ。
	if not ProjectSettings.has_setting("autoload/" + AUTOLOAD_NAME):
		add_autoload_singleton(AUTOLOAD_NAME, _autoload_path())

func _exit_tree() -> void:
	remove_autoload_singleton(AUTOLOAD_NAME)

## 既定値を登録しないと「プロジェクト設定」で全項目に戻す印が付き、どれを変えたか
## 分からない。値は読む側の既定値と同じにする。読む側はこの登録が無くても動く。
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
