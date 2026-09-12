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
## MornIssueBridgeのURLと、Issueを作成するリポジトリを指定します。
var endpoint := ""
var repository := ""
## 送信者情報は任意です。ログイン中のユーザーなどをゲーム側で設定できます。
var reporter_id := ""
var reporter_name := ""
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

## 報告の画面で使う書体（`res://` から始まる置き場）。空なら既定のまま。
##
## 指定しないと、Godotが用意している既定の書体で描く。この書体は日本語の字を
## 持たないが、卓上では実行環境の書体が肩代わりするため気付けない。肩代わりの
## 無い環境（Webへ書き出したもの）では、日本語がすべて豆腐になる。実際に配った
## Web版で、報告の画面の文字が全部四角になっていた。報告の画面が読めなければ、
## そもそも報告が届かない。
var font_path := ""

const SETTING_PREFIX := "gmorn_issue_maker/"

## 設定を読み込む。自分自身へ書き込むので、作ってから呼ぶ。
##
##   var settings := SETTINGS_SCRIPT.new()
##   settings.load_from_environment()
func load_from_environment() -> void:
	var settings := self
	settings.endpoint = String(_setting("endpoint", settings.endpoint))
	settings.repository = String(_setting("repository", settings.repository))
	settings.reporter_id = String(_setting("reporter_id", settings.reporter_id))
	settings.reporter_name = String(_setting("reporter_name", settings.reporter_name))
	settings.enabled = bool(_setting("enabled", settings.enabled))
	settings.button_corner = String(_setting("button_corner", settings.button_corner))
	settings.button_text = String(_setting("button_text", settings.button_text))
	settings.button_size = Vector2(
		float(_setting("button_width", settings.button_size.x)),
		float(_setting("button_height", settings.button_size.y)))
	settings.button_alpha = float(_setting("button_alpha", settings.button_alpha))
	settings.canvas_layer = int(_setting("canvas_layer", settings.canvas_layer))
	settings.font_path = String(_setting("font_path", settings.font_path))
	# 何も指定が無ければ、プロジェクト全体の書体を借りる。作品が既に持って
	# いるものを使えば、報告の画面のためだけに置き場を書かせなくて済む。
	if settings.font_path.is_empty():
		settings.font_path = String(_setting_at("gui/theme/custom_font", ""))
	var labels: Variant = _setting("labels", settings.labels)
	if labels is Array or labels is PackedStringArray:
		settings.labels = Array(labels)
	elif labels is String and not String(labels).is_empty():
		settings.labels = Array(String(labels).split(",", false))
	# 環境変数は最後に効かせる。手元だけ送り先を変えたいときに使う。
	settings.endpoint = _environment("GMORN_ISSUE_ENDPOINT", settings.endpoint)
	settings.repository = _environment("GMORN_ISSUE_REPOSITORY", settings.repository)
	var disabled := OS.get_environment("GMORN_ISSUE_DISABLED")
	if disabled == "1" or disabled.to_lower() == "true":
		settings.enabled = false

static func _setting(key: String, fallback: Variant) -> Variant:
	return _setting_at(SETTING_PREFIX + key, fallback)

static func _setting_at(path: String, fallback: Variant) -> Variant:
	if not ProjectSettings.has_setting(path):
		return fallback
	return ProjectSettings.get_setting(path, fallback)

static func _environment(key: String, fallback: String) -> String:
	var value := OS.get_environment(key)
	return value if not value.is_empty() else fallback
