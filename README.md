<div align="center">

# HomeEar

**A private voice gateway for your smart home on macOS.**

Keep HomeEar running in the menu bar throughout the day, if you choose. It continuously listens for likely commands in German or English, filters speech on your Mac, and passes matching requests to your Poke agent. If you've connected Philips Hue, Home Assistant, or another smart-home service to Poke, your agent can use those connections to help with your home.

*Native menu bar UI · local speech recognition · Poke voice replies*

</div>

> **Development status:** This repository is a work in progress. The CI artifact is unsigned and unnotarized. There is no supported release or automatic installer yet.

## The idea: an always-available home assistant

With the microphone enabled and the Mac awake, HomeEar can stay active around the clock and respond whenever you speak a likely command. You don't have to open an app or press a button for every request. For example, ask for the lights in the living room, a warmer bedroom, or a scene you use at night. HomeEar turns speech into a text request for Poke. Poke decides what to do through **your own connected integrations** and can call HomeEar's local voice tool to speak a reply on your Mac. If you configure proactive automations in Poke or your connected smart-home system, those services may also change your home without a new spoken command; HomeEar itself does not schedule, infer, or initiate autonomous home actions.

HomeEar does **not** control Hue or Home Assistant directly, and it doesn't create those Poke connections for you. Set them up in Poke first. What commands work depends on your Poke setup and the capabilities of each connected service.

## How it works

```text
Mac microphone → Apple's on-device SpeechTranscriber → local request filter
             → Poke inbound API → your Poke agent → your connected home services
                                        ↘ Poke tunnel → HomeEar voice tool → Mac speaker
```

- Recognition defaults to `de-DE`. English (`en-US`) is available in settings. The Mac must support the chosen on-device model and may need to download it first.
- The request filter rejects short or non-command speech, but it is heuristic, not a privacy guarantee. Background speech could be sent by mistake. Pause the microphone from the menu bar whenever you need privacy.
- Audio is not uploaded or saved by HomeEar. Qualifying **text** is sent to Poke once setup is complete and the microphone is active. HomeEar doesn't keep a transcript on disk.
- The Poke V2 API key lives in macOS Keychain. Outbound requests and the inbound voice tunnel have separate status indicators.
- The app includes a pinned Node.js and Poke CLI runtime for its local tunnel. The UI, audio pipeline, filter, Keychain access, and speech playback are native Swift. Sign in to Poke once in the browser through HomeEar's onboarding; the app then manages the tunnel and retries interrupted connections. This needs on-device validation before release.

## Build and current limitations

GitHub Actions generates the Xcode project and compiles for Apple Silicon on the macOS 26 runner. macOS 26 or newer is required; the target is macOS 27. Builds are **development artifacts only**. Signing, notarization, safe updates, speech-model availability on the user's Mac, Poke device login, and tunnel/voice-tool interoperability have not been verified. The built-in update check opens the official GitHub release page for manual review; it does not replace the app.

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
