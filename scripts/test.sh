#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift test
node --test Tests/BrowserTests/*.test.mjs
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Tests/BrowserTests -p 'test_*.py' -v
node --check BrowserExtension/background.js
node --check BrowserExtension/popup.js
