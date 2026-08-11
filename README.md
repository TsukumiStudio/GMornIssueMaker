# GMornIssueMaker

## 概要

遊んでいるその場から不具合を報告するためのGodotアドオン。

画面の隅に小さな報告ボタン（虫の絵）を常に出す。押すとその瞬間の画面を撮り、動作中の状況を添えて中継サーバーへ送る。中継サーバーがGitHubのIssueを作る。

報告の中身は、人が読むためだけでなく**状況を機械が追えるように**組み立てる。版、環境、画面の大きさ、開いているシーン、直前の操作、アプリ固有の値を、決まった見出しの表で並べる。

## 動作環境

- Godot 4.x（4.7で確認）
- HTTPを受け付けるサーバー1つ。用意しなくても動く（その場合は報告をローカルへ書き出す）
- GitHubへIssueを作る権限のあるトークン1つ。**アプリではなくサーバーに置く**

画面のない実行（`--headless`）では撮影を飛ばし、状況だけで報告する。

## 何ができるか

- **その瞬間の画面を撮る**。撮る前に報告ボタン自身を消し、描画が1回終わってから読むので、報告したかった画面がボタンで隠れない。縦1080に収まるよう縮める。
- **状況を集めて表にする**。次の見出しで並ぶので、読む側は毎回同じ場所を見れば済む。

  | 見出し | 中身 |
  | --- | --- |
  | アプリ | 名前、版、デバッグビルドかどうか |
  | 環境 | OS、OSの版、エンジンの版、描画装置、言語、CPU |
  | 画面 | 窓の大きさ、描画範囲、全画面かどうか |
  | 実行 | 毎秒の描画数、起動からの秒数、ノード数、静的メモリ、開いているシーン |
  | ゲームの状況 | アプリが足したもの |
  | 直前の出来事 | アプリが残したもの |

- **アプリ固有の状況を足せる**。`Dictionary` を返す関数を登録する。
- **直前の操作を残せる**。節目で1行ずつ記録する。直近30件が報告に並ぶ。
- **送れなくても報告を捨てない**。送信先が未設定のときや通信に失敗したときは `user://gmorn_issue_maker/` へJSONで書き出す。
- **アプリに鍵を持たせない**。配布物へ入れた鍵は取り出せるため、Issueを作る権限のあるトークンは同梱できない。アプリは送信先だけを持ち、鍵はサーバーが持つ。

## 使い方

### 1. 取り込む

アドオン一式をリポジトリ直下へ置いてある。取り込む側の `addons/gmorn_issue_maker` へそのまま submodule として足せる。

```
git submodule add https://github.com/TsukumiStudio/GMornIssueMaker.git addons/gmorn_issue_maker
```

Godotのエディタで「プロジェクト設定 → プラグイン」から `GMornIssueMaker` を有効にする。自動読み込みへ `GMornIssueMaker` が登録される。

置き場所は決め打ちにしていない。別の名前の場所へ入れても、自分の居場所から辿って登録する。スクリプト同士の参照も相対なので、パスを直す必要は無い。

### 2. 中継サーバーを立てる

`server/cloudflare-worker.js` をそのまま使える。Cloudflare Workers に貼り、変数を3つ入れる。

| 変数 | 中身 |
| --- | --- |
| `GITHUB_TOKEN` | Issueを作る権限のあるトークン |
| `GITHUB_REPO` | `owner/name` |
| `SHARED_SECRET` | アプリ側と揃える合言葉（空なら確認しない） |

画像はIssueへ直接貼れないため、リポジトリの `gmorn-issue-screenshots` ブランチへ置いてから本文にリンクを差し込む。既定のブランチへ積むと報告のたびに履歴が汚れるので分けてある。ブランチが無ければ作る。

自前で書く場合は、次の形のJSONをPOSTで受け取れればよい。`html_url` を含むJSONを返すと、アプリ側にIssueのURLが出る。

```json
{
  "title": "見出し",
  "body": "Markdown の本文",
  "labels": ["bug"],
  "context": { "...": "組み立て済みの状況" },
  "screenshot_png_base64": "iVBORw0K...",
  "library": { "name": "GMornIssueMaker", "version": "0.1.1" }
}
```

### 3. 設定する

決め方は3段ある。後のものが前のものを上書きする。

1. 既定値
2. プロジェクト設定（`gmorn_issue_maker/...`）
3. 環境変数（`GMORN_ISSUE_*`）

| 項目 | プロジェクト設定 | 環境変数 | 既定 |
| --- | --- | --- | --- |
| 送信先 | `gmorn_issue_maker/endpoint` | `GMORN_ISSUE_ENDPOINT` | 空 |
| 合言葉 | `gmorn_issue_maker/shared_secret` | `GMORN_ISSUE_SECRET` | 空 |
| 出す／出さない | `gmorn_issue_maker/enabled` | `GMORN_ISSUE_DISABLED=1` で切る | 出す |
| ボタンの位置 | `gmorn_issue_maker/button_corner` | — | `top_right` |
| ボタンの文字 | `gmorn_issue_maker/button_text` | — | 空（虫の絵だけ） |
| ボタンの大きさ | `gmorn_issue_maker/button_width` / `button_height` | — | `40` / `40` |
| 描画の層 | `gmorn_issue_maker/canvas_layer` | — | `512` |
| 札 | `gmorn_issue_maker/labels` | — | `bug, in-game-report` |

送信先は配布物へ入るので、公開して構わないものを置く。合言葉のように配りたくないものは環境変数で渡す。

### 4. アプリ固有の状況を足す

```gdscript
func _ready() -> void:
    var reporter := get_node_or_null("/root/GMornIssueMaker")
    if reporter == null:
        return
    reporter.add_context_provider(func() -> Dictionary:
        return {
            "面": current_stage_name(),
            "残機": player.lives,
            "経過時間": "%.1f秒" % elapsed_seconds,
        })
```

部品が入っていない環境でも動くよう、`get_node_or_null` で確かめてから使う。

### 5. 直前の操作を残す

不具合報告でいちばん足りないのは「何をしたか」である。画面遷移や購入など、節目で呼んでおくと経路を追える。

```gdscript
reporter.leave_breadcrumb("タイトルからゲームへ")
reporter.leave_breadcrumb("面3を開始")
reporter.leave_breadcrumb("ショップで回復薬を購入")
```

### その他の口

| 呼び出し | 何をするか |
| --- | --- |
| `open_report_form()` | ボタンを押したときと同じ流れを始める。任意のキーへ割り当てたいときに使う |
| `set_button_visible(false)` | 撮影や配信のあいだだけボタンを隠す |
| `collect_context()` | いまの状況を `Dictionary` で取る |
| `report_started` / `report_finished(success, url, message)` | 送信の始まりと終わり |

### 手を入れる

リポジトリ直下の `project.godot` と `verify.gd` は、この部品だけを開いて手を入れるためのもの。取り込む側は使わない。

```
godot --headless --path addons/gmorn_issue_maker --script verify.gd
```

で、設定の読み込みから報告の組み立てまでが通ることを確かめられる。

## ライセンス

Unlicense（パブリックドメイン）。
