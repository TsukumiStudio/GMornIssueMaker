extends SceneTree

## アドオンが読めて、報告の中身が組み立てられることを確かめる。
##
## 送信までは行わない。送り先が空のときは書き出しへ回るので、その分岐までを見る。

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	# `class_name` はエディタが走査するまで引けない。取り込んだ直後でも通るよう、
	# 読み込みで直に指す。アドオン本体も同じ理由で読み込みを使っている。
	var settings_script: GDScript = load("res://gmorn_issue_settings.gd")
	var settings: RefCounted = settings_script.new()
	settings.load_from_environment()
	assert(settings.enabled, "既定で出るはず")
	assert(settings.button_corner == "top_right", "既定の位置が違う")
	assert(settings.endpoint.is_empty(), "例では送り先を空にしてある")

	var reporter: Node = (load("res://gmorn_issue_maker.gd") as GDScript).new()
	root.add_child(reporter)
	await process_frame

	reporter.add_context_provider(func() -> Dictionary:
		return {"面": "3-2", "残機": 3})
	reporter.leave_breadcrumb("面3を開始")
	reporter.leave_breadcrumb("ショップを開いた")

	var context: Dictionary = reporter.collect_context()
	for section: String in ["アプリ", "環境", "画面", "実行", "ゲームの状況", "直前の出来事"]:
		assert(context.has(section), "%s が無い" % section)
	assert(int(context["ゲームの状況"]["残機"]) == 3, "アプリ固有の値が入らない")
	assert(context["直前の出来事"].size() == 2, "出来事が入らない")

	var body: String = reporter.build_body("押したら落ちた", context)
	for heading: String in ["## 何が起きたか", "## 環境", "## ゲームの状況", "## 直前の出来事"]:
		assert(body.contains(heading), "%s の見出しが無い" % heading)
	assert(body.contains("押したら落ちた"), "書いた内容が入らない")
	assert(body.contains("| 残機 | 3 |"), "表の形になっていない")

	var payload: Dictionary = reporter.build_payload("落ちる", "押したら落ちた")
	assert(String(payload["title"]) == "落ちる", "見出しが入らない")
	assert(payload.has("labels") and payload.has("context"), "送る中身が足りない")
	assert(String(payload["library"]["name"]) == "GMornIssueMaker", "名乗りが無い")

	# 中継サーバーが無くても、リポジトリが決まっていれば報告の口は開く。
	reporter.settings.endpoint = ""
	reporter.settings.repository = "owner/name"
	# GDScriptのラムダは外の変数を値で写す。中で書き換えても外へは戻らないので、
	# 入れ物（配列）を渡して、その中身を書き換える。
	var opened: Array[String] = [""]
	reporter.report_finished.connect(func(_success: bool, url: String, _message: String) -> void:
		opened[0] = url)
	reporter._title_edit.text = "落ちる"
	reporter._body_edit.text = "押したら落ちた"
	reporter._send_report()
	await process_frame
	assert(opened[0].begins_with("https://github.com/owner/name/issues/new?"),
		"GitHubの頁を開く形になっていない: %s" % opened[0])
	assert(opened[0].contains("title="), "見出しが入っていない")
	assert(opened[0].contains("body="), "本文が入っていない")

	# どちらも無いときは開かない。開き先が無いまま開くと何も起きずに終わる。
	reporter.settings.repository = ""
	opened[0] = ""
	reporter._title_edit.text = "行き先なし"
	reporter._send_report()
	await process_frame
	assert(opened[0].is_empty(), "行き先が無いのに開こうとした")

	print("見出し=%d行 本文=%d文字" % [body.split("\n").size(), body.length()])
	print("GMORN ISSUE MAKER VERIFY: PASS")
	quit(0)
