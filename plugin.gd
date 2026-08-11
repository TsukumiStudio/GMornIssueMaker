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
	add_autoload_singleton(AUTOLOAD_NAME, _autoload_path())

func _exit_tree() -> void:
	remove_autoload_singleton(AUTOLOAD_NAME)
