#!/usr/bin/env python3
"""Install the host for one explicit unpacked extension ID; no browser settings are changed."""
import json
from pathlib import Path
import re
import shutil
import sys

if len(sys.argv) != 2 or not re.fullmatch(r"[a-p]{32}", sys.argv[1]):
    sys.exit("Usage: python3 install-host.py EXTENSION_ID (from chrome://extensions)")
extension_id = sys.argv[1]
root = Path.home() / "Library/Application Support/Onward"
root.mkdir(mode=0o700, parents=True, exist_ok=True)
shutil.copy2(Path(__file__).with_name("native-host.py"), root / "native-host.py")
destinations = {
    "net.imput.helium": "net.imput.helium/NativeMessagingHosts",
    "com.google.Chrome": "Google/Chrome/NativeMessagingHosts",
    "com.brave.Browser": "BraveSoftware/Brave-Browser/NativeMessagingHosts",
    "com.microsoft.edgemac": "Microsoft Edge/NativeMessagingHosts",
    "org.chromium.Chromium": "Chromium/NativeMessagingHosts",
}
import shlex
for bundle, folder in destinations.items():
    launcher = root / f"host-{bundle}.sh"
    launcher.write_text(f"#!/bin/sh\nexec {shlex.quote(sys.executable)} {shlex.quote(str(root / 'native-host.py'))} {shlex.quote(bundle)} \"$@\"\n")
    launcher.chmod(0o700)
    directory = Path.home() / "Library/Application Support" / folder
    directory.mkdir(parents=True, exist_ok=True)
    manifest = {"name": "com.quasa0.onward", "description": "Onward browser text capture", "path": str(launcher), "type": "stdio", "allowed_origins": [f"chrome-extension://{extension_id}/"]}
    (directory / "com.quasa0.onward.json").write_text(json.dumps(manifest, indent=2) + "\n")
print("Native host installed. It only accepts this extension and captures during an active Onward session.")
