#!/usr/bin/env python3
"""Tiny provisioning regressions. No real runtime/model install, download, inference or user roots."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock

RESOURCE = Path(__file__).resolve().parents[1]/'Sources/RAWMasterAI/Resources/prepare_models.py'
spec = importlib.util.spec_from_file_location('prepare_models_readonly', RESOURCE)
models = importlib.util.module_from_spec(spec)
spec.loader.exec_module(models)


class ModelReadOnlyTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.base = Path(self.temporary.name).resolve()
        self.borrowed = self.base/'borrowed'
        self.borrowed.mkdir()
        self.owned = self.base/'owned'
        self.owned.mkdir()
        self.payload = b'fixed required model tiny fixture'*16
        self.target = self.borrowed/'weights.bin'
        self.target.write_bytes(self.payload)
        self.target.chmod(0o444)
        self.item = {'path': 'weights.bin', 'size': len(self.payload),
                     'sha256': hashlib.sha256(self.payload).hexdigest(),
                     'url': 'https://huggingface.co/fixed/revision/weights.bin'}
        self.manifest = self.owned/'manifest.json'
        self.manifest.write_text(json.dumps({'model': 'fixture', 'revision': 'fixed', 'files': [self.item]}))
        self.receipt = self.owned/'receipt.json'

    def tearDown(self):
        self.temporary.cleanup()

    def snapshot(self):
        result = {}
        for path in [self.borrowed, *self.borrowed.rglob('*')]:
            value = path.lstat()
            result[str(path.relative_to(self.borrowed))] = [value.st_dev, value.st_ino, value.st_size,
                value.st_mode, value.st_nlink, value.st_mtime_ns, value.st_ctime_ns,
                path.read_bytes() if path.is_file() else None]
        return result # atime intentionally excluded: kernel reads may update access time.

    def test_existing_borrowed_root_is_only_read_and_receipt_is_owned(self):
        before = self.snapshot()
        with mock.patch.object(models, 'emit'), mock.patch.object(models.urllib.request, 'build_opener') as network:
            models.prepare(self.manifest, self.borrowed, False, read_only=True, receipt_path=self.receipt)
        self.assertEqual(before, self.snapshot())
        network.assert_not_called()
        value = json.loads(self.receipt.read_text())
        self.assertTrue(value['verified'])
        self.assertTrue(value['readOnly'])
        self.assertEqual(value['reusedBytes'], len(self.payload))
        self.assertFalse((self.borrowed/'.rawmaster-downloads').exists())
        self.assertFalse((self.borrowed/'.rawmaster-model-receipt.json').exists())
        self.assertFalse((self.borrowed/'.rawmaster-prepare.lock').exists())

    def test_missing_readonly_model_and_inside_receipt_never_modify_root(self):
        before = self.snapshot()
        with mock.patch.object(models, 'emit'), self.assertRaisesRegex(ValueError, 'cannot contain receipt'):
            models.prepare(self.manifest, self.borrowed, False, True, self.borrowed/'receipt.json')
        self.assertEqual(before, self.snapshot())
        self.item['path'] = 'missing/file.bin'
        self.manifest.write_text(json.dumps({'model': 'fixture', 'revision': 'fixed', 'files': [self.item]}))
        with mock.patch.object(models, 'emit'), self.assertRaisesRegex(ValueError, 'Required model missing'):
            models.prepare(self.manifest, self.borrowed, False, True, self.receipt)
        self.assertEqual(before, self.snapshot())
        self.assertFalse(self.receipt.exists())

    def test_http_or_unapproved_redirect_destination_is_not_a_fallback(self):
        for url in ['http://huggingface.co/model', 'https://huggingface.co.evil.invalid/model',
                    'https://user:secret@huggingface.co/model', 'https://127.0.0.1/model', 'file:///tmp/model']:
            self.assertFalse(models.permitted_url(url))
        self.assertTrue(models.permitted_url('https://huggingface.co/fixed/resolve/revision/model'))
        self.assertTrue(models.permitted_url('https://cas-bridge.xethub.hf.co/fixed'))
        with self.assertRaisesRegex(ValueError, 'outside fixed provider'):
            models.RestrictedRedirect(False).redirect_request(None, None, 302, '', {}, 'https://other.invalid/model')

    def test_interruption_retains_only_owned_partial_and_never_publishes(self):
        root = self.base/'managed'
        class Response:
            status = 200
            def __init__(self): self.first = True
            def __enter__(self): return self
            def __exit__(self, *args): pass
            def read(self, count):
                if self.first:
                    self.first = False
                    return b'partial'
                raise InterruptedError('controlled tiny interruption')
        with mock.patch.object(models, 'emit'), mock.patch.object(models.urllib.request, 'build_opener') as opener:
            opener.return_value.open.return_value = Response()
            with self.assertRaises(InterruptedError):
                models.prepare(self.manifest, root, False, receipt_path=self.receipt)
        self.assertEqual((root/'.rawmaster-downloads'/(self.item['sha256']+'.part')).read_bytes(), b'partial')
        self.assertFalse((root/'weights.bin').exists())
        self.assertFalse(self.receipt.exists())
        self.assertEqual(self.target.read_bytes(), self.payload)


if __name__ == '__main__':
    unittest.main()
