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

	# 版は2か所にある。実行時に使うのはスクリプトの定数で、plugin.cfg は
	# エディタが読む。書き出しに plugin.cfg は含まれないので、実行時に
	# そちらへ頼ると空になる（実際に画面へ「v」だけが出た）。
	# 片方だけ上げる事故を防ぐため、ここで突き合わせる。
	var maker_script: GDScript = load("res://gmorn_issue_maker.gd")
	var declared: String = maker_script.get_script_constant_map()["VERSION"]
	var plugin := ConfigFile.new()
	assert(plugin.load("res://plugin.cfg") == OK, "plugin.cfg が読めない")
	var advertised := String(plugin.get_value("plugin", "version", ""))
	assert(declared == advertised,
		"版が食い違っています。スクリプト=%s / plugin.cfg=%s。両方を揃えること" % [
			declared, advertised])
	assert(not declared.is_empty(), "版が空です")
	print("  版: %s（スクリプトと plugin.cfg が一致）" % declared)

	# 置き場は既定でつながっていること。**空だと、取り込んだ人は写しも全文も
	# 付かないまま気づかない。** 設定を書かせない代わりに、ここで見張る。
	var fresh: RefCounted = settings_script.new()
	fresh.load_from_environment()
	assert(fresh.drop_endpoint.begins_with("https://"),
		"置き場が既定でつながっていない（%s）" % fresh.drop_endpoint)
	assert(fresh.drop_endpoint == settings_script.DEFAULT_DROP_ENDPOINT,
		"既定値と食い違う（%s）" % fresh.drop_endpoint)

	# 差し替えられること。
	ProjectSettings.set_setting("gmorn_issue_maker/drop_endpoint", "https://example.test")
	var swapped: RefCounted = settings_script.new()
	swapped.load_from_environment()
	assert(swapped.drop_endpoint == "https://example.test",
		"置き場を差し替えられない（%s）" % swapped.drop_endpoint)

	# 空を書いたら切れること。既定へ戻ってはいけない。
	ProjectSettings.set_setting("gmorn_issue_maker/drop_endpoint", "")
	var cut: RefCounted = settings_script.new()
	cut.load_from_environment()
	assert(cut.drop_endpoint.is_empty(),
		"空にしても切れない（%s）" % cut.drop_endpoint)
	ProjectSettings.clear("gmorn_issue_maker/drop_endpoint")
	print("  置き場: 既定=%s / 差し替え・切断とも効く" % settings_script.DEFAULT_DROP_ENDPOINT)

	# 置き場へ送れたときの本文は「写し・詳細へのリンク・部品の版」だけ。
	# 表を並べるとURLの上限で切れるので、Issueには載せない。
	var brief: Node = maker_script.new()
	root.add_child(brief)
	await process_frame
	var summary: String = brief.call(
		"_summary_body", "https://example.test/a.png", "", "https://example.test/b.md")
	assert(summary.contains("https://example.test/a.png"), "写しが入っていない")
	assert(summary.contains("詳細はこちら: https://example.test/b.md"),
		"詳細へのリンクが入っていない: %s" % summary)
	assert(summary.contains("v" + maker_script.get_script_constant_map()["VERSION"]),
		"部品の版が入っていない: %s" % summary)
	assert(not summary.contains("## 環境"), "表がIssue本文に残っている")
	# URLの上限に対して十分小さいこと。ここが膨らむと、また切れ始める。
	assert(summary.uri_encode().length() < 1000,
		"Issue本文が%dバイトある。要約になっていない" % summary.uri_encode().length())
	print("  Issue本文: %dバイト（上限6000）" % summary.uri_encode().length())

	# **本番の経路が本当にこれを使っているか。** 関数だけを見ていると、
	# 呼び出し側を書き換えて表を並べる形に戻しても素通りする（実際に素通りした）。
	# 送る流れの中で `_summary_body` を通っていることを、書いてあるもので確かめる。
	var source := FileAccess.get_file_as_string("res://gmorn_issue_maker.gd")
	var flow := source.substr(source.find("func _open_github_issue_page"))
	flow = flow.substr(0, flow.find("\nfunc "))
	assert(flow.contains("_summary_body("),
		"送る流れが _summary_body を通っていない。置き場へ送れたときは要約だけを載せること")
	assert(flow.contains("_upload_report("),
		"送る流れが _upload_report を通っていない。詳細を置き場へ送ること")
	brief.queue_free()
	await process_frame

	var reporter: Node = maker_script.new()
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
