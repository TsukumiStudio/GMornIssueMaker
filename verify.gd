extends SceneTree

var finished: Array = []

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var settings_script := load("res://gmorn_issue_settings.gd")
	var defaults: RefCounted = settings_script.new()
	defaults.load_from_project()
	assert(defaults.endpoint.is_empty() and defaults.repository.is_empty())
	var maker_script := load("res://gmorn_issue_maker.gd")
	var plugin := ConfigFile.new()
	assert(plugin.load("res://plugin.cfg") == OK)
	assert(plugin.get_value("plugin", "version") == maker_script.VERSION)
	var reporter: Node = maker_script.new()
	root.add_child(reporter)
	var font: Font = reporter._ui_theme().default_font
	assert(font.resource_path.ends_with("fonts/default_font.tres"))
	assert(reporter._button.get_theme_font("font") == font)
	assert(font.get_meta("license").contains("SIL OPEN FONT LICENSE Version 1.1"))
	(font as FontVariation).base_font.allow_system_fallback = false
	for character in "報告送信見出し詳細あいうえおアイウエオ漢字":
		assert(font.has_char(character.unicode_at(0)), "同梱フォントに文字がありません: " + character)
	reporter.settings.endpoint = OS.get_environment("MOCK_BRIDGE_URL")
	reporter.settings.repository = "example/game"
	var game := {"残機": 3}
	reporter.add_context_provider(func() -> Dictionary: return game)
	reporter.leave_breadcrumb("ショップを開きました")
	reporter.report_finished.connect(func(success: bool, url: String, message: String) -> void:
		finished.assign([success, url, message]))
	assert(reporter.send_report(" ", "本文") == ERR_INVALID_PARAMETER)
	assert(finished.is_empty())
	var screenshot := Image.create(1, 1, false, Image.FORMAT_RGBA8)
	var small: Dictionary = reporter._build_payload("小画像", "本文", screenshot)
	assert(Marshalls.base64_to_raw(small.screenshot_png_base64) == screenshot.save_png_to_buffer())
	assert(not reporter._build_payload("画像なし", "本文", Image.new()).has("screenshot_png_base64"))
	var pixels := FileAccess.get_file_as_bytes("res://noise.rgb")
	screenshot = Image.create_from_data(1920, 1080, false, Image.FORMAT_RGB8, pixels)
	assert(screenshot.save_png_to_buffer().size() > 2 * 1024 * 1024, "容量超過の画像になっていません")
	var reduced: Dictionary = reporter._build_payload("大画像", "本文", screenshot)
	var decoded := Image.new()
	assert(decoded.load_png_from_buffer(Marshalls.base64_to_raw(reduced.screenshot_png_base64)) == OK)
	assert(decoded.get_width() * 1080 == decoded.get_height() * 1920, "縦横比が変わっています")
	assert(screenshot.get_size() == Vector2i(1920, 1080) and screenshot.get_data() == pixels, "元画像が変わっています")
	assert(reporter.send_report("成功", "詳細".repeat(800), screenshot) == OK)
	assert(reporter.send_report("重複", "本文") == ERR_BUSY)
	await reporter.report_finished
	assert(finished[0] and finished[1] == "https://github.com/example/game/issues/42")
	assert(_saved().is_empty(), "成功時に控えが残っています")
	for title: String in ["拒否", "ログイン画面", "不正な成功", "切断"]:
		game["残機"] = 3
		# フォームも同じ送信経路を使います。
		reporter._screenshot = screenshot
		reporter._title_edit.text = title
		reporter._body_edit.text = "失敗時の本文"
		reporter._send_report()
		game["残機"] = 9
		await reporter.report_finished
		assert(not finished[0] and finished[1].is_empty(), title)
		assert(finished[2].contains("残しました"), finished[2])
	assert(_saved().size() == 4, "控えが上書きされています")
	for path: String in _saved():
		var payload: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
		assert(payload.body.contains("| 残機 | 3 |"), "送信時の状況が保存されていません")
		assert(payload.body.contains("ショップを開きました"))
		assert(payload.repository == "example/game")
	reporter.settings.endpoint = ""
	assert(reporter.send_report("設定なし", "本文") == ERR_UNCONFIGURED)
	assert(not finished[0] and _saved().size() == 5)
	reporter.settings.endpoint = OS.get_environment("MOCK_BRIDGE_URL")
	reporter.settings.repository = ""
	assert(reporter.send_report("リポジトリなし", "本文") == ERR_UNCONFIGURED)
	assert(not finished[0] and _saved().size() == 6)
	print("GMORN ISSUE MAKER VERIFY: PASS")
	quit()

func _saved() -> Array[String]:
	var files: Array[String] = []
	var directory := DirAccess.open("user://gmorn_issue_maker")
	if directory != null:
		for file: String in directory.get_files():
			assert(not file.ends_with(".tmp"), "一時ファイルが残っています")
			files.append("user://gmorn_issue_maker/" + file)
	return files
