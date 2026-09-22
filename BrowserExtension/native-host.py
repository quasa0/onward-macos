#!/usr/bin/env python3
"""Browser-owned native messaging process; exits when the browser closes its pipe."""
import json
import math
import os
from pathlib import Path
import struct
import sys
import time

MAX_MESSAGE = 250_000


def read_exact(stream, size):
    chunks = bytearray()
    while len(chunks) < size:
        chunk = stream.read(size - len(chunks))
        if not chunk:
            return None
        chunks.extend(chunk)
    return bytes(chunks)


def fresh(value, now):
    return type(value) in (int, float) and math.isfinite(value) and 0 <= now - value < 8


def control(directory, bundle, now):
    try:
        state = json.loads((directory / 'observer-status.json').read_text())
        return {'enabled': bool(isinstance(state, dict) and state.get('enabled') is True
                                and state.get('bundleID') == bundle and fresh(state.get('updatedAt'), now))}
    except (OSError, ValueError, TypeError):
        return {'enabled': False}


def respond(stream, value):
    data = json.dumps(value, allow_nan=False).encode()
    stream.write(struct.pack('<I', len(data)) + data)
    stream.flush()


def handle(message, directory, bundle, now):
    if not isinstance(message, dict):
        raise ValueError('Expected a JSON object')
    state = control(directory, bundle, now)
    if message.get('type') != 'snapshot' or not state['enabled']:
        return state
    if not all(isinstance(message.get(key), str) for key in ('text', 'title', 'url')):
        raise ValueError('Invalid snapshot text or identity')
    if not fresh(message.get('capturedAt'), now):
        raise ValueError('Stale snapshot')
    warnings = message.get('warnings', [])
    if not isinstance(warnings, list):
        raise ValueError('Invalid snapshot warnings')
    snapshot = {key: message[key] for key in ('capturedAt', 'title', 'url')}
    snapshot['text'] = message['text'][:24000]
    snapshot['warnings'] = [str(w)[:500] for w in warnings[:20]]
    if type(message.get('tabId')) is int:
        snapshot['tabId'] = message['tabId']
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    target = directory / f'browser-{bundle}.json'
    temporary = target.with_suffix(f'.{os.getpid()}.tmp')
    try:
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, 'w') as file:
            json.dump(snapshot, file, allow_nan=False)
        temporary.replace(target)
    finally:
        temporary.unlink(missing_ok=True)
    return state


def serve(input_stream, output_stream, directory, bundle, clock=time.time):
    while True:
        header = read_exact(input_stream, 4)
        if header is None:
            return
        size = struct.unpack('<I', header)[0]
        if size > MAX_MESSAGE:
            return
        body = read_exact(input_stream, size)
        if body is None:
            return
        try:
            respond(output_stream, handle(json.loads(body), directory, bundle, clock()))
        except (ValueError, TypeError, OSError) as error:
            respond(output_stream, {'enabled': False, 'error': str(error)})


if __name__ == '__main__':
    if len(sys.argv) < 2 or sys.argv[1] not in {
        'net.imput.helium', 'com.google.Chrome', 'com.brave.Browser',
        'com.microsoft.edgemac', 'org.chromium.Chromium',
    }:
        sys.exit('Expected a supported browser bundle ID')
    serve(sys.stdin.buffer, sys.stdout.buffer,
          Path.home() / 'Library/Application Support/Onward', sys.argv[1])
