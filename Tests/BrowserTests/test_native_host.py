import importlib.util
import io
import json
from pathlib import Path
import stat
import struct
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('host', Path(__file__).parents[2] / 'BrowserExtension/native-host.py')
host = importlib.util.module_from_spec(spec)
spec.loader.exec_module(host)


def frame(value):
    body = json.dumps(value).encode()
    return struct.pack('<I', len(body)) + body


class PartialPipe(io.BytesIO):
    def read(self, size=-1):
        return super().read(min(size, 3))


class NativeHostTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.bundle = 'net.imput.helium'
        self.state(enabled=True)

    def tearDown(self):
        self.temporary.cleanup()

    def state(self, enabled=True, bundle='net.imput.helium', updatedAt=999):
        (self.root / 'observer-status.json').write_text(json.dumps(dict(enabled=enabled, bundleID=bundle, updatedAt=updatedAt)))

    def snapshot(self, **changes):
        return dict(type='snapshot', title='Apple documentation', url='https://developer.apple.com/vision?a=1#ocr',
                    text='VNRecognizeTextRequest', capturedAt=999, warnings=[], tabId=42) | changes

    def test_partial_reads_and_eof(self):
        output = io.BytesIO()
        host.serve(PartialPipe(frame({'type': 'status'}) + frame(self.snapshot())), output, self.root, self.bundle, clock=lambda: 1000)
        output.seek(0)
        for _ in range(2):
            size = struct.unpack('<I', output.read(4))[0]
            self.assertEqual(json.loads(output.read(size)), {'enabled': True})
        self.assertEqual(output.read(), b'')
        saved = json.loads((self.root / f'browser-{self.bundle}.json').read_text())
        self.assertEqual(saved['url'], self.snapshot()['url'])
        self.assertEqual(stat.S_IMODE((self.root / f'browser-{self.bundle}.json').stat().st_mode), 0o600)

    def test_disabled_wrong_browser_stale_and_future_control_cannot_capture(self):
        for changes in ({'enabled': False}, {'bundle': 'com.google.Chrome'}, {'updatedAt': 991}, {'updatedAt': 1001}):
            with self.subTest(changes=changes):
                self.state(**changes)
                self.assertEqual(host.handle(self.snapshot(), self.root, self.bundle, 1000), {'enabled': False})
                self.assertFalse((self.root / f'browser-{self.bundle}.json').exists())

    def test_malformed_payload_and_timestamp_rejected(self):
        for bad in ([], None, self.snapshot(capturedAt=990), self.snapshot(capturedAt=1001),
                    self.snapshot(capturedAt=float('nan')), self.snapshot(capturedAt=True), self.snapshot(warnings='bad')):
            with self.subTest(bad=bad):
                with self.assertRaises(ValueError):
                    host.handle(bad, self.root, self.bundle, 1000)
        self.assertFalse((self.root / f'browser-{self.bundle}.json').exists())

    def test_oversized_and_truncated_frames_close_cleanly(self):
        for data in (b'\x01', struct.pack('<I', 100) + b'{}', struct.pack('<I', host.MAX_MESSAGE + 1)):
            output = io.BytesIO()
            host.serve(io.BytesIO(data), output, self.root, self.bundle)
            self.assertEqual(output.getvalue(), b'')

    def test_snapshot_bounds_and_unknown_fields(self):
        host.handle(self.snapshot(text='x' * 50000, warnings=['y' * 1000] * 40, screenshot='must not persist'), self.root, self.bundle, 1000)
        saved = json.loads((self.root / f'browser-{self.bundle}.json').read_text())
        self.assertEqual(len(saved['text']), 24000)
        self.assertEqual(len(saved['warnings']), 20)
        self.assertNotIn('screenshot', saved)
        self.assertEqual(list(self.root.glob('*.tmp')), [])


if __name__ == '__main__':
    unittest.main()
