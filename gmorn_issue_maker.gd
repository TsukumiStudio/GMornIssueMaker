extends CanvasLayer

## 遊んでいるその場から不具合を報告する常駐部品。画面を撮り、状況を添えて
## 中継サーバー（MornIssueBridge）へ送り、サーバーが GitHub Issue を作る。
##
## ゲーム側に GitHub のトークンを持たせない。配布物に入れた鍵は取り出せる。
## 鍵は中継サーバーが持ち、ゲームは送り先だけを設定に持つ。

## 送れなかった報告は捨てずにここへ書き出す。あとから手で送れる。
const FALLBACK_DIRECTORY := "user://gmorn_issue_maker"
## 押したまま固まらない長さ。
const REQUEST_TIMEOUT := 20.0
const BREADCRUMB_LIMIT := 30
## 原寸のままだと数メガバイトになり、中継サーバー側で弾かれる。
const SCREENSHOT_MAX_HEIGHT := 1080
const SCREENSHOT_MAX_BYTES := 2 * 1024 * 1024

## 窓は固定の大きさにせず割合で置く。取り込む側の設計解像度が分からない。
const PANEL_MARGIN_RATIO := 0.06

## 既定の文字の大きさ（16px）が読める画面の高さ。これより広い画面ではその比で拡大する。
const UI_REFERENCE_HEIGHT := 720.0
## 幅も見る。高さだけだと縦長の携帯で拡大され、詰まっている幅がさらに足りなくなり
## 釦の文字が切れる。
const UI_REFERENCE_WIDTH := 540.0
const UI_MAX_SCALE := 6.0
## 下限を 1.0 にしない。狭い画面では既定より縮める必要がある。
const UI_MIN_SCALE := 0.85

const LIBRARY_NAME := "GMornIssueMaker"
## plugin.cfg の version と揃える（verify.gd が突き合わせる）。
const VERSION := "0.6.0"
const ACCENT_COLOR := Color(0.98, 0.78, 0.35)
const MUTED_COLOR := Color(0.62, 0.62, 0.68)
## 釦の虫の絵。絵文字は環境の書体で豆腐になり、画像ファイルは submodule の付属物を
## 増やすので、SVG 文字列を実行時に起こす。
const BUG_ICON_SVG := """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="#ffffff" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">
<path d="M9 4.5 7.5 2.6M15 4.5l1.5-1.9"/>
<rect x="8" y="6" width="8" height="13" rx="4"/>
<path d="M8 10.5H4.6M8 15H4.6M16 10.5h3.4M16 15h3.4M6.2 7.4 4.4 6M6.2 18 4.4 19.6M17.8 7.4 19.6 6M17.8 18 19.6 19.6M12 6v13"/>
</svg>"""
const BUG_ICON_SIZE := 22
const BUTTON_SIZE := Vector2(40.0, 40.0)
const BUTTON_MARGIN := Vector2(12.0, 12.0)

## `class_name` で引かない。エディタが一度走査するまで名前が引けず、取り込んだ直後の
## 自動実行で落ちる。
const SETTINGS_SCRIPT := preload("gmorn_issue_settings.gd")
const DEFAULT_FONT := preload("fonts/default_font.tres")

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
var _open_button: Button
var _created_issue_url := ""
var _request: HTTPRequest
var _pending_payload: Dictionary = {}
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
	settings.load_from_project()
	# 遊びの画面がどれだけ層を重ねても報告ボタンが隠れない層。
	layer = 512
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_ui()
	_request = HTTPRequest.new()
	_request.timeout = REQUEST_TIMEOUT
	_request.max_redirects = 0
	_request.body_size_limit = 65536
	add_child(_request)
	_request.request_completed.connect(_on_request_completed)

## ゲーム固有の状況を報告へ足す。`provider` は `Dictionary` を返す。
func add_context_provider(provider: Callable) -> void:
	if not _context_providers.has(provider):
		_context_providers.append(provider)

## 画面遷移や購入などの節目で呼ぶと、報告に「直前の出来事」として並ぶ。
func leave_breadcrumb(message: String) -> void:
	_breadcrumbs.append("%s %s" % [_timestamp(), message])
	if _breadcrumbs.size() > BREADCRUMB_LIMIT:
		_breadcrumbs.remove_at(0)

## 報告釦と同じ流れ。任意のキーへ割り当てるときに外から呼ぶ。
func _open_report_form() -> void:
	if _sending or not is_instance_valid(_panel) or _panel.visible:
		return
	_fit_to_screen()
	await _capture_screenshot()
	_title_edit.text = ""
	_body_edit.text = ""
	_status_label.text = ""
	_send_button.disabled = false
	_send_button.visible = true
	_open_button.visible = false
	_created_issue_url = ""
	_panel.visible = true
	_title_edit.grab_focus()

func _build_ui() -> void:
	_button = Button.new()
	_button.icon = _bug_icon()
	_button.expand_icon = true
	_button.tooltip_text = "この瞬間の画面と状況を添えて報告する"
	_button.theme = _ui_theme()
	_button.focus_mode = Control.FOCUS_NONE
	_button.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_button.offset_left = -BUTTON_SIZE.x - BUTTON_MARGIN.x
	_button.offset_right = -BUTTON_MARGIN.x
	_button.offset_top = BUTTON_MARGIN.y
	_button.offset_bottom = BUTTON_MARGIN.y + BUTTON_SIZE.y
	_button.modulate.a = 0.75
	_button.pressed.connect(_open_report_form)
	add_child(_button)
	_build_panel()

func _bug_icon() -> Texture2D:
	var image := Image.new()
	var error := image.load_svg_from_string(BUG_ICON_SVG, float(BUG_ICON_SIZE) / 24.0)
	if error != OK:
		return null
	return ImageTexture.create_from_image(image)

## 取り込む先の設計解像度を選べないので、開くたびに測って文字と間隔を決める。
func _fit_to_screen() -> void:
	if not is_instance_valid(_panel):
		return
	var view := get_viewport().get_visible_rect().size
	# 狭い方に合わせる。広い方に合わせると、もう一方からはみ出す。
	var scale := clampf(minf(
		float(view.x) / UI_REFERENCE_WIDTH,
		float(view.y) / UI_REFERENCE_HEIGHT), UI_MIN_SCALE, UI_MAX_SCALE)
	var base := int(round(16.0 * scale))
	if is_instance_valid(_headline):
		_headline.add_theme_font_size_override("font_size", int(round(base * 1.4)))
	for caption in _captions:
		caption.add_theme_font_size_override("font_size", base)
	for control in [_title_edit, _body_edit, _status_label, _send_button, _open_button, _cancel_button]:
		if is_instance_valid(control):
			control.add_theme_font_size_override("font_size", base)
	if is_instance_valid(_signature):
		_signature.add_theme_font_size_override("font_size", int(round(base * 0.8)))
	if is_instance_valid(_box):
		_box.add_theme_constant_override("separation", int(round(10.0 * scale)))
	if is_instance_valid(_footer):
		_footer.add_theme_constant_override("separation", int(round(12.0 * scale)))
	if is_instance_valid(_inset):
		var pad := int(round(22.0 * scale))
		for side in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
			_inset.add_theme_constant_override(side, pad)
	if is_instance_valid(_body_edit):
		_body_edit.custom_minimum_size = Vector2(0.0, base * 6.0)

## OS のフォントに頼らず同梱フォントで日本語を出す。
func _ui_theme() -> Theme:
	if _theme == null:
		_theme = Theme.new()
		_theme.default_font = DEFAULT_FONT
	return _theme

func _build_panel() -> void:
	_panel = Control.new()
	_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	_panel.visible = false
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	# テーマは子へ伝わるので、部品を足すたびに指定し直さない。
	_panel.theme = _ui_theme()
	add_child(_panel)

	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.0, 0.6)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_panel.add_child(dim)

	var frame := PanelContainer.new()
	frame.anchor_left = PANEL_MARGIN_RATIO
	frame.anchor_top = PANEL_MARGIN_RATIO
	frame.anchor_right = 1.0 - PANEL_MARGIN_RATIO
	frame.anchor_bottom = 1.0 - PANEL_MARGIN_RATIO
	frame.add_theme_stylebox_override("panel", _panel_style())
	_panel.add_child(frame)

	# 余白は文字と同じ比で広げるので _fit_to_screen が触る。
	_inset = MarginContainer.new()
	frame.add_child(_inset)

	var box := VBoxContainer.new()
	_inset.add_child(box)
	_box = box

	_headline = Label.new()
	_headline.text = "不具合報告"
	_headline.add_theme_color_override("font_color", ACCENT_COLOR)
	box.add_child(_headline)

	# 暗い台紙に載せないと、透過や白い絵の輪郭が分からない。
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
	_title_edit.placeholder_text = "何が起きたか"
	_dress_input(_title_edit)
	box.add_child(_title_edit)

	_captions.append(_caption("詳細", box))
	_body_edit = TextEdit.new()
	_body_edit.placeholder_text = "何をしたか"
	_body_edit.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_body_edit.size_flags_stretch_ratio = 1.5
	_dress_input(_body_edit)
	box.add_child(_body_edit)

	_status_label = Label.new()
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status_label.add_theme_color_override("font_color", ACCENT_COLOR)
	box.add_child(_status_label)

	# 部品の版を出しておくと、報告を受けた側が聞き返さずに済む。
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
	_open_button = Button.new()
	_open_button.text = "開く"
	_open_button.visible = false
	_open_button.pressed.connect(_open_created_issue)
	_dress_button(_open_button, true)
	footer.add_child(_open_button)
	_footer = footer

func _caption(text: String, parent: Node) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_color_override("font_color", MUTED_COLOR)
	parent.add_child(label)
	return label

## `plugin.cfg` から読まない。エディタ用のメタ情報で、書き出した実行ファイルには
## 含まれず空になる。
func _library_version() -> String:
	return VERSION

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

## 自分の釦が写り込まないよう、消してから描画1回を待って読む。
func _capture_screenshot() -> void:
	# ヘッドレスでは frame_post_draw が来ず固まるので、撮らずに進む。
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

func _open_created_issue() -> void:
	if _created_issue_url.is_empty():
		return
	var error := OS.shell_open(_created_issue_url)
	if error != OK:
		_status_label.text = "開けませんでした（%d）: %s" % [error, _created_issue_url]

func _send_report() -> void:
	send_report(_title_edit.text, _body_edit.text, _screenshot)

## OK は通信開始を表し、結果は report_finished で通知する。
## 同時送信は ERR_BUSY、空の見出しは ERR_INVALID_PARAMETER を返し、通知しない。
func send_report(title: String, description: String, screenshot: Image = null) -> Error:
	if _sending:
		return ERR_BUSY
	title = title.strip_edges()
	if title.is_empty():
		_status_label.text = "見出しを書いてください。"
		return ERR_INVALID_PARAMETER
	_pending_payload = _build_payload(title, description, screenshot).duplicate(true)
	_sending = true
	_created_issue_url = ""
	_open_button.visible = false
	_send_button.visible = true
	_send_button.disabled = true
	_title_edit.editable = false
	_body_edit.editable = false
	_status_label.text = "送っています…"
	if settings.endpoint.is_empty() or settings.repository.is_empty():
		_finish(false, "", "MornIssueBridgeのURLとリポジトリを設定してください。")
		return ERR_UNCONFIGURED
	var error := _request.request(settings.endpoint,
		PackedStringArray(["Content-Type: application/json"]),
		HTTPClient.METHOD_POST, JSON.stringify(_pending_payload))
	if error != OK:
		_finish(false, "", "送信を開始できませんでした（%d）。" % error)
	return error

## Issue 本文は要点だけ。状況と画像は Bridge が MornDrop の詳細レポートへ保存する。
func _build_payload(title: String, description: String, screenshot: Image = null) -> Dictionary:
	var payload := {
		"repository": settings.repository,
		"title": title,
		"body": _build_summary(description),
		"report_markdown": "# %s\n\n%s" % [title, _build_body(description, _collect_context())],
		"labels": ["bug", "in-game-report"],
	}
	if screenshot != null and not screenshot.is_empty():
		var image := screenshot.duplicate() as Image
		var png := image.save_png_to_buffer()
		while png.size() > SCREENSHOT_MAX_BYTES:
			image.resize(maxi(1, image.get_width() >> 1), maxi(1, image.get_height() >> 1), Image.INTERPOLATE_BILINEAR)
			png = image.save_png_to_buffer()
		if not png.is_empty():
			payload["screenshot_png_base64"] = Marshalls.raw_to_base64(png)
	return payload

## 見出しは固定。読む側（人と機械）が毎回同じ場所を見れば済むようにする。
func _collect_context() -> Dictionary:
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
			# ブラウザでは 0 が返るので _drop_blanks で落ちる。0 と書くと「使っていない」と読める。
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

## ブラウザでは `OS.get_version()` や `OS.get_processor_name()` が空で返るので、
## 機能タグとコア数で補う。`javascript_eval=no` のエンジンでは JavaScriptBridge が
## null を返すため、JS に頼るのは閲覧ソフト名だけにする。
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
			rows["OSの版"] = _web_host_os()
		if String(rows["CPU"]).is_empty():
			rows["CPU"] = "%d コア" % OS.get_processor_count()
	return _drop_blanks(rows)

func _web_host_os() -> String:
	for pair in [["web_windows", "Windows"], ["web_macos", "macOS"],
			["web_linuxbsd", "Linux/BSD"], ["web_android", "Android"], ["web_ios", "iOS"]]:
		if OS.has_feature(pair[0]):
			return pair[1]
	return ""

func _browser_info(expression: String) -> String:
	if not OS.has_feature("web"):
		return ""
	var value: Variant = JavaScriptBridge.eval(expression, true)
	return "" if value == null else String(value)

## 空のまま並べると「調べたが分からなかった」のか「見ていない」のか区別がつかない。
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

func _build_summary(description: String) -> String:
	return "## 何が起きたか\n\n" + (description.strip_edges() if not description.strip_edges().is_empty() else "（記入なし）")

func _build_body(description: String, context: Dictionary) -> String:
	var lines := PackedStringArray([_build_summary(description), ""])
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

func _on_request_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	var json := JSON.new()
	var parsed: Variant = json.data if json.parse(body.get_string_from_utf8()) == OK else null
	if result == HTTPRequest.RESULT_SUCCESS and response_code == 201 and parsed is Dictionary:
		var number: Variant = parsed.get("number")
		var url: Variant = parsed.get("html_url")
		if (number is int or number is float) and number > 0 and number == floor(number) and url is String:
			var expected := "https://github.com/%s/issues/%d" % [_pending_payload.repository, number]
			if url.to_lower() == expected.to_lower():
				_finish(true, url, "送りました: " + url)
				return
	var message := "送信を確認できませんでした（HTTP %d、通信結果 %d）。" % [response_code, result]
	if parsed is Dictionary and parsed.get("error") is String:
		message += "\n" + parsed.error
	_finish(false, "", message)

func _finish(success: bool, url: String, message: String) -> void:
	if not success:
		var saved := _save_fallback(_pending_payload)
		message += "\n報告は %s に残しました。" % saved if not saved.is_empty() else "\n報告の控えも保存できませんでした。入力内容をコピーしてください。"
	_pending_payload = {}
	_sending = false
	_send_button.disabled = success
	_send_button.visible = not success
	_created_issue_url = url if success else ""
	_open_button.visible = success
	_title_edit.editable = true
	_body_edit.editable = true
	_status_label.text = message
	report_finished.emit(success, url, message)

func _save_fallback(payload: Dictionary) -> String:
	if DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(FALLBACK_DIRECTORY)) != OK:
		return ""
	var path := "%s/report_%s_%s.json" % [FALLBACK_DIRECTORY, _file_stamp(), Crypto.new().generate_random_bytes(8).hex_encode()]
	var temporary := path + ".tmp"
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null:
		return ""
	var serialized := JSON.stringify(payload, "\t")
	file.store_string(serialized)
	file.flush()
	var error := file.get_error()
	file.close()
	if error != OK or not _valid_fallback(temporary, serialized):
		DirAccess.remove_absolute(temporary)
		return ""
	if DirAccess.rename_absolute(temporary, path) != OK:
		DirAccess.remove_absolute(temporary)
		return ""
	return ProjectSettings.globalize_path(path) if _valid_fallback(path, serialized) else ""

func _valid_fallback(path: String, serialized: String) -> bool:
	var content := FileAccess.get_file_as_string(path)
	return content == serialized and JSON.parse_string(content) is Dictionary

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
