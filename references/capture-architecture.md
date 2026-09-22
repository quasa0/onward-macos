# Capture reference map

Investigation: 2026-09-21. Public source: https://github.com/openai/codex/tree/d583e73c4d1204f1e9f654ef87065e9f0dd07ac7

The original investigation used an adjacent `../codex-source` checkout. A fresh checkout of Onward does not need that directory; use the pinned public source link above for reference. Reusable architectural patterns are implemented in Onward; keep this map for extending the capture system.

| Codex mechanism | Evidence | Onward equivalent |
| --- | --- | --- |
| Computer tools outside the model/runtime core | `codex-rs/plugin/src/bundled_hooks.rs`; `core/src/mcp_tool_call.rs` | CaptureEngine is separate from JevClient and FocusPolicy |
| Unicode-safe bounded context | `codex-rs/utils/string/src/lib.rs` | Swift port `boundedText`, with Apache attribution |
| Bounded observations with provenance | `core/src/context/node_repl_review_evidence.rs` | Observation sources, warnings, timestamps, fingerprints, local history, byte limits |
| Native AX text and separate image output | Installed Sky `get_app_state`/`window_result` wrappers and API definitions | AXRead + ScreenCaptureKit + local Vision OCR |
| AXObserver and NSWorkspace activation | Imports in installed SkyComputerUseService binary | Native observer notifications plus periodic capture |
| Browser frame tree, DOM snapshot, full AX tree | Installed `@oai/browser-desktop/scripts/browser-service.mjs` | Optional BrowserExtension with per-frame CDP capture |
| Snapshot identity and stale-result rejection | Browser runtime tab/frame/loader provenance | PID, exact URL, fingerprint, goal revision, timestamp validation |
| Length-prefixed local messages | Installed Sky native pipe transport | Browser-owned native messaging host; no network listener |
| Incremental observations | Native/browser full/diff interfaces | Fingerprint deduplication, fresh full Jev context per judgment |

Onward deliberately sends full bounded state with each Jev call: each call is stateless, so a diff alone could hide the evidence that justified the previous judgment. The classifier retains five recent activity summaries and up to six user corrections within the running session. It never sends image bytes.

## Platform sources

- https://developer.apple.com/documentation/applicationservices/axuielement
- https://developer.apple.com/documentation/appkit/nsworkspace/didactivateapplicationnotification
- https://developer.apple.com/documentation/screencapturekit/scscreenshotmanager
- https://developer.apple.com/documentation/vision/vnrecognizetextrequest
- https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/Multithreading/ThreadSafetySummary/ThreadSafetySummary.html (NSAppleScript runs on the main actor)
- https://developer.chrome.com/docs/extensions/reference/api/debugger
- https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging
- https://docs.typesafe.ai/api

## Boundaries

This is a passive observer. Capture must not activate a target app, click, type, scroll, or alter user content. OS Accessibility provides app-exposed text, not an exhaustive document export. Vision reads only visible text in the focused app window. Browser DOM captures can include off-screen content; these are labeled separately. Hidden iframe content, inaccessible custom views, DRM surfaces, and unlabeled graphics can remain unavailable. No capture path can prove the user's actual intent.
