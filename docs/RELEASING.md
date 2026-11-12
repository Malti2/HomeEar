# Releasing HomeEar

HomeEar has two build paths. Neither one publishes anything by itself.

## Development build (every push)

`.github/workflows/build.yml` runs on `main` and `claude/**` branches. It runs the unit tests, builds an
ad-hoc sealed app, packages a DMG and ZIP, prepares and verifies the signed Sparkle feed, and captures
real-window screenshots in English and German. The artifacts are for testing only: the app is **not**
Developer ID signed or notarized.

Publishing a reviewed development build as a test release is a separate manual step
(`publish-test.yml`). It uploads exactly the artifacts of a named, green run and never rebuilds.

## Notarized build (manual, untested)

`.github/workflows/release-notarized.yml` is meant for the first public release. It signs inside-out
with the hardened runtime, notarizes with `notarytool`, staples the ticket, checks Gatekeeper and
produces a stapled DMG and ZIP as workflow artifacts. It does not publish. **It has not been run**:
it needs an Apple Developer account and the repository secrets below, and the first run will probably
need small fixes.

| Secret | What it is |
| --- | --- |
| `DEVELOPER_ID_CERT_P12_BASE64` | Developer ID Application certificate and private key, exported as .p12 and base64-encoded |
| `DEVELOPER_ID_CERT_PASSWORD` | Password of that .p12 |
| `APPLE_ID` | Apple ID used for notarization |
| `APPLE_TEAM_ID` | Ten-character team id |
| `APPLE_APP_SPECIFIC_PASSWORD` | App-specific password for that Apple ID |

What the signing step relies on:

- The bundled Node.js is signed first with `Signing/node.entitlements` (`allow-jit` and
  `allow-unsigned-executable-memory`, which V8 needs under the hardened runtime). If the Poke CLI ever
  loads native addons, `com.apple.security.cs.disable-library-validation` will be needed as well.
- Sparkle's helpers and XPC services are signed before the framework, the framework before the app.
- The app is signed last with `HomeEar/HomeEar.entitlements` (microphone).

After the first successful notarized run, the Sparkle update archive has to be rebuilt from the
**stapled** app, then signed and verified like in `build.yml`; changing a signed file means
re-signing it. The update-signing key stays in the repository secret `SPARKLE_PRIVATE_KEY`.

## Checklist before a public release

1. All tests green on the release commit; review both screenshot sets (English and German).
2. Run the manual checklist on real hardware: speech model download, microphone permission,
   Poke sign-in and tunnel, Home Assistant connection, follow-up window, confirmation and safety
   gate, quiet hours, update from the previous version.
3. Notarized build succeeds; `spctl --assess` accepts it on a clean Mac after a browser download.
4. Decide on the project license (the repository currently only carries third-party licenses).
5. Publish the exact reviewed artifacts; never rebuild between review and release.
