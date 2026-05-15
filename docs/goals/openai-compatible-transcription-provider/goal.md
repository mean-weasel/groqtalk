# OpenAI-Compatible Transcription Provider

## Objective

Implement an OpenAI-compatible transcription provider abstraction for GroqTalk and verify it with the existing E2E audio clip against a tiny local Whisper-compatible server.

## Context

- Project: GroqTalk is a native Swift macOS menu bar dictation app.
- Current transcription flow: `AudioRecorder` / `RecordingController` -> `TranscriptionController` -> `TranscriptionService` -> Groq OpenAI-compatible transcription endpoint -> optional cleanup -> paste/history.
- Current hard coupling: Groq endpoints, Groq API key copy, Groq keychain account, Groq model defaults, Groq-specific setup validation, and Groq-specific error messages are spread across service, app state, settings, onboarding, setup, tests, and UI.
- Existing E2E audio: `GroqTalk/e2e-test-audio.wav`, about 2.79s, 16 kHz mono PCM WAV, expected phrase `the quick brown fox jumps over the lazy dog`.
- Existing E2E UI test writes `/tmp/groqtalk-e2e-result.txt` and allows at most one missing expected word.

## Scope

Include:

- Add a provider abstraction for transcription endpoints.
- Preserve Groq as the default provider with unchanged default behavior.
- Add an OpenAI-compatible custom provider configurable by base URL, model, and optional API key.
- Route transcription requests through the selected provider.
- Make setup/key validation provider-aware.
- Make API key storage provider-scoped while preserving the existing Groq key.
- Add tests proving Groq defaults remain unchanged.
- Add tests proving custom OpenAI-compatible base URLs are used for `/audio/transcriptions`.
- Add an opt-in local E2E path that targets a local OpenAI-compatible Whisper server with the existing WAV clip and tiny model.

Exclude:

- Do not embed whisper.cpp in the app.
- Do not vendor whisper.cpp source or model files into this repo.
- Do not implement local model download UI.
- Do not make cleanup/chat local.
- Do not redesign the whole settings UI beyond the controls needed for provider selection/configuration.

## Constraints

- Preserve current Groq behavior for existing users.
- Existing Groq API keys stored under the current keychain account must still work.
- Default app launch must remain Groq + `whisper-large-v3-turbo`.
- The regular CI unit/UI test workflow must not require network access, Groq credentials, whisper.cpp, or model downloads.
- Local Whisper E2E must be opt-in via a separate command/workflow or explicit environment variables.
- If an OpenAI-compatible transcription provider does not support `/models` validation, setup checks must validate URL shape/reachability only or skip model validation with clear provider-specific status.
- If transcript cleanup is enabled while using a transcription-only provider, either keep cleanup routed to Groq only when a Groq cleanup key/model exists, or disable cleanup with a clear provider-aware message. Do not silently call Groq in a supposed local transcription test.

## Acceptance Criteria

- `make test` passes.
- `make test-ui` passes.
- `xcodebuild build -scheme GroqTalk -configuration Debug -destination 'platform=macOS' OTHER_SWIFT_FLAGS='-warnings-as-errors'` succeeds.
- Unit tests prove the Groq provider still builds:
  - `https://api.groq.com/openai/v1/audio/transcriptions`
  - `https://api.groq.com/openai/v1/chat/completions`
  - `https://api.groq.com/openai/v1/models`
- Unit tests prove a custom base URL such as `http://127.0.0.1:8080/v1` sends transcription requests to `http://127.0.0.1:8080/v1/audio/transcriptions`.
- Unit tests prove Authorization is omitted or accepted as dummy/local when the custom provider is configured without a real API key.
- Unit tests prove Groq and custom-provider API keys are stored independently and the legacy Groq key remains readable.
- UI/state tests prove the ready/session detail displays the selected provider name rather than hardcoded `Groq`.
- The existing live Groq E2E tests still pass when `GROQ_API_KEY` is set and still skip cleanly when it is absent.
- Add an opt-in local endpoint E2E verification using `GroqTalk/e2e-test-audio.wav` and a tiny Whisper model. It must:
  - POST to `/v1/audio/transcriptions`.
  - Return HTTP 200.
  - Produce a non-empty transcript.
  - Match at least 8 of 9 words in `the quick brown fox jumps over the lazy dog`.
  - Record elapsed time for 10 runs and report median and p95.
  - Pass with p95 under 10 seconds on the development Apple Silicon machine used for verification, or report measured latency if hardware prevents that threshold.
- The app-level E2E UI test must be runnable against the local endpoint using environment variables such as:
  - `E2E_TRANSCRIPTION_PROVIDER=openai-compatible`
  - `E2E_TRANSCRIPTION_BASE_URL=http://127.0.0.1:8080/v1`
  - `E2E_TRANSCRIPTION_MODEL=whisper-1`
  - `E2E_API_KEY=local`

## Verification

Run:

- `make test`
- `make test-ui`
- `xcodebuild build -scheme GroqTalk -configuration Debug -destination 'platform=macOS' OTHER_SWIFT_FLAGS='-warnings-as-errors'`
- Existing live Groq E2E command when `GROQ_API_KEY` is available.
- Local tiny Whisper endpoint smoke/E2E command when whisper.cpp server is running.

Inspect:

- Provider defaults and migration behavior.
- Keychain account naming.
- Settings/setup copy for hardcoded Groq references.
- `/tmp/groqtalk-e2e-result.txt` after app-level local E2E.

Evidence to report:

- Changed files.
- Test command results.
- Local endpoint transcript.
- Word recall count.
- 10-run latency median and p95.

## Deliverables

- Code changes implementing provider abstraction.
- Unit/UI/E2E test updates.
- A short README or docs note explaining how to run the local OpenAI-compatible Whisper E2E path.
- No committed model files, no vendored whisper.cpp checkout.

## Stop Rule

Stop when all deterministic tests pass, Groq default behavior is proven unchanged, and the local OpenAI-compatible E2E path transcribes the bundled clip with at least 8/9 expected words. Pause and ask if provider configuration requires a product decision that would change user-visible setup semantics or privacy claims.

## Starter Command

```text
/goal Follow docs/goals/openai-compatible-transcription-provider/goal.md.
```
