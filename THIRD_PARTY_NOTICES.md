# Third-party notices

## OpenAI Codex

Copyright 2025 OpenAI. Licensed under Apache License 2.0; see `references/CODEX-LICENSE` in the source project or `Contents/Resources/CODEX-LICENSE` in the application bundle.

`Sources/OnwardCore/Observation.swift` ports the Unicode-safe byte-bounding algorithm from `codex-rs/utils/string/src/lib.rs` (`take_bytes_at_char_boundary`) at commit `d583e73c4d1204f1e9f654ef87065e9f0dd07ac7`. The port is modified for Swift and returns an owned string.

Upstream source: https://github.com/openai/codex/tree/d583e73c4d1204f1e9f654ef87065e9f0dd07ac7. Its original `NOTICE` is preserved at `references/CODEX-NOTICE` (`Contents/Resources/CODEX-NOTICE` in the app). The upstream Ratatui notice describes Codex components not included in Onward. The complete upstream checkout is not required or included.

The app's platform capture, browser extension, native host, renderer, classifier, and UI are independent implementations. Their architecture follows the observed separation between native Accessibility capture, browser CDP capture, structured text, and image observations. No private OpenAI runtime, binary, JavaScript bundle, or WebAssembly module is redistributed or required by Onward.
