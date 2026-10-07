<div align="center">

# HomeEar

**A private voice gateway for your smart home on macOS.**

Keep HomeEar running in the menu bar throughout the day, if you choose. Say **“Hey Poke”** followed by a request, or just speak a likely command in German or English — HomeEar filters speech on your Mac and passes matching requests to your selected backend: Poke or built-in Home Assistant Assist. If you've connected Philips Hue, Home Assistant, or another smart-home service to Poke, your agent can use those connections to help with your home.

*Native menu bar UI · local speech recognition · Poke voice replies*

</div>

> **Development status:** This repository is a work in progress. The CI artifact is ad-hoc sealed for integrity, not Developer ID signed or notarized. No supported public release has been published. 0.1.4 adds a Sparkle updater and signed update artifacts; end-to-end installation and Gatekeeper behavior still need testing.

## The idea: an always-available home assistant

With the microphone enabled and the Mac awake, HomeEar can stay active around the clock and respond whenever you speak a likely command. You don't have to open an app or press a button for every request. For example, ask for the lights in the living room, a warmer bedroom, or a scene you use at night. HomeEar turns speech into a text request for Poke. Poke decides what to do through **your own connected integrations** and can call HomeEar's local voice tool to speak a reply on your Mac. If you configure proactive automations in Poke or your connected smart-home system, those services may also change your home without a new spoken command; HomeEar itself does not schedule, infer, or initiate autonomous home actions.

Select Poke or Home Assistant in Settings. Poke uses your own integrations. Direct Home Assistant sends finalized text to its built-in Conversation/Assist agent, using the configured server and a separate Keychain token. Expose intended devices to Assist in Home Assistant. Only the selected backend receives a request; there is no automatic fallback or retry after an uncertain result.

## How it works

```text
Mac microphone → Apple's on-device SpeechTranscriber → UtteranceRouter
    ├─ "Hey Poke" wake word (fuzzy, on partials+finals) → command → Poke inbound API
    └─ proactive filter (scored finals, no wake word needed) → Poke inbound API
                                        ↘ Poke tunnel → HomeEar voice tool → Mac speaker
```

- Recognition defaults to `de-DE`. English (`en-US`) is available in settings. The Mac must support the chosen on-device model and may need to download it first.
- Two input paths: the **“Hey Poke” wake word** is detected fuzzily in the live transcript (tolerating misrecognitions like “hey poak”), so an explicit invocation is understood reliably; a lone “Hey Poke” listens for your command for a few seconds. The **proactive filter** scores utterances without a wake word (command verbs, smart-home entities, polite framings) and forwards likely requests automatically. Both paths share a duplicate-suppression window so repeats are sent only once. The filter is heuristic, not a privacy guarantee — background speech could be sent by mistake. Pause the microphone from the menu bar whenever you need privacy.
- Audio is not uploaded or saved by HomeEar. Qualifying **text** is sent to the selected backend once it is configured and the microphone is active. HomeEar doesn't keep a transcript on disk.
- The Poke V2 API key lives in macOS Keychain. Outbound requests and the inbound voice tunnel have separate status indicators.
- The app includes a pinned Node.js and Poke CLI runtime for its local tunnel. The UI, audio pipeline, filter, Keychain access, and speech playback are native Swift. Sign in to Poke once in the browser through HomeEar's onboarding; the app then manages the tunnel and retries interrupted connections. This needs on-device validation before release.

## Build and current limitations

GitHub Actions generates the Xcode project and compiles for Apple Silicon on the macOS 26 runner. macOS 26 or newer is required; the target is macOS 27. Builds are **development artifacts only**. Developer ID signing and notarization are not configured. 0.1.4 uses Sparkle 2.10.0 to validate the signed release feed and archive before download/install/relaunch after user confirmation. Automatic checks start disabled. The first updater-enabled version must be installed manually; older versions cannot update themselves. End-to-end updating, browser-download Gatekeeper behavior, speech-model availability, Poke device login and tunnel interoperability still require on-device validation.

The local voice tool listens only on `127.0.0.1:3000`. Its MCP transport needs compatibility and security testing before a release, especially because any local process may access a loopback endpoint. No OpenClaw integration exists in v1; the agent-backend boundary is designed to allow it later.

## Privacy and safety

HomeEar can transmit text to Poke and Poke may act through services you've connected there. Confirm those connections and their permissions yourself. Avoid leaving the microphone running near other people, TV audio, or sensitive conversations. Neither the local filter nor a successful build proves it is safe to run unattended.

## Development

```sh
brew install xcodegen
xcodegen generate
xcodebuild -project HomeEar.xcodeproj -scheme HomeEar -configuration Release -arch arm64 CODE_SIGNING_ALLOWED=NO build
```

The CI workflow pins and checksums the bundled Node/Poke runtime. Never commit API keys, login tokens, or personal recordings.

## Installing a development package

The CI artifact contains a drag-to-Applications DMG and a ZIP. Copy HomeEar to Applications before running it. An unnotarized build may require your explicit confirmation in macOS System Settings > Privacy & Security > Open Anyway. This is not a notarized distribution and the exact prompt has not been verified on every macOS version. A damaged-app warning is a separate integrity failure, not something to suppress. No quarantine-removal commands or global security changes are part of HomeEar.

## Release gate

CI builds and verifies packages and prepares signed update archives/appcast as artifacts only. It never publishes a release automatically. A release requires review of real-window screenshots and explicit approval. Future release assets must include the generated versioned ZIP and unchanged signed appcast.xml; changing a signed file requires re-signing. The update-signing key stays in the encrypted repository secret, never source or logs.

## Update channels

0.1.5 adds Stable and Beta choices in Settings > Update. Stable looks for regular GitHub releases; Beta looks for prereleases and displays an unfinished-software warning. The selected release must provide a signed appcast.xml; missing assets, network errors and signature failures remain errors. An empty channel has a clear no-release message. Each check resolves the selected channel before Sparkle verifies and offers an update. 0.1.4 requires one manual install of this fix because its original stable-latest feed returns 404 when only a prerelease exists.
