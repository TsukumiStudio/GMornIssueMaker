extends RefCounted

## `class_name` は付けない。付けるとエディタが一度走査するまで名前を引けず、
## 取り込んだ直後にヘッドレスで走らせたときに読み込みごと失敗する。使う側は
## `preload` で直に指す。

## GMornIssueMaker の設定。
##
## 決め方は3段ある。後のものが前のものを上書きする。
##   1. ここに書いた既定値
##   2. プロジェクト設定（`gmorn_issue_maker/...`）
##   3. 環境変数（`GMORN_ISSUE_*`）
##
## プロジェクト設定は配布物へ入るので、送り先のように公開して構わないものを
## 置く。合言葉のように配りたくないものは環境変数で渡す。どちらにも書けるが、
## 配布物に入れた鍵は取り出せることを前提に決める。

## 送り先。中継サーバーのURL。空なら送らずに書き出しだけを行う。
var endpoint := ""
## 中継サーバーが受け付けるときに確かめる合言葉。空なら付けない。
var shared_secret := ""
## 報告ボタンを出すかどうか。既定では、書き出したビルドでも出す。
## 配布物で出したくない場合はプロジェクト設定で切る。
var enabled := true
## ボタンの位置。top_right / top_left / bottom_right / bottom_left。
var button_corner := "top_right"
## ボタンへ出す文字。空なら虫の絵だけを出す。長い文字を出すと画面の隅を
## 占めてしまうので、既定は絵だけにしてある。
var button_text := ""
## ボタンの大きさ。絵だけのときは正方形に近い方が収まりが良い。
var button_size := Vector2(40.0, 40.0)
var button_margin := Vector2(12.0, 12.0)
var button_alpha := 0.75
## 描画の層。遊びの画面より大きくしておく。
var canvas_layer := 512
## Issue へ付ける札。
var labels: Array = ["bug", "in-game-report"]

const SETTING_PREFIX := "gmorn_issue_maker/"

## 設定を読み込む。自分自身へ書き込むので、作ってから呼ぶ。
##
##   var settings := SETTINGS_SCRIPT.new()
##   settings.load_from_environment()
func load_from_environment() -> void:
	var settings := self
	settings.endpoint = String(_setting("endpoint", settings.endpoint))
	settings.shared_secret = String(_setting("shared_secret", settings.shared_secret))
	settings.enabled = bool(_setting("enabled", settings.enabled))
	settings.button_corner = String(_setting("button_corner", settings.button_corner))
	settings.button_text = String(_setting("button_text", settings.button_text))
	settings.button_size = Vector2(
		float(_setting("button_width", settings.button_size.x)),
		float(_setting("button_height", settings.button_size.y)))
	settings.button_alpha = float(_setting("button_alpha", settings.button_alpha))
	settings.canvas_layer = int(_setting("canvas_layer", settings.canvas_layer))
	var labels: Variant = _setting("labels", settings.labels)
	if labels is Array:
		settings.labels = labels as Array
	elif labels is String and not String(labels).is_empty():
		settings.labels = Array(String(labels).split(",", false))
	# 環境変数は最後に効かせる。手元だけ送り先を変えたいときに使う。
	settings.endpoint = _environment("GMORN_ISSUE_ENDPOINT", settings.endpoint)
	settings.shared_secret = _environment("GMORN_ISSUE_SECRET", settings.shared_secret)
	var disabled := OS.get_environment("GMORN_ISSUE_DISABLED")
	if disabled == "1" or disabled.to_lower() == "true":
		settings.enabled = false

static func _setting(key: String, fallback: Variant) -> Variant:
	var path := SETTING_PREFIX + key
	if not ProjectSettings.has_setting(path):
		return fallback
	return ProjectSettings.get_setting(path, fallback)

static func _environment(key: String, fallback: String) -> String:
	var value := OS.get_environment(key)
	return value if not value.is_empty() else fallback
