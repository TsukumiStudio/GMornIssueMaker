# GMornIssueMaker

Godotから[MornIssueBridge](https://github.com/TsukumiStudio/MornIssueBridge)へ報告を送り、GitHub Issueを作成するライブラリです。

[環境構築](#環境構築) · [送信方法](#送信方法) · [ライセンス](#ライセンス)

## 環境構築

1. [MornIssueBridge](https://github.com/TsukumiStudio/MornIssueBridge#環境構築)をデプロイします。
2. このリポジトリを`addons/gmorn_issue_maker`に配置し、Godotの「プロジェクト設定 → プラグイン」で有効にします。
3. `project.godot`に送信先のURLとリポジトリを設定します。

```ini
[gmorn_issue_maker]
endpoint="https://YOUR-WORKER.workers.dev/"
repository="owner/repo"
```

日本語フォントを同梱しているため、フォントの準備は不要です。

## 送信方法

画面右上の報告ボタンを押し、見出しと本文を入力して送信します。スクリーンショットとゲームの状況が添付され、結果がフォームに表示されます。

作成するIssueには`bug`と`in-game-report`のラベルが付きます。

コードからも送信できます。

```gdscript
GMornIssueMaker.send_report("画面が進みません", "購入ボタンを押すと止まります。")
```

第3引数に`Image`を渡すと画像を添付します。送信結果は`report_finished(success, url, message)`で受け取れます。

ゲーム固有の状況は`add_context_provider()`、直前の操作は`leave_breadcrumb()`で添えられます。

送信に失敗した場合は、報告の控えを`user://gmorn_issue_maker/`に保存します。

## ライセンス

コードは[The Unlicense](UNLICENSE)、同梱の[Noto Sans JP](https://github.com/google/fonts/tree/66a36c8c94b1a5d992ee4e7f392fccfe4945767c/ofl/notosansjp)は[SIL Open Font License 1.1](fonts/OFL.txt)です。
