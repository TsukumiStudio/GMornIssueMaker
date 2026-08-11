// GMornIssueMaker の中継サーバー（Cloudflare Workers 版）。
//
// ゲーム側にGitHubのトークンを持たせない。配布物へ入れた鍵は取り出せるため、
// 書き込み権限のあるトークンは同梱できない。ここが鍵を持ち、ゲームからは
// 送り先だけを見せる。
//
// 置き方:
//   1. Cloudflare のダッシュボードで Worker を作り、この中身を貼る
//   2. 変数（Secret）を3つ入れる
//        GITHUB_TOKEN   Issue を作る権限のあるトークン
//        GITHUB_REPO    "owner/name" 形式
//        SHARED_SECRET  ゲーム側と揃える合言葉（空なら確認しない）
//   3. 出来たURLをゲームの gmorn_issue_maker/endpoint に入れる
//
// 画面は Issue へ直接貼れないため、リポジトリの `gmorn-issue-screenshots`
// ブランチへ置いてから本文にリンクを差し込む。ブランチが無ければ作る。
//
// 荒らし対策:
//   公開アプリだと、この送り先URLも合言葉も配布物から取り出せる。誰でも叩ける
//   前提で、素通しにしない。大きさの上限は常に効く。回数の上限は KV を
//   `RATE_LIMIT` という名前で結んだときだけ効く（無ければ素通し）。
//     wrangler kv namespace create RATE_LIMIT
//   ダッシュボードの Rate limiting rules を使ってもよい。

const SCREENSHOT_BRANCH = "gmorn-issue-screenshots";

const MAX_BODY_BYTES = 3 * 1024 * 1024;  // 画像込みの受け取り上限
const MAX_TITLE_LENGTH = 200;
const MAX_TEXT_LENGTH = 20000;
const RATE_LIMIT_PER_HOUR = 20;  // 同じ相手から1時間に受け付ける件数

export default {
  async fetch(request, env) {
    if (request.method === "OPTIONS") {
      return new Response(null, { headers: corsHeaders() });
    }
    if (request.method !== "POST") {
      return json({ error: "POST してください" }, 405);
    }
    if (env.SHARED_SECRET && request.headers.get("X-GMorn-Token") !== env.SHARED_SECRET) {
      return json({ error: "合言葉が違います" }, 401);
    }
    // 大きすぎるものは読む前に断る。読んでから測ると、その時点で食わされている。
    const declared = Number(request.headers.get("Content-Length") || "0");
    if (declared > MAX_BODY_BYTES) {
      return json({ error: "大きすぎます" }, 413);
    }
    const limited = await checkRateLimit(env, request);
    if (limited) {
      return limited;
    }

    let payload;
    try {
      payload = await request.json();
    } catch (_) {
      return json({ error: "JSON として読めません" }, 400);
    }
    const title = (payload.title || "").trim().slice(0, MAX_TITLE_LENGTH);
    if (!title) {
      return json({ error: "title が空です" }, 400);
    }

    let body = (payload.body || "").slice(0, MAX_TEXT_LENGTH);
    if (payload.screenshot_png_base64) {
      try {
        const url = await uploadScreenshot(env, payload.screenshot_png_base64);
        // 画像は本文の先頭へ置く。読む側が最初に見るのは絵である。
        body = `![報告時の画面](${url})\n\n${body}`;
      } catch (error) {
        body = `（画面の保存に失敗: ${error.message}）\n\n${body}`;
      }
    }

    const created = await githubRequest(env, `/repos/${env.GITHUB_REPO}/issues`, "POST", {
      title,
      body,
      labels: Array.isArray(payload.labels) ? payload.labels : undefined,
    });
    return json({ html_url: created.html_url, number: created.number }, 201);
  },
};

async function uploadScreenshot(env, base64) {
  const path = `screenshots/${Date.now()}-${Math.random().toString(36).slice(2, 8)}.png`;
  await ensureBranch(env);
  const created = await githubRequest(
    env,
    `/repos/${env.GITHUB_REPO}/contents/${path}`,
    "PUT",
    {
      message: `GMornIssueMaker: ${path}`,
      content: base64,
      branch: SCREENSHOT_BRANCH,
    }
  );
  return created.content.download_url;
}

// 画像を置くためだけのブランチを用意する。既定のブランチへ積むと、
// 報告のたびに履歴が汚れる。
async function ensureBranch(env) {
  const repo = await githubRequest(env, `/repos/${env.GITHUB_REPO}`, "GET");
  try {
    await githubRequest(env, `/repos/${env.GITHUB_REPO}/git/ref/heads/${SCREENSHOT_BRANCH}`, "GET");
    return;
  } catch (_) {
    // 無いので作る
  }
  const base = await githubRequest(
    env,
    `/repos/${env.GITHUB_REPO}/git/ref/heads/${repo.default_branch}`,
    "GET"
  );
  await githubRequest(env, `/repos/${env.GITHUB_REPO}/git/refs`, "POST", {
    ref: `refs/heads/${SCREENSHOT_BRANCH}`,
    sha: base.object.sha,
  });
}

async function githubRequest(env, path, method, body) {
  const response = await fetch(`https://api.github.com${path}`, {
    method,
    headers: {
      Authorization: `Bearer ${env.GITHUB_TOKEN}`,
      Accept: "application/vnd.github+json",
      "User-Agent": "GMornIssueMaker",
      "Content-Type": "application/json",
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await response.text();
  if (!response.ok) {
    throw new Error(`GitHub ${response.status}: ${text.slice(0, 200)}`);
  }
  return text ? JSON.parse(text) : {};
}

// 同じ相手からの連投を抑える。KV を `RATE_LIMIT` で結んでいなければ何もしない。
// 抑えられなかったときに落とすより、受け取って動くほうを選ぶ（報告の口は塞がない）。
async function checkRateLimit(env, request) {
  if (!env.RATE_LIMIT) {
    return null;
  }
  const who = request.headers.get("CF-Connecting-IP") || "unknown";
  const hour = new Date().toISOString().slice(0, 13);
  const key = `rate:${who}:${hour}`;
  const seen = Number((await env.RATE_LIMIT.get(key)) || "0");
  if (seen >= RATE_LIMIT_PER_HOUR) {
    return json({ error: "しばらく待ってから送ってください" }, 429);
  }
  // 1時間で消える。取りこぼしても実害は無いので、書き込みの失敗は無視する。
  await env.RATE_LIMIT.put(key, String(seen + 1), { expirationTtl: 3600 }).catch(() => {});
  return null;
}

function json(value, status) {
  return new Response(JSON.stringify(value), {
    status,
    headers: { "Content-Type": "application/json", ...corsHeaders() },
  });
}

function corsHeaders() {
  return {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "Content-Type, X-GMorn-Token",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
  };
}
