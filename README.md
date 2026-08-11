# GMornIssueMaker

遊んでいるその場から不具合を報告するためのGodotアドオン。

画面の隅に小さな報告ボタンを常に出す。押すとその瞬間の画面を撮り、いま動いている状況を添えて中継サーバーへ送る。中継サーバーがGitHubのIssueを作る。

報告の中身は、人が読むためだけでなく**状況を機械が追えるように**組み立てる。版、環境、画面の大きさ、いま開いているシーン、直前の出来事、ゲーム固有の値を決まった見出しで並べる。

## 入れ方

アドオン一式をリポジトリ直下へ置いてある。取り込む側の `addons/gmorn_issue_maker` へそのまま submodule として足せる。

```
git submodule add https://github.com/TsukumiStudio/GMornIssueMaker.git addons/gmorn_issue_maker
```

Godotのエディタで「プロジェクト設定 → プラグイン」から `GMornIssueMaker` を有効にする。自動読み込みへ `GMornIssueMaker` が登録される。

置き場所は決め打ちにしていない。別の名前の場所へ入れても、自分の居場所から辿って登録する。スクリプト同士の参照も相対で書いてあるので、パスを直す必要は無い。

リポジトリ直下の `project.godot` と `verify.gd` は、この部品だけを開いて手を入れるためのもの。取り込む側は使わない。

```
godot --headless --path addons/gmorn_issue_maker --script verify.gd
```

で、報告の中身が組み立てられることを確かめられる。

## 設定

決め方は3段ある。後のものが前のものを上書きする。

1. 既定値
2. プロジェクト設定（`gmorn_issue_maker/...`）
3. 環境変数（`GMORN_ISSUE_*`）

| 項目 | プロジェクト設定 | 環境変数 | 既定 |
| --- | --- | --- | --- |
| 送り先 | `gmorn_issue_maker/endpoint` | `GMORN_ISSUE_ENDPOINT` | 空 |
| 合言葉 | `gmorn_issue_maker/shared_secret` | `GMORN_ISSUE_SECRET` | 空 |
| 出す／出さない | `gmorn_issue_maker/enabled` | `GMORN_ISSUE_DISABLED=1` で切る | 出す |
| ボタンの位置 | `gmorn_issue_maker/button_corner` | — | `top_right` |
| ボタンの文字 | `gmorn_issue_maker/button_text` | — | `不具合報告` |
| 描画の層 | `gmorn_issue_maker/canvas_layer` | — | `512` |
| 札 | `gmorn_issue_maker/labels` | — | `bug, in-game-report` |

送り先は配布物へ入るので、公開して構わないものを置く。**GitHubのトークンはゲームに持たせない**。配布物へ入れた鍵は取り出せるため、書き込み権限のあるトークンは同梱できない。鍵は中継サーバーが持つ。

送り先が空のときは送信を試みず、報告を `user://gmorn_issue_maker/` へ書き出す。送信に失敗したときも同じ場所へ残す。せっかく書いた内容を捨てない。

## ゲーム固有の状況を足す

`add_context_provider` に `Dictionary` を返す関数を渡す。報告の「ゲームの状況」へ並ぶ。

```gdscript
func _ready() -> void:
    var reporter := get_node_or_null("/root/GMornIssueMaker")
    if reporter != null:
        reporter.add_context_provider(func() -> Dictionary:
            return {
                "日数": GameState.day(),
                "所持金": GameState.money(),
                "画面": screen_state_name(),
            })
```

## 何をしたかを残す

不具合報告でいちばん足りないのは「何をしたか」である。節目で `leave_breadcrumb` を呼んでおくと、報告に直前の流れが並ぶ。

```gdscript
reporter.leave_breadcrumb("勤務を開始")
reporter.leave_breadcrumb("スマホでアップグレードを購入: 流量アップ")
```

直近30件を覚える。それ以上は古いものから捨てる。

## 中継サーバー

`server/cloudflare-worker.js` をそのまま使える。Cloudflare Workers に貼り、変数を3つ入れるだけで動く。

| 変数 | 中身 |
| --- | --- |
| `GITHUB_TOKEN` | Issue を作る権限のあるトークン |
| `GITHUB_REPO` | `owner/name` |
| `SHARED_SECRET` | ゲーム側と揃える合言葉（空なら確認しない） |

画面はIssueへ直接貼れないため、リポジトリの `gmorn-issue-screenshots` ブランチへ置いてから本文にリンクを差し込む。既定のブランチへ積むと報告のたびに履歴が汚れるので分けてある。ブランチが無ければ作る。

自前で書く場合は、次の形の JSON を POST で受け取れればよい。

```json
{
  "title": "見出し",
  "body": "Markdown の本文",
  "labels": ["bug"],
  "context": { "...": "組み立て済みの状況" },
  "screenshot_png_base64": "iVBORw0K...",
  "library": { "name": "GMornIssueMaker", "version": "0.1.0" }
}
```

`html_url` を含む JSON を返すと、ゲーム側にIssueのURLが出る。

## 撮影に写り込まないこと

撮る前に報告ボタンを消し、描画が1回終わるのを待ってから読む。報告したかった画面がボタンで隠れない。

配信や撮影のあいだだけ隠したいときは `set_button_visible(false)` を呼ぶ。

## ライセンス

Unlicense（パブリックドメイン）。
