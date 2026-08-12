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

## 既定でつないである置き場。
##
## **公開して構わない。** 預かるだけでIssueを作る権限は持たないので、鍵ではない。
## そもそもブラウザで動くものに入れた時点で、開発者ツールから見える。
## 隠せない前提で、守りは置き場の側（大きさの上限・回数の制限・受け取る種類の
## 限定・一定期間で消える）に寄せてある。
##
## 差し替え・切断のしかたは `drop_endpoint` の説明を見ること。
const DEFAULT_DROP_ENDPOINT := "https://drop.tsukumistudio.com"

## 送り先。中継サーバーのURL。空でも `repository` があれば報告できる。
var endpoint := ""
## 置き場のURL。写しと報告の全文を預けるだけの、小さなサーバー。
##
## 入れておくと、GitHubの頁を開く方式でも
##
## - 画面の写しを先に上げて、本文へ画像として埋め込める
## - **報告の全文を Markdown で上げて、本文からリンクできる**
##
## 全文のリンクが要るのは、GitHubの頁を開く方式にURLの長さの上限があるため。
## 6000バイトしか載らず、日本語は1文字9バイトなので**本文は600文字ほどで切れる**。
## 直前の操作の足あとが途中で消えて、いちばん知りたいところが読めなかった。
##
## **置くだけなので鍵は要らない**（Issueを作る権限は持たせない）。だから
## **既定でつなげてある。** 取り込んだだけで写しも全文も付く。
##
## 別の置き場に向けたいなら `gmorn_issue_maker/drop_endpoint`、
## 環境変数 `GMORN_ISSUE_DROP_ENDPOINT` で差し替える。空にすれば使わない。
## 古い名前 `image_endpoint` でも読む。
##
## 置き場に求めるのはこれだけ。
##
##   POST で生バイトを受け取り（種類は Content-Type）、
##   `{"url": "..."}` を含むJSONを返す
var drop_endpoint := DEFAULT_DROP_ENDPOINT
## 報告先のリポジトリ（`owner/name`）。中継サーバーが無いときに使う。
##
## 中継サーバーが無くても、GitHubの「新しいIssue」の頁を見出しと本文を入れた
## 状態で開けば報告はできる。書き込みはその人のGitHubの権限で行われるので、
## こちらが鍵を持つ必要が無い。画面の写しだけは自動で添えられないため、
## 場所を伝えて貼ってもらう。
var repository := ""
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
	# 置き場は画像だけでなく報告の全文も預かるようになったので名前を変えた。
	# 先に入れた人の設定を壊さないよう、古い名前も読む。
	#
	# **空を書いたら空のまま**にする（既定へ戻さない）。置き場へ送りたくない
	# 取り込み方があるので、明示的に切れる道を残す。
	settings.drop_endpoint = String(_setting("image_endpoint", settings.drop_endpoint))
	settings.drop_endpoint = String(_setting("drop_endpoint", settings.drop_endpoint))
	settings.drop_endpoint = _environment(
		"GMORN_ISSUE_DROP_ENDPOINT", settings.drop_endpoint)
	settings.repository = String(_setting("repository", settings.repository))
	settings.shared_secret = String(_setting("shared_secret", settings.shared_secret))
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
	if labels is Array:
		settings.labels = labels as Array
	elif labels is String and not String(labels).is_empty():
		settings.labels = Array(String(labels).split(",", false))
	# 環境変数は最後に効かせる。手元だけ送り先を変えたいときに使う。
	settings.endpoint = _environment("GMORN_ISSUE_ENDPOINT", settings.endpoint)
	settings.repository = _environment("GMORN_ISSUE_REPOSITORY", settings.repository)
	settings.shared_secret = _environment("GMORN_ISSUE_SECRET", settings.shared_secret)
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
