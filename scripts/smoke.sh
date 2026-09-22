#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP="${1:-$HOME/Applications/Onward.app}"
codesign --verify --strict "$APP"
"$APP/Contents/MacOS/Onward" --smoke-test
