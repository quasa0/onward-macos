# Rich browser context (optional)

Onward already reads browser tab titles and exact URLs using Apple events. Accessibility and local OCR work without this extension. This companion adds Chromium's structured accessibility tree and DOM text, using the CDP capture APIs observed in Codex.

1. Open `chrome://extensions` in Helium or Chrome. Enable Developer mode.
2. Choose **Load unpacked** and select this `BrowserExtension` folder.
3. Copy the extension ID. Run `python3 install-host.py EXTENSION_ID` from this folder.
4. Start a focus session in Onward. Return to a normal web page.

The browser shows its debugger banner while capture is enabled. Use the extension popup to disable capture. Dismissing the debugger banner suppresses capture for that tab until a tab change or explicit re-enable. Another debugger, including DevTools or another automation extension, can prevent attachment. Capture failure is visible in the popup; native Accessibility and OCR continue in Onward.

The extension uses `Page.getFrameTree`, `DOMSnapshot.captureSnapshot`, and `Accessibility.getFullAXTree`. It handles same-process frames and attempts flattened sessions for cross-process iframes. Missing frames produce warnings. It collects only the active tab in the focused browser window, and only while the native app reports a fresh, active focus session for that browser. DOM text can include off-screen content. Text is bounded before it reaches Jev. No screenshot is taken by the extension.

Native messaging uses 4-byte little-endian length-prefixed JSON. The Python host exists only for its browser connection and exits on EOF. It writes one replaceable local snapshot per browser. The native app accepts it only if its URL and title match the active tab and it is less than 8 seconds old. There is no TCP listener.

To remove: remove the extension, delete `com.quasa0.onward.json` from the browser's `NativeMessagingHosts` folder, and remove Onward's `host-*.sh` and `native-host.py` files in `~/Library/Application Support/Onward`.
