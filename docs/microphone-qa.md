# Microphone QA

Regular CI does not require microphone permission, microphone hardware, Groq credentials, or macOS TCC prompts.

Run deterministic onboarding and setup coverage:

```bash
make test-ui
```

Run the opt-in live microphone smoke locally:

```bash
RUN_LIVE_MICROPHONE_TESTS=1 make test-microphone-live
```

The live smoke launches a debug-only app hook that starts the real recorder, captures about two seconds of audio, writes `/tmp/groqtalk-live-microphone-result.txt`, and verifies the result from XCUITest. It records the app path, signing identity, microphone permission status, start/stop state, elapsed time, captured byte count, and either a non-empty capture result or a clear local prerequisite failure. It does not require network or Groq API availability.

If macOS permission state is stale:

```bash
tccutil reset Microphone com.neonwatty.GroqTalk
RUN_LIVE_MICROPHONE_TESTS=1 make test-microphone-live
```

When prompted, allow microphone access for the GroqTalk test app. If no prompt appears, open System Settings > Privacy & Security > Microphone and verify GroqTalk is allowed.
