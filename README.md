# Onward

A native macOS focus observer. Set one goal, use your Mac, and see a live signal in the menu bar and below the notch. Jev classifies text captured from your current app and browser. Apple Vision performs all OCR locally.

## Start

1. Open `~/Applications/Onward.app`.
2. Enable **App text** (Accessibility) and **Local OCR** (Screen Recording). macOS may require quitting and reopening Onward after changing Screen Recording permission.
3. Enter a goal and press **Start focus**. Onward starts with a blank goal and opens paused. You can also edit and apply your goal directly in its menu bar popover.

The first browser capture may request Automation permission. Allow it to read the active tab title and exact URL. For page text beyond Accessibility/OCR, enable **View → Developer → Allow JavaScript from Apple Events** in Helium/Chrome, or install the optional extension in `BrowserExtension/README.md`.

## Behavior

- **Green:** current activity directly serves the goal or supports it.
- **Yellow:** Jev selects off-goal activity, including when its probability is below 0.65.
- **Red:** confirmed distraction continues for 45 seconds (configurable).
- **Neutral:** only before the first established judgment for a goal. After that, the pill and menu bar keep the latest green, yellow, or red through checking, uncertainty, app/tab switches, pause, idle, and service interruptions.

Turning red plays your chosen warning when sound is enabled. **Settings → Reminders** offers ten sounds and an independent warning-volume slider. Selecting a sound previews it; **Preview** replays it. The low, descending double warning remains the default. Audio plays locally even when notification banners are disabled; banners do not add a second sound.

**Settings → Time cues** optionally marks passing time with a quiet sound every 5, 10, 15, or 30 seconds, or every minute. Cues align to actual clock boundaries: a 15-second interval plays at `:00`, `:15`, `:30`, and `:45`. Choose from five subtle sounds and adjust cue volume separately. Time cues start disabled, with Soft tick at 25% volume and a 15-second interval ready to try. When enabled they continue while focus is paused, stop during lock/sleep, and resume on the next future boundary without replaying missed cues. Warning sounds take priority over automatic cues. Sound choices, intervals, and volumes persist across restarts. All audio is original and bundled; regenerate it with `python3 scripts/warning-sound.py`, or validate it silently with `--check`.

Colors follow Jev’s latest clear answer. An **unclear** answer keeps the last green, yellow, or red status. It pauses the distraction timer and sends no new reminder. Fresh captures without readable evidence behave the same way. Repeated uncertain answers keep that color; a clear off-goal answer resumes the timer, while an on-goal or supporting answer turns green and clears it. The dashboard identifies a retained status, and the raw answer remains available for inspection. Probabilities are not a guarantee of correctness. Use **This is relevant** or **It's a distraction** to provide context for subsequent judgments. These corrections apply to the current app session. Exact model probabilities and confidence remain separate. Jev supplies choices, not generated explanations; UI messages are authored locally.

App activation invalidates old results immediately. Accessibility notifications trigger capture; a four-second poll detects tab/content changes that apps fail to notify. Unchanged evidence is reclassified every 20 seconds to keep the alert state fresh. Ordinary changed content is rate-limited to one request per three seconds; app activation can request immediately. Requests time out and service failures pause judgments for 20 seconds. Results are discarded when the goal, foreground process, or observed content changed while a request was running. A stale gap resets the distraction interval. Capture rechecks app, window, and tab identity after collecting text and OCR; mixed captures are discarded. Data sources are sampled sequentially, so a rapidly changing page is not an atomic snapshot.

Displayed color is separate from capture/classification state. Checking never replaces an established color or advances its displayed timer. App/tab switches, capture failures, and expired evidence invalidate the current judgment internally while retaining the last visual cue. A fresh clear judgment replaces that cue. Only changing or clearing the goal/context, or restarting the app, begins without a previous color; same-goal pause/resume preserves it. Errors and operational state remain visible in the dashboard and diagnostics, and retained colors cannot cause new alerts. A compact colored circle below the notch shows Onward's arrow, with no goal text or timer. It hides when the pointer comes within 24 points and returns after the pointer stays 44 points away for 0.35 seconds. It always passes mouse clicks through to the window below. The menu bar also uses a compact arrow icon; the full goal remains in its popover and the dashboard.

**Screen-edge glow** adds a slight yellow glow while drifting and a much wider, stronger red glow when distracted. Green has no glow. The effect follows the retained color through checking, appears on all four edges of each display, and breathes slowly without flashing. It passes clicks through and cannot take focus. Pause, idle, sleep, and inactive sessions hide the glow. Turn it off in **Settings → Reminders**. macOS Reduce Motion disables the breathing animation; the glow also respects Reduce Transparency.

Capture pauses during sleep, inactive user sessions, manual pause, and after five minutes without input. It resumes when activity returns. The observer does not change app focus or control user content. Onward itself is excluded from capture; opening its dashboard preserves the previous color and pauses the distraction timer while you inspect it.

## Data and permissions

The app captures bundle ID/PID, focused-window title, browser title and exact URL, selected text, focused element, bounded Accessibility text, browser page text, and locally recognized screen text. Capture provenance, truncation warnings, and timestamps are retained. Screenshots remain in memory only and are never sent to Jev or stored. **Inspect text** shows the latest capture. **Export last Jev request** saves the exact last submitted payload, including goal, context, recent activity, and questions. It can precede the latest capture.

Native Accessibility takes priority. For Electron apps, Onward requests the full accessibility tree once per app process through the documented `AXManualAccessibility` attribute. In T3 Code, it reads the selected project and thread from the named **Thread breadcrumb** landmark, excluding sidebar buttons and conversation text. Sufficient native content skips OCR. Sparse or unsupported trees retain local Vision fallback; T3 OCR keeps header/sidebar/main-content structure and corroborates the breadcrumb before identifying a workspace. Jev receives that active workspace separately and must apply project exclusions before considering incidental goal mentions or background agents.

The API key stays in macOS Keychain (`com.quasa0.Onward.typesafe`). Only `https://api.typesafe.ai/v1/systemone` receives classification requests. Redirects are rejected. No app server or TCP port is needed. Browser native messaging is local.

Local history is stored in `~/Library/Application Support/Onward/activity.jsonl`. It holds full text for changed/classified observations. The log rotates at 10 MB and retains one previous file. History can be disabled. There is no public deployment or automatic upload outside the requested TypeSafe classification.

## Build, install, verify

- `./scripts/test.sh` checks freshness, stable status during refresh, pointer avoidance, idle detection, escalation, uncertainty, Unicode bounds, payloads, response validation, browser text rendering, native-message framing, and browser/session freshness.
- `./scripts/install.sh` builds locally, signs with an available Apple Development identity (or ad-hoc), and installs to `~/Applications`.
- `./scripts/manage.sh start|stop|status` manages the app, records its PID, and captures logs in `.runtime/onward.log`. `start-background` opens it without moving focus; add `--resume` to resume the saved goal explicitly.
- `./scripts/smoke.sh` verifies the installed signature, retained display colors, local Vision OCR on a synthetic image, and nine authenticated Jev classifications, including native workspace identity versus incidental goal mentions. It uses the saved Keychain key.
- `Onward.app/Contents/MacOS/Onward --render-preview /tmp/onward-preview.png [now|activity|settings|hud] [ready|focused|drifting|distracted] [light|dark]` renders synthetic interface fixtures offscreen. It does not capture the screen, send requests, or change the saved goal. Run `./scripts/preview.sh` to generate light, dark, compact, empty, and HUD fixtures in `.runtime/previews`.
- `Onward.app/Contents/MacOS/Onward --replay-entry UUID` reclassifies one saved local observation with its saved goal and empty additional context. It prints only decision/probability/status, does not append history or change the session, and sends that saved text to Jev again.
- `Onward.app/Contents/MacOS/Onward --classify-image PATH BUNDLE_ID [REPEATS]` runs local OCR on a supplied image and classifies its text with the saved goal. It prints the extracted workspace and decision, sends no image, and does not append history or change the session. Repeat count is bounded to 1–5.
- `Onward.app/Contents/MacOS/Onward --capture-diagnostics` passively reads the current app and prints only source counts, active workspace, capture timing, and warnings.
- `Onward.app/Contents/MacOS/Onward --import-key-from /path/to/.env` imports `TYPESAFE_API_KEY` without putting it in the bundle or printing it.

Requires macOS 14+, Swift 5.10+, and a TypeSafe key. No package dependencies. The optional Chromium extension uses `chrome.debugger` and displays the browser's debugger banner. It is not needed for ordinary Helium tab identity, native app text, or local OCR.

Source reuse and evidence are recorded in `THIRD_PARTY_NOTICES.md` and `references/capture-architecture.md`.
