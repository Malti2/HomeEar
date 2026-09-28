# HomeEar

A local-first macOS menu bar voice gateway. Speech recognition and request filtering stay on the Mac. Only qualifying text goes to Poke.

## Status

Development build. No release is available yet. macOS 26 or newer is required for Apple's SpeechTranscriber. This app is designed for macOS 27 and German by default.

## Privacy and setup

The first-run flow requests microphone access and downloads Apple's language asset if needed. The Poke V2 API key is stored in macOS Keychain. Recognized text and audio are not saved to disk. Eligible requests are sent by default after setup; use Pause microphone to stop capture. Background speech can still be mistaken for a request. Do not run unattended when people or a TV are talking near the microphone.

Local TTS is exposed over an MCP Streamable HTTP endpoint at `http://127.0.0.1:3000/mcp`. The app bundles a pinned version of Poke CLI and Node. Sign in to Poke once from HomeEar onboarding through your browser, then HomeEar manages the tunnel and reconnects it. The included CLI is an external runtime even though the UI and local voice pipeline are native Swift. Poke's inbound API delivers messages; its response does not include the agent's answer. OpenClaw is a future integration, not functional here.

## Build

GitHub Actions builds an unsigned, unnotarized development artifact on the `macos-26` ARM runner. It is not a safe automatic installer. Update checking only opens the official release page for manual review; no self-replacement is attempted. The project is generated with XcodeGen and uses macOS native frameworks. No secrets belong in this repository. Author: Malte.
