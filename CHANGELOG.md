# Changelog

## 0.2.0

A conversation layer, a safer filter and a German interface.

- **Conversation:** HomeEar reads Home Assistant replies aloud and ignores the microphone while it
  speaks (this also fixes Poke voice replies being heard as requests). After a reply, short answers
  and follow-ups work without the wake word. Home Assistant keeps context across follow-ups.
- **Asks back:** almost-commands are confirmed out loud and in the menu bar panel instead of being
  guessed at. Optional second opinion from Apple Intelligence (on-device, off by default).
- **Filter:** per-word entity matching, infinitive commands, subordinate and past-tense clauses,
  sentences addressed to a person, distant-speech detection from loudness, your own words and
  household names, and room and device names imported from Home Assistant.
- **Safety gate:** locks, garage doors, alarm systems and ovens are never sent from background
  speech and ask for confirmation when asked for with the wake word.
- **Control:** shortcuts for stored requests, smart routing between Poke and Home Assistant,
  quiet hours, activity list with reasons, learned corrections (stored as hashes only).
- **Interface:** settings as a sidebar of categories, menu bar icon per state, optional sounds,
  German translation, app icon.
- **Release plumbing:** privacy manifest, version metadata, shared runtime script, DMG retry in CI,
  manual notarization workflow (untested), documentation in `docs/RELEASING.md`.
- **Fixes:** deliveries are logged only after the backend answered, the Start at login switch shows
  the real state at launch, closing follow-up windows no longer overwrite the last decision.

## 0.1.5

Stable and Beta update channels.

## 0.1.4

Sparkle updater with signed update archives.
