extends CanvasLayer

## 遊んでいるその場から不具合を報告するための常駐部品。
##
## 画面の隅に小さな報告ボタンを出す。押すとその瞬間の画面を撮り、いま動いて
## いる状況を添えて中継サーバーへ送る。中継サーバーがGitHubのIssueを作る。
##
## ゲーム側にGitHubのトークンを持たせない。配布物の中に入れた鍵は取り出せる
## ため、書き込み権限のあるトークンを同梱できない。代わりに、送り先だけを
## 設定に持ち、鍵は中継サーバーが持つ。
##
## 報告の中身は、人が読むためだけでなく、状況を機械が追えるように組み立てる。
## 版、環境、画面の大きさ、いま開いているシーン、直前の出来事、ゲーム固有の
## 値を決まった見出しで並べる。
##
## 使い方は README.md を参照。ゲーム固有の値は
## `GMornIssueMaker.add_context_provider(callable)` で足す。

## 中継サーバーが失敗したとき、報告を書き出す置き場。送れなかった報告を
## 捨てない。あとから手で送れる。
const FALLBACK_DIRECTORY := "user://gmorn_issue_maker"
## 送信の待ち時間（秒）。押したまま固まらない長さにする。
const REQUEST_TIMEOUT := 20.0
## 覚えておく出来事の数。多すぎると本文が読めなくなる。
const BREADCRUMB_LIMIT := 30
## 画面を送るときの縦の上限。原寸のままだと数メガバイトになり、
## 中継サーバー側で弾かれやすい。
const SCREENSHOT_MAX_HEIGHT := 1080

## GitHubの「新しいIssue」の頁を開くURLの上限。実際は8キロバイト程度まで通るが、
## 途中の経路（ブラウザやプロキシ）で切られないよう余裕を見る。
const URL_MAX_LENGTH := 6000

## 報告の窓は画面いっぱいから余白を取って出す。取り込む側の設計解像度が
## 分からないので、固定の大きさにすると広い画面では豆粒になる。
const PANEL_MARGIN_RATIO := 0.06

## 既定の文字の大きさが読める画面の高さ。これより広い画面では、その比で拡大する。
## 縦2142のような設計だと、既定の16pxは実質読めない。
const UI_REFERENCE_HEIGHT := 720.0
const UI_MAX_SCALE := 6.0

const LIBRARY_NAME := "GMornIssueMaker"
## plugin.cfg の version と必ず揃える（verify.gd が突き合わせる）
const VERSION := "0.3.1"
const ACCENT_COLOR := Color(0.98, 0.78, 0.35)
const MUTED_COLOR := Color(0.62, 0.62, 0.68)
## ボタンに出す虫の絵。
##
## 文字で「不具合報告」と出すと画面の隅を大きく占める。絵文字は環境の書体に
## 左右されて豆腐になることがあるため、絵そのものを持つ。SVGを実行時に
## 起こすので、画像ファイルを同梱しなくてよい（submodule で配る部品なので、
## 付属物は少ないほど扱いやすい）。
const BUG_ICON_SVG := """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="#ffffff" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">
<path d="M9 4.5 7.5 2.6M15 4.5l1.5-1.9"/>
<rect x="8" y="6" width="8" height="13" rx="4"/>
<path d="M8 10.5H4.6M8 15H4.6M16 10.5h3.4M16 15h3.4M6.2 7.4 4.4 6M6.2 18 4.4 19.6M17.8 7.4 19.6 6M17.8 18 19.6 19.6M12 6v13"/>
</svg>"""
## 虫の絵の一辺（画素）。ボタンより少し小さくして余白を残す。
const BUG_ICON_SIZE := 22

## 設定の実体。`class_name` で引くとエディタが一度走査するまで名前が引けず、
## 取り込んだ直後の自動実行で落ちる。読み込みで直に指す。
const SETTINGS_SCRIPT := preload("gmorn_issue_settings.gd")

signal report_started
signal report_finished(success: bool, url: String, message: String)

var settings: RefCounted
var _button: Button
var _panel: Control
var _theme: Theme
var _title_edit: LineEdit
var _body_edit: TextEdit
var _status_label: Label
var _preview: TextureRect
var _send_button: Button
var _request: HTTPRequest
var _screenshot: Image
var _context_providers: Array[Callable] = []
var _breadcrumbs: Array[String] = []
var _sending := false
var _headline: Label
var _captions: Array[Label] = []
var _cancel_button: Button
var _box: VBoxContainer
var _inset: MarginContainer
var _footer: HBoxContainer
var _signature: Label

func _ready() -> void:
	settings = SETTINGS_SCRIPT.new()
	settings.load_from_environment()
	if not settings.enabled:
		queue_free()
		return
	# いちばん上へ出す。遊びの画面がどれだけ層を重ねても、報告ボタンは隠れない。
	layer = settings.canvas_layer
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_ui()
	_request = HTTPRequest.new()
	_request.timeout = REQUEST_TIMEOUT
	add_child(_request)
	_request.request_completed.connect(_on_request_completed)

## ゲーム固有の状況を足す。呼ばれた側は `Dictionary` を返す。
##
## 例:
##   GMornIssueMaker.add_context_provider(func() -> Dictionary:
##       return {"面": current_stage_name(), "残機": player.lives})
func add_context_provider(provider: Callable) -> void:
	if not _context_providers.has(provider):
		_context_providers.append(provider)

func remove_context_provider(provider: Callable) -> void:
	_context_providers.erase(provider)

## 出来事を記録する。報告に直前の流れとして並ぶ。
##
## 不具合報告でいちばん足りないのは「何をしたか」である。画面遷移や購入など
## 節目で呼んでおくと、報告を読む側が経路を追える。
func leave_breadcrumb(message: String) -> void:
	_breadcrumbs.append("%s %s" % [_timestamp(), message])
	if _breadcrumbs.size() > BREADCRUMB_LIMIT:
		_breadcrumbs.remove_at(0)

## 報告ボタンの出し入れ。撮影や配信のときに隠せるようにする。
func set_button_visible(value: bool) -> void:
	if is_instance_valid(_button):
		_button.visible = value

## 押されたときと同じ流れを外から始める。任意のキーへ割り当てたいときに使う。
func open_report_form() -> void:
	if _sending or not is_instance_valid(_panel) or _panel.visible:
		return
	_fit_to_screen()
	await _capture_screenshot()
	_title_edit.text = ""
	_body_edit.text = ""
	_status_label.text = ""
	_send_button.disabled = false
	_panel.visible = true
	_title_edit.grab_focus()

func _build_ui() -> void:
	_button = Button.new()
	_button.text = settings.button_text
	if settings.button_text.is_empty():
		_button.icon = _bug_icon()
		_button.expand_icon = true
	_button.tooltip_text = "この瞬間の画面と状況を添えて報告する"
	_button.theme = _ui_theme()
	_button.focus_mode = Control.FOCUS_NONE
	_button.set_anchors_preset(_button_preset())
	_button.offset_left = settings.button_margin.x if settings.button_corner in ["top_left", "bottom_left"] else -settings.button_size.x - settings.button_margin.x
	_button.offset_right = _button.offset_left + settings.button_size.x
	_button.offset_top = settings.button_margin.y if settings.button_corner in ["top_left", "top_right"] else -settings.button_size.y - settings.button_margin.y
	_button.offset_bottom = _button.offset_top + settings.button_size.y
	_button.modulate.a = settings.button_alpha
	_button.pressed.connect(open_report_form)
	add_child(_button)
	_build_panel()

## 虫の絵を起こす。書体に頼らないので、どの環境でも同じ形が出る。
func _bug_icon() -> Texture2D:
	var image := Image.new()
	var error := image.load_svg_from_string(BUG_ICON_SVG, float(BUG_ICON_SIZE) / 24.0)
	if error != OK:
		return null
	return ImageTexture.create_from_image(image)

func _button_preset() -> int:
	match settings.button_corner:
		"top_left":
			return Control.PRESET_TOP_LEFT
		"bottom_left":
			return Control.PRESET_BOTTOM_LEFT
		"bottom_right":
			return Control.PRESET_BOTTOM_RIGHT
		_:
			return Control.PRESET_TOP_RIGHT

## 画面の広さに合わせて文字と間隔を決める。
##
## 部品の側では取り込む先の設計解像度を選べない。縦2142の企画に既定の16pxを
## 出すと、画面のごく一部に読めない字が並ぶ。開くたびに測って合わせる。
func _fit_to_screen() -> void:
	if not is_instance_valid(_panel):
		return
	var height := float(get_viewport().get_visible_rect().size.y)
	var scale := clampf(height / UI_REFERENCE_HEIGHT, 1.0, UI_MAX_SCALE)
	var base := int(round(16.0 * scale))
	if is_instance_valid(_headline):
		_headline.add_theme_font_size_override("font_size", int(round(base * 1.4)))
	for caption in _captions:
		caption.add_theme_font_size_override("font_size", base)
	for control in [_title_edit, _body_edit, _status_label, _send_button, _cancel_button]:
		if is_instance_valid(control):
			control.add_theme_font_size_override("font_size", base)
	if is_instance_valid(_signature):
		# 部品の名前と版は控えめに。読ませたいのは報告の中身のほう。
		_signature.add_theme_font_size_override("font_size", int(round(base * 0.8)))
	if is_instance_valid(_box):
		_box.add_theme_constant_override("separation", int(round(10.0 * scale)))
	if is_instance_valid(_footer):
		_footer.add_theme_constant_override("separation", int(round(12.0 * scale)))
	if is_instance_valid(_inset):
		# 窓の縁と中身のあいだ。狭いと文字が枠に貼り付いて読みにくい。
		var pad := int(round(22.0 * scale))
		for side in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
			_inset.add_theme_constant_override(side, pad)
	if is_instance_valid(_body_edit):
		_body_edit.custom_minimum_size = Vector2(0.0, base * 6.0)

## 報告の画面で使うテーマを作る。書体の指定が無ければ `null` を返し、既定の
## ままにする。
##
## 既定の書体は日本語の字を持たない。卓上では実行環境の書体が肩代わりするため
## 気付けないが、肩代わりの無い環境（Webへ書き出したもの）では日本語がすべて
## 豆腐になる。実際に配ったWeb版で、報告の画面の文字が全部四角になっていた。
## 報告の画面が読めなければ、そもそも報告が届かない。
##
## 大きさはここでは決めない。画面の広さに合わせて場所ごとに指定してあるため
## （`_apply_scale()`）、ここで既定を入れるとそちらと二重になる。
func _ui_theme() -> Theme:
	if _theme != null:
		return _theme
	if settings.font_path.is_empty():
		return null
	var font := load(settings.font_path) as Font
	if font == null:
		push_warning("書体を読めなかったため既定のままにする: %s" % settings.font_path)
		return null
	_theme = Theme.new()
	_theme.default_font = font
	return _theme

func _build_panel() -> void:
	_panel = Control.new()
	_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	_panel.visible = false
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	# 書体は報告の画面そのものへ付ける。テーマは子へ伝わるので、部品を足す
	# たびに指定し直さなくてよい。
	_panel.theme = _ui_theme()
	add_child(_panel)

	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.0, 0.6)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_panel.add_child(dim)

	# 画面いっぱいから余白を取る。取り込む側の設計解像度は分からないので、
	# 固定の大きさにすると、広い画面では豆粒、狭い画面でははみ出す。割合で置く。
	var frame := PanelContainer.new()
	frame.anchor_left = PANEL_MARGIN_RATIO
	frame.anchor_top = PANEL_MARGIN_RATIO
	frame.anchor_right = 1.0 - PANEL_MARGIN_RATIO
	frame.anchor_bottom = 1.0 - PANEL_MARGIN_RATIO
	frame.add_theme_stylebox_override("panel", _panel_style())
	_panel.add_child(frame)

	# 窓の縁と中身のあいだ。文字と同じ比で広げるので _fit_to_screen が触る。
	_inset = MarginContainer.new()
	frame.add_child(_inset)

	var box := VBoxContainer.new()
	_inset.add_child(box)
	_box = box

	_headline = Label.new()
	_headline.text = "不具合報告"
	_headline.add_theme_color_override("font_color", ACCENT_COLOR)
	box.add_child(_headline)

	# 写しは暗い台紙に載せる。透過や白い絵でも輪郭が分かるようにするため。
	var stage := PanelContainer.new()
	stage.size_flags_vertical = Control.SIZE_EXPAND_FILL
	stage.add_theme_stylebox_override("panel", _stage_style())
	box.add_child(stage)
	_preview = TextureRect.new()
	_preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	stage.add_child(_preview)

	_captions.append(_caption("タイトル", box))
	_title_edit = LineEdit.new()
	_title_edit.placeholder_text = "何が起きたかを一行で"
	_dress_input(_title_edit)
	box.add_child(_title_edit)

	_captions.append(_caption("詳細", box))
	_body_edit = TextEdit.new()
	_body_edit.placeholder_text = "何をしたら起きたか"
	_body_edit.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_dress_input(_body_edit)
	box.add_child(_body_edit)

	_status_label = Label.new()
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status_label.add_theme_color_override("font_color", ACCENT_COLOR)
	box.add_child(_status_label)

	# いちばん下の段。左に部品の名前と版、右に釦。
	# 版が分かると、報告を受けた側が「どの版の部品か」を聞き返さずに済む。
	var footer := HBoxContainer.new()
	box.add_child(footer)
	_signature = Label.new()
	_signature.text = "%s v%s" % [LIBRARY_NAME, _library_version()]
	_signature.add_theme_color_override("font_color", MUTED_COLOR)
	_signature.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	footer.add_child(_signature)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	footer.add_child(spacer)
	_cancel_button = Button.new()
	_cancel_button.text = "閉じる"
	_cancel_button.pressed.connect(_close_panel)
	_dress_button(_cancel_button, false)
	footer.add_child(_cancel_button)
	_send_button = Button.new()
	_send_button.text = "送信する"
	_send_button.pressed.connect(_send_report)
	_dress_button(_send_button, true)
	footer.add_child(_send_button)
	_footer = footer

## 見出しの小さいラベル
func _caption(text: String, parent: Node) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_color_override("font_color", MUTED_COLOR)
	parent.add_child(label)
	return label

## 部品の版。**実行時は必ずこの定数から出す。**
##
## `plugin.cfg` から読む形にしたら、書き出した実行ファイルで空になった。
## あれはエディタ用のメタ情報で、書き出しには含まれない。取り込む側に
## 書き出し設定をいじらせるのは筋が悪いので、ここに持つ。
##
## `plugin.cfg` と食い違わないことは `verify.gd` が確かめる。
func _library_version() -> String:
	return VERSION

## 書き込む欄。背景を1段明るくして「ここに書く」と分かるようにする。
func _dress_input(control: Control) -> void:
	var normal := StyleBoxFlat.new()
	normal.bg_color = Color(0.17, 0.17, 0.2)
	normal.set_corner_radius_all(8)
	normal.set_content_margin_all(10)
	var focused := normal.duplicate() as StyleBoxFlat
	focused.border_color = ACCENT_COLOR
	focused.set_border_width_all(2)
	control.add_theme_stylebox_override("normal", normal)
	control.add_theme_stylebox_override("focus", focused)

## 釦。送信だけを目立たせ、閉じるは控えめにする。
func _dress_button(button: Button, primary: bool) -> void:
	var normal := StyleBoxFlat.new()
	normal.bg_color = ACCENT_COLOR if primary else Color(0.24, 0.24, 0.28)
	normal.set_corner_radius_all(8)
	normal.set_content_margin_all(10)
	var hover := normal.duplicate() as StyleBoxFlat
	hover.bg_color = normal.bg_color.lightened(0.12)
	var pressed := normal.duplicate() as StyleBoxFlat
	pressed.bg_color = normal.bg_color.darkened(0.15)
	var disabled := normal.duplicate() as StyleBoxFlat
	disabled.bg_color = normal.bg_color
	disabled.bg_color.a = 0.4
	for name in ["normal", "hover", "pressed", "disabled"]:
		button.add_theme_stylebox_override(name, {
			"normal": normal, "hover": hover,
			"pressed": pressed, "disabled": disabled}[name])
	var text_color := Color(0.12, 0.1, 0.06) if primary else Color(0.92, 0.92, 0.95)
	for name in ["font_color", "font_hover_color", "font_pressed_color"]:
		button.add_theme_color_override(name, text_color)

func _panel_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.11, 0.11, 0.13, 0.98)
	style.border_color = Color(0.32, 0.32, 0.38)
	style.set_border_width_all(2)
	style.set_corner_radius_all(14)
	style.shadow_color = Color(0.0, 0.0, 0.0, 0.5)
	style.shadow_size = 10
	return style

func _stage_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.06, 0.06, 0.08, 1.0)
	style.set_corner_radius_all(8)
	return style

func _close_panel() -> void:
	_panel.visible = false
	_screenshot = null
	_preview.texture = null

## その瞬間の画面を撮る。
##
## ボタンや入力欄が写り込むと、報告したかった画面が隠れる。撮る前に自分の
## 描画を消し、描画が1回終わるのを待ってから読む。
func _capture_screenshot() -> void:
	# 画面の無い動かし方では撮れない。待ち続けると押したまま固まるので、
	# 撮らずに進む。報告そのものは状況だけで送れる。
	if DisplayServer.get_name() == "headless":
		_screenshot = null
		return
	var button_was_visible := _button.visible
	_button.visible = false
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	_button.visible = button_was_visible
	if image.get_height() > SCREENSHOT_MAX_HEIGHT:
		var ratio := float(SCREENSHOT_MAX_HEIGHT) / float(image.get_height())
		image.resize(int(float(image.get_width()) * ratio), SCREENSHOT_MAX_HEIGHT, Image.INTERPOLATE_BILINEAR)
	_screenshot = image
	_preview.texture = ImageTexture.create_from_image(image)

func _send_report() -> void:
	if _sending:
		return
	var title := _title_edit.text.strip_edges()
	if title.is_empty():
		_status_label.text = "見出しを書いてください。"
		return
	_sending = true
	_send_button.disabled = true
	_status_label.text = "送っています…"
	report_started.emit()
	var payload := build_payload(title, _body_edit.text)
	if settings.endpoint.is_empty():
		# 中継サーバーが無くても、GitHubの頁を開けば報告はできる。
		if not settings.repository.is_empty():
			# 画像を上げるあいだ待つので await。呼び出し側は待たなくてよい。
			_open_github_issue_page(title, payload)
			return
		_finish(false, "", "送り先も報告先のリポジトリも設定されていません。", payload)
		return
	var headers := PackedStringArray(["Content-Type: application/json"])
	if not settings.shared_secret.is_empty():
		headers.append("X-GMorn-Token: " + settings.shared_secret)
	var error := _request.request(settings.endpoint, headers, HTTPClient.METHOD_POST, JSON.stringify(payload))
	if error != OK:
		_finish(false, "", "送れませんでした（%d）。" % error, payload)

## GitHubの「新しいIssue」の頁を、見出しと本文を入れた状態で開く。
##
## 中継サーバーが無いときの道。書き込みはその人のGitHubの権限で行われるので、
## こちらが鍵を持たなくてよい。中継サーバーを立てるまでの間や、鍵を置きたく
## ない配り方でも、報告の口を閉じずに済む。
##
## 画面の写しは、URLへ直接載せられない。`drop_endpoint` があれば先に置き場へ
## 上げて、本文に画像として埋め込む。無ければ従来どおり、写しの場所を伝えて
## 貼ってもらう。
##
## **本文もURLへ載せる以上、長さの上限から逃げられない。** 6000バイトしか
## 入らず、日本語は1文字9バイトなので600文字ほどで切れる。切れるのは末尾＝
## 直前の操作の足あとで、いちばん知りたいところが消えていた。
## 置き場があるときは全文を Markdown で上げ、**切られない位置（先頭）** に
## そのリンクを置く。
func _open_github_issue_page(title: String, payload: Dictionary) -> void:
	var body := String(payload.get("body", ""))
	var screenshot_path := ""
	var image_url := await _upload_screenshot()
	if not image_url.is_empty():
		# 画像は本文の先頭へ置く。読む側が最初に見るのは絵である。
		body = "![報告時の画面](%s)\n\n%s" % [image_url, body]
	else:
		screenshot_path = _save_screenshot_file()
		if not screenshot_path.is_empty():
			body = "（画面の写し: %s をこの欄へ貼ってください）\n\n%s" % [screenshot_path, body]
			DisplayServer.clipboard_set(screenshot_path)
	# 詳しい表は置き場の md へ送り、**Issueには写しとリンクだけを載せる**。
	#
	# 状況の表をURLに詰め込むと6000バイトを超えて切れる。切れるのは末尾＝
	# 直前の操作の足あとで、いちばん知りたいところだった。どうせ md を開くなら、
	# Issue に同じものを（しかも切れた形で）並べる意味が無い。
	#
	# 上げられなかったときだけ、従来どおり全文を詰めて切る。
	var report_url := await _upload_report(body)
	if not report_url.is_empty():
		body = _summary_body(image_url, screenshot_path, report_url)
	var head := "https://github.com/%s/issues/new?title=%s&body=" % [
		settings.repository, title.uri_encode()]
	var tail := ""
	var labels: Array = payload.get("labels", [])
	if not labels.is_empty():
		tail = "&labels=" + ",".join(PackedStringArray(labels)).uri_encode()
	body = _fit_to_url(body, head.length() + tail.length())
	var url := head + body.uri_encode() + tail
	OS.shell_open(url)
	# **うまくいったときは控えを書かない。** 同じものがブラウザの中にも
	# 置き場の md にもある。手元に貯めても誰も読まないゴミが増えるだけ。
	# 書き出すのは「送れなかったとき」だけ（せっかく書いた内容が消えると、
	# 二度目は書いてもらえない）。
	# **うまくいったときは一行だけ。** 送り終えた人に要るのは「開いた」の一言で、
	# 何を本文へ入れたかは開いた頁を見れば分かる。控えの場所も同じ。
	# 読み手が何かしないといけないときだけ足す。
	var message := "GitHubのIssueページを開きました"
	if image_url.is_empty() and not screenshot_path.is_empty():
		# 写しを上げられなかったときだけ。貼る作業が残っているので伝える。
		message += "\n画面の写しの場所を写字板へ入れました。本文の欄へ貼ってください。"
	_sending = false
	_send_button.disabled = false
	_status_label.text = message
	report_finished.emit(true, url, message)

## 置き場へ送れたときのIssue本文。写し・詳細へのリンク・部品の版だけ。
##
## 読む側がまず見るのは絵で、次に開くのは詳細。Issueに表を並べても、
## URLの上限で切れた不完全な写しになるだけなので載せない。
func _summary_body(image_url: String, screenshot_path: String, report_url: String) -> String:
	var lines := PackedStringArray()
	if not image_url.is_empty():
		lines.append("![報告時の画面](%s)" % image_url)
	elif not screenshot_path.is_empty():
		lines.append("（画面の写し: %s をこの欄へ貼ってください）" % screenshot_path)
	lines.append("")
	lines.append("詳細はこちら: %s" % report_url)
	lines.append("")
	lines.append("---")
	lines.append("%s v%s" % [LIBRARY_NAME, _library_version()])
	return "\n".join(lines)

## URLの長さに収まるところまで本文を切る。全文は控えに残るので情報は失われない。
##
## **文字数ではなくURLエンコード後の長さで測る。** 日本語は1文字が %E3%81%82 の
## 9バイトになるので、6000文字で切ると54000バイトのURLになり、GitHubが受け取れない。
## 実際に「Issueが立てられない」という報告があった。
func _fit_to_url(body: String, reserved: int) -> String:
	if reserved + body.uri_encode().length() <= URL_MAX_LENGTH:
		return body
	# 置き場へ送れたときは要約だけを載せるので、ここへは来ない。
	# 来るのは置き場が無いときで、そのときは全文がどこにも無い。
	# 「控えにあります」と書くと嘘になる。
	var suffix := "\n\n（以下省略。URLの長さの上限で切れました）"
	var room := URL_MAX_LENGTH - reserved - suffix.uri_encode().length()
	if room <= 0:
		return suffix
	# 1文字あたりのバイト数は文字によって違うので、入る長さを二分探索で決める
	var low := 0
	var high := body.length()
	while low < high:
		var middle := (low + high + 1) / 2
		if body.substr(0, middle).uri_encode().length() <= room:
			low = middle
		else:
			high = middle - 1
	return body.substr(0, low) + suffix

## 画面の写しを画像置き場へ上げ、そのURLを返す。上げられなければ空を返す。
##
## 置き場は画像を預かるだけで、Issueを作る権限は持たない。だからURLを配布物へ
## 入れてよい。GitHubへ直接上げる道は書き込み権限のあるトークンが要るので、
## 配布するアプリからは使えない。
##
## 上げられなくても報告は止めない。写しの場所を伝える従来の道へ落ちる。
func _upload_screenshot() -> String:
	if _screenshot == null:
		return ""
	var png := _screenshot.save_png_to_buffer()
	if png.is_empty():
		return ""
	return await _upload(png, "image/png")

## 報告の全文を Markdown で置き場へ上げ、そのURLを返す。
##
## GitHubの頁を開く方式にはURLの長さの上限があり、本文は600文字ほどで切れる。
## **切れるのは末尾＝直前の操作の足あと**で、いちばん知りたいところが消える。
## 全文を別に置いてリンクすれば、本文が切れても読む側は辿れる。
func _upload_report(body: String) -> String:
	var bytes := body.to_utf8_buffer()
	if bytes.is_empty():
		return ""
	return await _upload(bytes, "text/markdown")

## 置き場へ上げて、公開URLを返す。上げられなければ空を返す。
##
## 置き場は預かるだけで、Issueを作る権限は持たない。だからURLを配布物へ
## 入れてよい。GitHubへ直接上げる道は書き込み権限のあるトークンが要るので、
## 配布するアプリからは使えない。
func _upload(bytes: PackedByteArray, content_type: String) -> String:
	if settings.drop_endpoint.is_empty():
		return ""
	var uploader := HTTPRequest.new()
	uploader.timeout = REQUEST_TIMEOUT
	add_child(uploader)
	var error := uploader.request_raw(
		settings.drop_endpoint, PackedStringArray(["Content-Type: " + content_type]),
		HTTPClient.METHOD_POST, bytes)
	if error != OK:
		uploader.queue_free()
		return ""
	var result: Array = await uploader.request_completed
	uploader.queue_free()
	# [result, response_code, headers, body]
	if int(result[1]) < 200 or int(result[1]) >= 300:
		return ""
	var parsed = JSON.parse_string((result[3] as PackedByteArray).get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY:
		return ""
	return String(parsed.get("url", ""))

## 画面の写しをファイルへ残し、その場所を返す。撮れていなければ空を返す。
func _save_screenshot_file() -> String:
	if _screenshot == null:
		return ""
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(FALLBACK_DIRECTORY))
	var path := "%s/screenshot_%s.png" % [FALLBACK_DIRECTORY, _file_stamp()]
	if _screenshot.save_png(path) != OK:
		return ""
	return ProjectSettings.globalize_path(path)

## 送る中身を組み立てる。中継サーバーはこの形を受け取る。
##
## 画面は base64 で入れる。別送りにすると、片方だけ届いたときに本文と画像が
## 食い違う。
func build_payload(title: String, description: String) -> Dictionary:
	var context := collect_context()
	var payload := {
		"title": title,
		"body": build_body(description, context),
		"labels": settings.labels,
		"context": context,
		"library": {"name": LIBRARY_NAME, "version": _library_version()},
	}
	if _screenshot != null:
		payload["screenshot_png_base64"] = Marshalls.raw_to_base64(_screenshot.save_png_to_buffer())
	return payload

## 状況を集める。決まった見出しで並べ、読む側が毎回同じ場所を見れば済むようにする。
func collect_context() -> Dictionary:
	var viewport := get_viewport()
	var context := {
		"報告時刻": _timestamp(),
		"アプリ": {
			"名前": ProjectSettings.get_setting("application/config/name", ""),
			"版": _application_version(),
			"デバッグビルド": OS.is_debug_build(),
		},
		"環境": _environment_rows(),
		"画面": {
			"窓": str(DisplayServer.window_get_size()),
			"描画範囲": str(viewport.get_visible_rect().size) if viewport != null else "",
			"全画面": DisplayServer.window_get_mode() != DisplayServer.WINDOW_MODE_WINDOWED,
		},
		"実行": _drop_blanks({
			"毎秒の描画数": Engine.get_frames_per_second(),
			"起動からの秒数": snappedf(float(Time.get_ticks_msec()) / 1000.0, 0.1),
			"ノード数": Performance.get_monitor(Performance.OBJECT_NODE_COUNT),
			# ブラウザでは 0 が返る。0 と書くと「使っていない」と読めてしまう
			"静的メモリ": Performance.get_monitor(Performance.MEMORY_STATIC),
			"開いているシーン": _current_scene_path(),
		}),
	}
	if not _breadcrumbs.is_empty():
		context["直前の出来事"] = _breadcrumbs.duplicate()
	var game := {}
	for provider: Callable in _context_providers:
		if not provider.is_valid():
			continue
		var extra: Variant = provider.call()
		if extra is Dictionary:
			game.merge(extra as Dictionary, true)
	if not game.is_empty():
		context["ゲームの状況"] = game
	return context

## Issue の本文を組み立てる。
##
## 状況は畳んだ塊ではなく、見出し付きの表と箇条書きで並べる。読むのが人でも
## 機械でも、同じ見出しを辿れば同じ場所に同じ意味の値がある形にする。
## 環境の欄。ブラウザでは `OS.get_version()` や `OS.get_processor_name()` が
## 空で返るので、代わりに閲覧ソフト側から拾える範囲を入れる。
## 空のまま並べると「調べたが分からなかった」のか「そもそも見ていない」のか
## 読む側に区別がつかないので、埋まらない行は出さない。
func _environment_rows() -> Dictionary:
	var rows := {
		"OS": OS.get_name(),
		"OSの版": OS.get_version(),
		"エンジン": "%s.%s.%s" % [
			Engine.get_version_info()["major"],
			Engine.get_version_info()["minor"],
			Engine.get_version_info()["patch"]],
		"描画方式": RenderingServer.get_video_adapter_name(),
		"言語": OS.get_locale(),
		"CPU": OS.get_processor_name(),
	}
	if OS.has_feature("web"):
		rows["閲覧ソフト"] = _browser_info("navigator.userAgent")
		if String(rows["OSの版"]).is_empty():
			rows["OSの版"] = _browser_info("navigator.platform")
		if String(rows["CPU"]).is_empty():
			var cores := _browser_info("String(navigator.hardwareConcurrency || '')")
			if not cores.is_empty():
				rows["CPU"] = "%s コア" % cores
	return _drop_blanks(rows)

## ブラウザから1つ値を取る。ブラウザ以外や取れないときは空を返す。
func _browser_info(expression: String) -> String:
	if not OS.has_feature("web"):
		return ""
	var value: Variant = JavaScriptBridge.eval(expression, true)
	return "" if value == null else String(value)

## 空・0 の行を落とす。埋まらなかったものを並べても読む側の役に立たない。
func _drop_blanks(rows: Dictionary) -> Dictionary:
	var kept := {}
	for key in rows:
		var value: Variant = rows[key]
		if value is String and String(value).strip_edges().is_empty():
			continue
		if (value is float or value is int) and float(value) == 0.0:
			continue
		kept[key] = value
	return kept

func build_body(description: String, context: Dictionary) -> String:
	var lines := PackedStringArray()
	lines.append("## 何が起きたか")
	lines.append("")
	lines.append(description.strip_edges() if not description.strip_edges().is_empty() else "（記入なし）")
	lines.append("")
	for section: String in ["アプリ", "環境", "画面", "実行", "ゲームの状況"]:
		if not context.has(section):
			continue
		lines.append("## " + section)
		lines.append("")
		lines.append("| 項目 | 値 |")
		lines.append("| --- | --- |")
		var values: Dictionary = context[section]
		for key: Variant in values:
			lines.append("| %s | %s |" % [key, _format_value(values[key])])
		lines.append("")
	if context.has("直前の出来事"):
		lines.append("## 直前の出来事")
		lines.append("")
		for entry: Variant in context["直前の出来事"]:
			lines.append("- " + String(entry))
		lines.append("")
	lines.append("---")
	lines.append("報告時刻: %s / %s v%s" % [
		context.get("報告時刻", ""), LIBRARY_NAME, _library_version()])
	return "\n".join(lines)

func _format_value(value: Variant) -> String:
	if value is float:
		return "%.2f" % value
	if value is bool:
		return "はい" if value else "いいえ"
	return String(str(value))

func _on_request_completed(_result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	var text := body.get_string_from_utf8()
	var parsed: Variant = JSON.parse_string(text)
	var url := ""
	if parsed is Dictionary:
		url = String((parsed as Dictionary).get("html_url", (parsed as Dictionary).get("url", "")))
	if response_code >= 200 and response_code < 300:
		_finish(true, url, "送りました。" if url.is_empty() else "送りました: " + url, {})
		return
	var message := "送れませんでした（%d）。" % response_code
	_finish(false, "", message, build_payload(_title_edit.text.strip_edges(), _body_edit.text))

## 送信の結末をまとめて扱う。
##
## 失敗したときは報告を捨てずに書き出す。せっかく書いた内容が消えると、
## 二度目は書いてもらえない。
func _finish(success: bool, url: String, message: String, payload: Dictionary) -> void:
	_sending = false
	_send_button.disabled = false
	if not success and not payload.is_empty():
		var saved := _save_fallback(payload)
		if not saved.is_empty():
			message += "\n報告は %s に残しました。" % saved
	_status_label.text = message
	report_finished.emit(success, url, message)
	if success:
		await get_tree().create_timer(1.5).timeout
		if is_instance_valid(_panel):
			_close_panel()

func _save_fallback(payload: Dictionary) -> String:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(FALLBACK_DIRECTORY))
	var path := "%s/report_%s.json" % [FALLBACK_DIRECTORY, _file_stamp()]
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return ""
	file.store_string(JSON.stringify(payload, "\t"))
	file.close()
	return ProjectSettings.globalize_path(path)

## ファイル名へ使える時刻。記号を落として並び順が保てる形にする。
func _file_stamp() -> String:
	return Time.get_datetime_string_from_system(false, false) \
		.replace(":", "").replace("-", "").replace("T", "_")

func _application_version() -> String:
	var version: Variant = ProjectSettings.get_setting("application/config/version", "")
	if not String(version).is_empty():
		return String(version)
	return "（application/config/version が未設定）"

func _current_scene_path() -> String:
	var tree := get_tree()
	if tree == null or tree.current_scene == null:
		return ""
	return tree.current_scene.scene_file_path

func _timestamp() -> String:
	return Time.get_datetime_string_from_system(false, true)
