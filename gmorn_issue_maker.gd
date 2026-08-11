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

func _build_panel() -> void:
	_panel = Control.new()
	_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	_panel.visible = false
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_panel)

	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.0, 0.55)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_panel.add_child(dim)

	var frame := PanelContainer.new()
	frame.set_anchors_preset(Control.PRESET_CENTER)
	frame.custom_minimum_size = Vector2(640.0, 480.0)
	frame.offset_left = -320.0
	frame.offset_right = 320.0
	frame.offset_top = -240.0
	frame.offset_bottom = 240.0
	_panel.add_child(frame)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	frame.add_child(box)

	var heading := Label.new()
	heading.text = "不具合の報告"
	box.add_child(heading)

	_preview = TextureRect.new()
	_preview.custom_minimum_size = Vector2(0.0, 160.0)
	_preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	box.add_child(_preview)

	var title_label := Label.new()
	title_label.text = "見出し"
	box.add_child(title_label)
	_title_edit = LineEdit.new()
	_title_edit.placeholder_text = "何が起きたかを一行で"
	box.add_child(_title_edit)

	var body_label := Label.new()
	body_label.text = "詳しく（何をしたら起きたか）"
	box.add_child(body_label)
	_body_edit = TextEdit.new()
	_body_edit.custom_minimum_size = Vector2(0.0, 120.0)
	box.add_child(_body_edit)

	_status_label = Label.new()
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_status_label)

	var buttons := HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_END
	box.add_child(buttons)
	var cancel := Button.new()
	cancel.text = "やめる"
	cancel.pressed.connect(_close_panel)
	buttons.add_child(cancel)
	_send_button = Button.new()
	_send_button.text = "送る"
	_send_button.pressed.connect(_send_report)
	buttons.add_child(_send_button)

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
## 画面の写しだけは頁へ自動で入れられない（URLに画像は載せられない）。
## 写しをファイルへ残し、その場所を写字板へ入れてから開く。報告する人は
## 本文の欄へ貼るか引きずり込むだけでよい。
func _open_github_issue_page(title: String, payload: Dictionary) -> void:
	var body := String(payload.get("body", ""))
	var screenshot_path := _save_screenshot_file()
	if not screenshot_path.is_empty():
		body = "（画面の写し: %s をこの欄へ貼ってください）\n\n%s" % [screenshot_path, body]
		DisplayServer.clipboard_set(screenshot_path)
	# GitHubのURLはおよそ8キロバイトまで。長い本文は切って、全文は控えに残す。
	if body.length() > 6000:
		body = body.substr(0, 6000) + "\n\n（以下省略。全文は報告の控えにあります）"
	var url := "https://github.com/%s/issues/new?title=%s&body=%s" % [
		settings.repository, title.uri_encode(), body.uri_encode()]
	var labels: Array = payload.get("labels", [])
	if not labels.is_empty():
		url += "&labels=" + ",".join(PackedStringArray(labels)).uri_encode()
	OS.shell_open(url)
	var saved := _save_fallback(payload)
	var message := "GitHubの報告ページを開きました。"
	if not screenshot_path.is_empty():
		message += "\n画面の写しの場所を写字板へ入れました。本文の欄へ貼ってください。"
	if not saved.is_empty():
		message += "\n控えは %s に残しました。" % saved
	_sending = false
	_send_button.disabled = false
	_status_label.text = message
	report_finished.emit(true, url, message)

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
		"library": {"name": "GMornIssueMaker", "version": "0.2.1"},
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
		"環境": {
			"OS": OS.get_name(),
			"OSの版": OS.get_version(),
			"エンジン": "%s.%s.%s" % [
				Engine.get_version_info()["major"],
				Engine.get_version_info()["minor"],
				Engine.get_version_info()["patch"]],
			"描画方式": RenderingServer.get_video_adapter_name(),
			"言語": OS.get_locale(),
			"CPU": OS.get_processor_name(),
		},
		"画面": {
			"窓": str(DisplayServer.window_get_size()),
			"描画範囲": str(viewport.get_visible_rect().size) if viewport != null else "",
			"全画面": DisplayServer.window_get_mode() != DisplayServer.WINDOW_MODE_WINDOWED,
		},
		"実行": {
			"毎秒の描画数": Engine.get_frames_per_second(),
			"起動からの秒数": snappedf(float(Time.get_ticks_msec()) / 1000.0, 0.1),
			"ノード数": Performance.get_monitor(Performance.OBJECT_NODE_COUNT),
			"静的メモリ": Performance.get_monitor(Performance.MEMORY_STATIC),
			"開いているシーン": _current_scene_path(),
		},
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
	lines.append("報告時刻: %s / GMornIssueMaker 0.2.1" % context.get("報告時刻", ""))
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
