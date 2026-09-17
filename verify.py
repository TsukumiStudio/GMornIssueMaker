"""ローカルHTTPサーバーを使ってGodotからの送信を検証します。"""
import http.server
import base64
import json
import os
from pathlib import Path
import shutil
import random
import subprocess
import tempfile
import threading

requests = []


class Bridge(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        payload = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        requests.append(payload)
        assert self.headers['Content-Type'] == 'application/json'
        assert not self.headers.get('X-GMorn-Token')
        assert not self.headers.get('Authorization')
        assert payload['repository'] == 'example/game'
        assert set(payload) <= {'repository', 'title', 'body', 'labels', 'screenshot_png_base64'}
        status, body = 201, {'html_url': 'https://github.com/example/game/issues/42', 'number': 42}
        if payload['title'] == '拒否':
            status, body = 429, {'error': '送信回数の上限です。'}
        elif payload['title'] == 'ログイン画面':
            status, body = 200, '<html>Login</html>'
        elif payload['title'] == '切断':
            self.close_connection = True
            return
        elif payload['title'] == '不正な成功':
            body = {'html_url': 'https://example.com/', 'number': 42}
        data = (body if isinstance(body, str) else json.dumps(body, ensure_ascii=False)).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *_args):
        pass


addon = Path(__file__).resolve().parent
with tempfile.TemporaryDirectory(prefix='gmorn-issue-verify-') as directory:
    work = Path(directory)
    target = work / 'addons/gmorn_issue_maker'
    target.mkdir(parents=True)
    for source in [*addon.glob('*.gd'), addon / 'plugin.cfg']:
        shutil.copy(source, target)
    shutil.copytree(addon / 'fonts', target / 'fonts')
    shutil.copy(addon / 'verify.gd', work)
    shutil.copy(addon / 'plugin.cfg', work)
    (work / 'noise.rgb').write_bytes(random.Random(0).randbytes(1920 * 1080 * 3))
    (work / 'project.godot').write_text('config_version=5\n[application]\nconfig/name="GMornIssueMaker Verify"\nconfig/features=PackedStringArray("4.7")\n')
    env = dict(os.environ)
    env.update(HOME=str(work / 'home'), XDG_DATA_HOME=str(work / 'data'))
    godot = env.get('GODOT_BIN', shutil.which('godot') or '/Applications/Godot.app/Contents/MacOS/Godot')
    imported = subprocess.run([godot, '--headless', '--editor', '--path', str(work), '--quit'], env=env, capture_output=True, text=True, timeout=30)
    assert imported.returncode == 0 and 'ERROR:' not in imported.stdout + imported.stderr, imported.stdout + imported.stderr
    with http.server.ThreadingHTTPServer(('127.0.0.1', 0), Bridge) as server:
        threading.Thread(target=server.serve_forever, daemon=True).start()
        env['MOCK_BRIDGE_URL'] = f'http://127.0.0.1:{server.server_port}/'
        try:
            result = subprocess.run([godot, '--headless', '--path', str(work), '--script', 'verify.gd'], env=env, capture_output=True, text=True, timeout=30)
        finally:
            server.shutdown()
    print(result.stdout, end='')
    print(result.stderr, end='')
    assert result.returncode == 0 and 'GMORN ISSUE MAKER VERIFY: PASS' in result.stdout
    assert 'SCRIPT ERROR' not in result.stderr and 'ERROR:' not in result.stderr
    assert len(requests) == 5, requests
    for payload in requests:
        assert payload.get('labels') == ['bug', 'in-game-report'], payload.get('labels')
        png = base64.b64decode(payload['screenshot_png_base64'], validate=True)
        assert 0 < len(png) <= 2 * 1024 * 1024, f'PNG容量超過: {len(png)} bytes'
        assert png.startswith(b'\x89PNG\r\n\x1a\n')
    assert '詳細' * 800 in requests[0]['body']
    assert requests[0]['screenshot_png_base64'].startswith('iVBOR')
