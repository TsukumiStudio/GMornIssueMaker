# GMornIssueMaker

Godotから[MornIssueBridge](https://github.com/TsukumiStudio/MornIssueBridge)へ不具合報告を送信するライブラリです。報告フォーム、スクリーンショット、実行環境、ゲームの状況をまとめて送信できます。

## 環境構築

1. [MornIssueBridgeのREADME](https://github.com/TsukumiStudio/MornIssueBridge#環境構築)に従って送信先を用意します。
2. このリポジトリを`addons/gmorn_issue_maker`へ配置し、Godotの「プロジェクト設定 → プラグイン」で有効にします。
3. プロジェクト設定に次の2項目を指定します。

```ini
[gmorn_issue_maker]
endpoint="https://your-worker.workers.dev/"
repository="owner/repo"
```

日本語を表示する場合は`font_path`にフォントを指定します。未指定なら`gui/theme/custom_font`を使います。ボタンの位置・大きさやラベルは、同じ設定欄で変更できます。

GitHubトークンはMornIssueBridge側に設定します。旧版の`drop_endpoint`、`image_endpoint`、`shared_secret`は使用しません。環境変数`GMORN_ISSUE_ENDPOINT`と`GMORN_ISSUE_REPOSITORY`で送信先を上書きできます。

## 送信方法

画面右上の報告ボタンを押し、見出しと本文を入力して送信します。報告時の画面と状況を添え、指定したリポジトリにIssueを作成します。送信結果はフォームに表示されます。

コードから送る場合は、Autoloadの準備後に`send_report()`を呼び出します。

```gdscript
func _ready() -> void:
    GMornIssueMaker.report_finished.connect(_on_report_finished)

func report_problem() -> void:
    var error := GMornIssueMaker.send_report("進行できません", "購入ボタンを押すと止まります。")
    if error != OK:
        print("送信を開始できませんでした: ", error)

func _on_report_finished(success: bool, url: String, message: String) -> void:
    print(message)
```

第3引数に`Image`を渡すとPNG画像を添付します。省略時は撮影しません。送信者を記録する場合は、送信前に`GMornIssueMaker.settings.reporter_id`と`reporter_name`を設定します。

`send_report()`の`OK`は通信開始を表します。結果は`report_finished(success, url, message)`で通知します。送信中は`ERR_BUSY`、見出しが空なら`ERR_INVALID_PARAMETER`を返し、この2つの場合は通知しません。設定不足や通信開始時の失敗は、その場で失敗を通知します。

ゲーム固有の状況や直前の操作も添付できます。

```gdscript
GMornIssueMaker.add_context_provider(func() -> Dictionary:
    return {"ステージ": current_stage, "残機": lives})
GMornIssueMaker.leave_breadcrumb("ショップを開きました")
```

`open_report_form()`でフォームを開き、`set_button_visible(false)`で標準ボタンを隠せます。`build_payload(title, description, screenshot)`は送信せずにJSON用の辞書を組み立てます。

本文は状況を含めて20,000文字、見出しは200文字、PNGは2MiBまでです（文字数はMornIssueBridgeのUTF-16単位）。上限を超えた場合など、送信に失敗すると送信時の内容を`user://gmorn_issue_maker/`へJSONで保存します。自動再送はしません。通信が途切れた場合はIssueが作成済みの可能性があるため、再送前にリポジトリを確認してください。

検証は`./verify.sh`で実行できます。GodotとPython 3を使い、一時プロジェクトとローカルHTTPサーバーで送信・失敗時の保存を確認します。

## ライセンス

[The Unlicense](UNLICENSE)です。
