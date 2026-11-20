#!/usr/bin/env python3
"""Deterministic offline model acquisition failure/resume checks; no real model download."""
import hashlib
import http.server
import importlib.util
import json
from pathlib import Path
import tempfile
import threading
import unittest
from unittest import mock

RESOURCE = Path(__file__).resolve().parents[1]/'Sources/RAWMasterAI/Resources/prepare_models.py'
spec = importlib.util.spec_from_file_location('prepare_models', RESOURCE)
prepare = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prepare)


class ModelDownloadTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.payload = b'fixed model fixture bytes'*100
        payload = self.payload
        self.ranges = []
        ranges = self.ranges
        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass
            def do_GET(self):
                offset = int(self.headers.get('Range', 'bytes=0-')[6:].split('-')[0])
                ranges.append(offset)
                self.send_response(206 if offset else 200)
                self.send_header('Content-Length', str(len(payload)-offset))
                if offset:
                    self.send_header('Content-Range', f'bytes {offset}-{len(payload)-1}/{len(payload)}')
                self.end_headers()
                self.wfile.write(payload[offset:])
        self.server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.item = {'path': 'qwen21-turbo/model.bin', 'size': len(payload), 'sha256': hashlib.sha256(payload).hexdigest(), 'url': f'http://127.0.0.1:{self.server.server_port}/model'}
        self.manifest = self.root/'manifest.json'
        self.manifest.write_text(json.dumps({'model': 'fixture', 'revision': 'fixed', 'files': [self.item]}))
        self.destination = self.root/'models'

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.temporary.cleanup()

    def test_resume_then_hash_verified_reuse(self):
        stage = self.destination/'.rawmaster-downloads'
        stage.mkdir(parents=True)
        (stage/(self.item['sha256']+'.part')).write_bytes(self.payload[:111])
        with mock.patch.object(prepare, 'emit'):
            prepare.prepare(self.manifest, self.destination, False, allow_test_http=True)
            prepare.prepare(self.manifest, self.destination, False, allow_test_http=True)
        self.assertEqual(self.ranges, [111])
        self.assertEqual((self.destination/self.item['path']).read_bytes(), self.payload)

    def test_wrong_download_never_publishes(self):
        self.item['sha256'] = '0'*64
        self.manifest.write_text(json.dumps({'model': 'fixture', 'revision': 'fixed', 'files': [self.item]}))
        with mock.patch.object(prepare, 'emit'), self.assertRaisesRegex(ValueError, 'hash/size'):
            prepare.prepare(self.manifest, self.destination, False, allow_test_http=True)
        self.assertFalse((self.destination/self.item['path']).exists())

    def test_existing_mismatch_is_preserved(self):
        target = self.destination/self.item['path']
        target.parent.mkdir(parents=True)
        target.write_bytes(b'private preexisting model')
        with mock.patch.object(prepare, 'emit'), self.assertRaisesRegex(ValueError, 'Existing model'):
            prepare.prepare(self.manifest, self.destination, False, allow_test_http=True)
        self.assertEqual(target.read_bytes(), b'private preexisting model')
        self.assertEqual(self.ranges, [])

    def test_traversal_rejected(self):
        self.item['path'] = '../escape.bin'
        self.manifest.write_text(json.dumps({'model': 'fixture', 'revision': 'fixed', 'files': [self.item]}))
        with self.assertRaisesRegex(ValueError, 'escapes'):
            prepare.prepare(self.manifest, self.destination, False, allow_test_http=True)


if __name__ == '__main__':
    unittest.main()
