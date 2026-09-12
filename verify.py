"""ローカルHTTPサーバーを使ってGodotからの送信を検証します。"""
import http.server
import json
import os
from pathlib import Path
import shutil
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
        assert payload['reporter_id'] == 'player-1'
        assert payload['reporter_name'] == '送信者'
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
    (work / 'verify.gd').write_text((addon / 'verify.gd').read_text().replace('res://gmorn_', 'res://addons/gmorn_issue_maker/gmorn_'))
    shutil.copy(addon / 'plugin.cfg', work)
    (work / 'project.godot').write_text('config_version=5\n[application]\nconfig/name="GMornIssueMaker Verify"\nconfig/features=PackedStringArray("4.7")\n')
    env = {key: value for key, value in os.environ.items() if not key.startswith('GMORN_ISSUE_')}
    env.update(HOME=str(work / 'home'), XDG_DATA_HOME=str(work / 'data'))
    with http.server.ThreadingHTTPServer(('127.0.0.1', 0), Bridge) as server:
        threading.Thread(target=server.serve_forever, daemon=True).start()
        env['MOCK_BRIDGE_URL'] = f'http://127.0.0.1:{server.server_port}/'
        try:
            result = subprocess.run([env.get('GODOT_BIN', shutil.which('godot') or '/Applications/Godot.app/Contents/MacOS/Godot'), '--headless', '--path', str(work), '--script', 'verify.gd'], env=env, capture_output=True, text=True, timeout=30)
        finally:
            server.shutdown()
    print(result.stdout, end='')
    print(result.stderr, end='')
    assert result.returncode == 0 and 'GMORN ISSUE MAKER VERIFY: PASS' in result.stdout
    assert 'SCRIPT ERROR' not in result.stderr and 'ERROR:' not in result.stderr
    assert len(requests) == 5, requests
    assert '詳細' * 800 in requests[0]['body']
    assert requests[0]['screenshot_png_base64'].startswith('iVBOR')
