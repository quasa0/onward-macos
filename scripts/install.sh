#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build.sh
./scripts/manage.sh stop
mkdir -p "$HOME/Applications"
mkdir -p "$HOME/Applications/Onward.app"
rsync -a --delete dist/Onward.app/ "$HOME/Applications/Onward.app/"
codesign --verify --strict "$HOME/Applications/Onward.app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$HOME/Applications/Onward.app"
printf 'Installed: %s/Applications/Onward.app\n' "$HOME"
