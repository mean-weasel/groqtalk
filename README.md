# GroqTalk

macOS menu bar speech-to-text powered by [Groq Whisper](https://console.groq.com/).

Demo media has not been published yet.

## Install

GroqTalk is still in beta. Verify the release artifact for the version you want
before treating the install paths below as public-ready.

**Manual:** Download `GroqTalk-VERSION-macos.dmg` from
[Releases](https://github.com/neonwatty/groqtalk/releases), verify the checksum
published with that release, open it, and drag GroqTalk into Applications.

### Install via Homebrew

```bash
brew tap mean-weasel/groqtalk
brew install --cask groqtalk
```

## Setup

1. Get a free API key from [console.groq.com](https://console.groq.com/)
2. Launch GroqTalk — it lives in your menu bar
3. Click the menu bar icon and use the Setup panel to grant Accessibility and
   Microphone permissions
4. Click **Add Key** or Settings → Transcription → **Change API Key**, then paste
   your Groq API key
5. Use **Run Check** in the Setup panel to confirm the app is ready

GroqTalk is a menu bar app (`LSUIElement`), so it does not keep a normal Dock
window open. The built app includes macOS AppIcon assets for Finder,
Applications, and DMG presentation; the menu bar itself uses SF Symbol state
icons.

## Local Development

Requirements:

- Xcode with macOS 14+ SDK support
- Node.js and npm for release tooling

```sh
npm ci
make setup-local-signing
make build
make install
make start
make test
```

By default, local builds use the `GroqTalk Local Code Signing` identity when it
exists, falling back to ad-hoc signing otherwise. Stable local signing keeps the
app's Accessibility permission attached across rebuilds. `make setup-local-signing`
creates that identity once in a dedicated local keychain and removes stale
GroqTalk-local copies from the login keychain.

For a Developer ID install, pass your signing identity and team:

```sh
make install SIGN_IDENTITY="Developer ID Application" DEVELOPMENT_TEAM=YOURTEAMID
```

Release DMG notarization uses App Store Connect API key secrets:

- `DEVELOPER_ID_CERT_BASE64`
- `DEVELOPER_ID_CERT_PASSWORD`
- `APPLE_TEAM_ID`
- `APP_STORE_CONNECT_KEY_ID`
- `APP_STORE_CONNECT_ISSUER_ID`
- `APP_STORE_CONNECT_PRIVATE_KEY`

If the certificate files are in `~/Desktop/apple-developer-certificates`, run:

```sh
make setup-release-secrets
```

## Features

- **Hold-to-record** — hold Right Command, Right Option, or Globe/Fn to record, release to transcribe
- **Toggle mode** — press once to start, again to stop
- **Auto-paste** — by default, sends a paste command to the app active when transcription finishes
- **Async paste option** — can capture the app where recording started and paste there later; some apps may block automation, in which case GroqTalk falls back to clipboard handling
- **Experimental background paste** — optional advanced paste routing for app-specific testing; disabled by default because it relies on private macOS behavior and command-posted results are not fully verifiable
- **Clipboard safety** — by default, GroqTalk restores the previous clipboard after posting paste; Settings can keep final text on the clipboard instead
- **3 audio formats** — M4A (smaller), WAV (lossless), FLAC (lossless, smaller)
- **Language selection** — hint Whisper for better accuracy in 12 languages
- **Cleanup modes** — optionally clean up or rewrite transcripts after Whisper; if cleanup fails after Whisper succeeds, GroqTalk uses the raw transcript
- **Transcription history** — browse, search, edit, export, copy, paste, delete, and retry past transcriptions

## Privacy

- API keys are stored in the macOS Keychain. Older plaintext API-key files are migrated on read when possible.
- Transcription history stays on this Mac in Application Support. Retention can be set to off, 100, 500, or 1000 records.
- Successful audio files are deleted after transcription.
- Failed audio may be retained locally only for retryable transcription failures. Clearing history deletes retained retry files.
- Normal diagnostics should not include API keys or full transcript text. Release builds write diagnostic logs only when `GROQTALK_DIAGNOSTICS=1` is set.

## Paste Caveats

macOS paste automation depends on Accessibility permission and target-app
behavior. GroqTalk distinguishes verified direct insertion, command-posted
paste, window-choreography paste, and clipboard fallback internally. A command
being posted does not prove every target app accepted it; use History or the
clipboard fallback when a target blocks paste automation.

Experimental background paste is off by default. It uses private macOS routing
when available and should be treated as an advanced compatibility option, not
as the default reliability path.

## Troubleshooting

**Invalid API key:** Use **Add Key** or Settings → Transcription →
**Change API Key**. GroqTalk validates the key before saving when the network is
available. If validation fails because Groq cannot be reached, you can save the
key anyway and run the setup check later.

**Microphone not available:** Open System Settings → Privacy & Security →
Microphone and allow GroqTalk. Use **Run Check** after changing the permission.

**Accessibility or hotkey not working:** Open System Settings → Privacy &
Security → Accessibility and allow GroqTalk. If a local rebuild or reinstall
changed the app identity, remove the old GroqTalk entry, add the installed app
again, then restart GroqTalk.

**Paste command sent but no text appears:** The target app may block synthetic
paste events. Open History to copy or paste the transcript again. If GroqTalk
reports clipboard fallback, the transcript is on the clipboard.

**Cleanup failed:** Whisper transcription succeeded, but the cleanup model did
not return usable text. GroqTalk uses the raw transcript and keeps going.

**Recording too long:** GroqTalk stops oversized recordings before upload to
avoid runaway memory use and Groq request-size failures. Try a shorter
recording.

## Requirements

- macOS 14+ (Sonoma)
- Groq API key (free tier available)
- Accessibility permission (for global hotkey and paste automation)
- Microphone permission (for recording)

## License

MIT
