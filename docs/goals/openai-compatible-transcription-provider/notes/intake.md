# Intake Notes

Original request:

> Implement an OpenAI-compatible transcription provider abstraction for GroqTalk and verify it with the existing E2E audio clip against a tiny local Whisper-compatible server.

Interpreted outcome:

GroqTalk can keep using Groq by default, but can also target a configurable OpenAI-compatible transcription endpoint. The implementation is proven with deterministic unit/UI coverage and an opt-in local Whisper-compatible E2E path using the bundled short WAV clip.

Board choice:

- Visual board: local GoalBuddy board.
- Slug: `openai-compatible-transcription-provider`.

Proof:

- Deterministic tests: `make test`, `make test-ui`, and warnings-as-errors build.
- Compatibility proof: Groq endpoint defaults and legacy key behavior remain unchanged.
- Local E2E proof: bundled `GroqTalk/e2e-test-audio.wav` transcribes through a tiny Whisper-compatible server with at least 8/9 expected words and recorded latency metrics.

Likely misfire:

Only adding a base URL override in `TranscriptionService` while leaving setup validation, UI copy, keychain storage, cleanup behavior, and E2E verification implicitly Groq-only.
