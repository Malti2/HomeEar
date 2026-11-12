<div align="center">

# HomeEar

**A private voice gateway for your smart home on macOS.**

Keep HomeEar in the menu bar. Say **“Hey Poke”** and a request, or just speak a likely command in German or English: HomeEar filters speech on your Mac and passes matching requests to your selected backend, Poke or built-in Home Assistant Assist. It can answer out loud, ask back when it is unsure, and stays out of the way when you are talking to someone else.

*Native menu bar app · on-device speech recognition · German and English*

</div>

> **Development status:** 0.2.0 is a development version. CI builds are ad-hoc sealed for integrity, not Developer ID signed or notarized, and no supported public release exists yet. A manual notarization workflow is prepared but untested (see [docs/RELEASING.md](docs/RELEASING.md)).

## What it does

With the microphone enabled and the Mac awake, HomeEar listens through Apple's on-device speech recognition. It turns speech into text and decides what to do with it:

```text
microphone → on-device SpeechTranscriber → UtteranceRouter
    ├─ "Hey Poke" wake word (fuzzy) ──────────────┐
    ├─ shortcuts ("Gute Nacht" → stored request) ─┤
    ├─ follow-up window after a spoken reply ─────┼→ safety gate → backend
    └─ proactive filter (no wake word needed) ────┘        │  Poke · Home Assistant · Smart
         scored heuristics + loudness + optional           ↓
         Apple Intelligence + your corrections      spoken reply → echo guard
```

Audio is not uploaded or saved by HomeEar. Only text that passes the filter is sent, and only to the backend you selected. The filter is heuristic, not a privacy guarantee: background speech can still be sent by mistake. Pause the microphone whenever you need privacy.

## Quick start

1. Install the DMG from a development build and open it from Applications (an unnotarized build may need *Open Anyway* in System Settings > Privacy & Security).
2. Follow **Finish setup** in the menu bar panel: language, microphone and speech access, then Poke (API key, browser sign-in) or Home Assistant (URL and long-lived token).
3. Press **Start listening** and say “Hey Poke, mach das Licht im Wohnzimmer an”.

macOS 26 or newer and Apple Silicon are required.

## Features

### Talking to it
- **Wake word:** “Hey Poke”, matched fuzzily on partial and final transcripts (“hey poak” works). A lone “Hey Poke” waits a few seconds for the command. “Abbrechen”, “vergiss es” or “never mind” cancels.
- **Spoken replies:** Home Assistant answers are read aloud. While HomeEar speaks, and for about a second after, microphone input is ignored, so its own voice (including Poke voice replies) is never taken for a request.
- **Follow-ups:** after a spoken reply, a short answer or “und im Flur auch” works without the wake word for a few seconds. Home Assistant keeps context through its conversation id.
- **Asks back:** a request that is almost a command is confirmed (“Meintest du: …?”) out loud and with Send/Discard buttons in the panel, instead of being guessed at. Answer with ja or nein.
- **Shortcuts:** “Gute Nacht” expands to a request you wrote once. Matches only the whole sentence, needs the wake word by default.

### Deciding what is a request
- **Proactive filter:** scores German and English sentences (command verbs, infinitive commands, smart-home words, polite framing). Entities match per word or as the tail of a compound (“Wohnzimmerlampe”), never inside other words. Subordinate clauses, past tense and sentences about someone else score down.
- **Addressed to a person:** “Mama, …”, “Schatz, …” and the household names you add are not forwarded.
- **Your vocabulary:** extra words, and room and device names imported from Home Assistant (read-only template call, cached on this Mac).
- **Loudness cues:** compares speech to the room and to how you sound with the wake word. Clearly quieter speech (TV, another room) loses points. Only dB levels are measured; this can lower a score but never send anything.
- **Apple Intelligence (optional, off by default):** a yes/no second opinion from Apple's on-device model for almost-commands. Nothing leaves the Mac. If the model is unavailable or too slow, HomeEar asks you instead.
- **Corrections:** “Send anyway” and “Wasn't a command” in the Activity list teach the filter that exact sentence.

### Safety
- **Sensitive actions:** locks, garage doors, alarm systems and ovens (plus your own words) are never sent from background speech. With the wake word, a follow-up or a shortcut, HomeEar asks “Soll ich das wirklich tun?” first. This is word matching on what was heard; it does not replace permissions and confirmations in your smart-home system.
- **One backend per request:** Poke, Home Assistant, or **Smart** routing (device and room words to Home Assistant, reminders, timers, calendar, weather and questions to Poke). Never an automatic fallback or a retry after an uncertain result.
- **Quiet hours:** the microphone pauses in a daily window and resumes afterwards, unless you paused it yourself.

### Interface
- Menu bar icon per state: listening, waiting for you, sent, problem, paused. Optional soft system sounds (off by default).
- Activity list: the last 50 things heard this session, with the decision and the reason.
- Settings as a sidebar of categories, in English and German (follows the system language; the recognition language is chosen separately).

## Settings

| Pane | What is in it |
| --- | --- |
| General | Destination (Poke, Home Assistant, Smart), start at login, quiet hours |
| Speech | Recognition language, microphone, spoken replies, sounds, follow-ups and asking back, wake word, proactive requests |
| Request Filter | Strictness, distant speech, your words, household names, Apple Intelligence, sensitive actions, Home Assistant names |
| Shortcuts | Spoken phrase → stored request |
| Activity | What HomeEar heard and did, corrections |
| Poke | API key, voice tunnel, voice |
| Home Assistant | Server URL, token, connection test |
| Update | Version, Stable or Beta channel, update checks |

## What is stored where

| Data | Where | Notes |
| --- | --- | --- |
| Audio | nowhere | Transcribed live on the Mac; only loudness levels (dB) are kept for a few seconds in memory |
| Heard sentences, recent requests, activity list | memory | Gone when you quit |
| Learned corrections | UserDefaults | SHA-256 hashes of normalised sentences, never readable text |
| Settings, shortcuts, your words | UserDefaults | Your own configuration |
| Imported Home Assistant names | UserDefaults | Word list only |
| Poke API key, Home Assistant token | macOS Keychain | Separate items |

## Build and test

```sh
brew install xcodegen
bash scripts/bundle-runtime.sh   # pinned, checksummed Node.js and Poke CLI
xcodegen generate
xcodebuild -project HomeEar.xcodeproj -scheme HomeEarTests -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test
xcodebuild -project HomeEar.xcodeproj -scheme HomeEar -configuration Release -arch arm64 CODE_SIGNING_ALLOWED=NO build
```

GitHub Actions runs the same on the macOS 26 runner for every push to `main` and `claude/**`, then packages the DMG and ZIP, prepares the signed update feed and captures real-window screenshots (English and German) as artifacts. Never commit API keys, login tokens or personal recordings.

## Limitations

- Speech-model availability, Poke device login, tunnel interoperability, the Home Assistant template call, the follow-up and echo timings and the loudness thresholds are validated by CI only as far as logic goes; they need testing on real hardware.
- The local voice tool listens on `127.0.0.1:3000` only. Any local process can reach a loopback endpoint, and its MCP transport needs compatibility and security testing before a release.
- No OpenClaw integration exists; the agent-backend boundary is designed to allow it later.
- HomeEar can transmit text to Poke, and Poke may act through services you connected there. Check those connections and permissions yourself. Avoid leaving the microphone running near other people, TV audio or sensitive conversations.

## Releases

CI never publishes a release. A release needs review of real-window screenshots and explicit approval; release assets are the generated versioned ZIP and the unchanged signed `appcast.xml` (changing a signed file requires re-signing). The update-signing key stays in the encrypted repository secret, never in source or logs. Details and the notarization workflow: [docs/RELEASING.md](docs/RELEASING.md). History: [CHANGELOG.md](CHANGELOG.md).

**Update channels** (Settings > Update): Stable looks for regular GitHub releases, Beta for prereleases and shows an unfinished-software warning. The selected release must provide a signed `appcast.xml`; missing assets, network errors and signature failures remain errors, and an empty channel shows a clear message. Each check resolves the channel first, then Sparkle verifies the signed feed and archive before anything is offered. The first updater-enabled version has to be installed manually.
