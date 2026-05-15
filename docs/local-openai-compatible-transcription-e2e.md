# Local OpenAI-Compatible Transcription E2E

This opt-in check verifies GroqTalk against a local OpenAI-compatible Whisper endpoint.
It does not require a Groq key and should not run in regular CI.

## Server Setup

Keep `whisper.cpp` and models outside this repo:

```sh
git clone --depth 1 https://github.com/ggml-org/whisper.cpp.git /tmp/whisper.cpp
cd /tmp/whisper.cpp
cmake -B build -DWHISPER_BUILD_TESTS=OFF
cmake --build build -j --config Release
sh ./models/download-ggml-model.sh tiny.en
```

Start the local server:

```sh
/tmp/whisper.cpp/build/bin/whisper-server \
  --host 127.0.0.1 \
  --port 8080 \
  --model /tmp/whisper.cpp/models/ggml-tiny.en.bin \
  --language en \
  --inference-path /v1/audio/transcriptions \
  --convert \
  --no-timestamps
```

## Endpoint Smoke Test

```sh
curl -sS http://127.0.0.1:8080/v1/audio/transcriptions \
  -H "Authorization: Bearer local" \
  -F "file=@GroqTalk/e2e-test-audio.wav;type=audio/wav" \
  -F "model=whisper-1" \
  -F "response_format=text"
```

Expected transcript:

```text
the quick brown fox jumps over the lazy dog.
```

## App-Level E2E

```sh
E2E_TRANSCRIPTION_PROVIDER=openai-compatible \
E2E_TRANSCRIPTION_BASE_URL=http://127.0.0.1:8080/v1 \
E2E_TRANSCRIPTION_MODEL=whisper-1 \
E2E_API_KEY=local \
xcodebuild test \
  -scheme GroqTalk \
  -configuration Debug \
  -destination 'platform=macOS' \
  -only-testing:GroqTalkUITests/GroqTalkUITests/testE2ETranscription
```

## 2026-05-14 Local Evidence

Machine: Apple Silicon Mac with Metal backend selected by `whisper.cpp`.

Clip:

- File: `GroqTalk/e2e-test-audio.wav`
- SHA-256: `36d3a24bbaf79f805fa4ad5360feb918c7467956b5001166d741f48e4c037e04`
- Format: 16 kHz mono PCM WAV

Endpoint result:

- HTTP: `200`
- Transcript: `the quick brown fox jumps over the lazy dog.`
- Word recall: `9/9`
- 10-run median latency: `0.054s`
- 10-run p95 latency: `0.056s`

App-level E2E result:

- Command: `testE2ETranscription` with the environment above
- Result: `TEST SUCCEEDED`
- `/tmp/groqtalk-e2e-result.txt`: `The quick brown fox jumps over the lazy dog.`
