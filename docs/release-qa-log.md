# Release QA Log

Use this file as the release-candidate evidence template. Copy the checklist
below into the release PR or release notes, then fill every result before
publishing.

## Release Candidate

- Version: Unreleased RC from `feat/initial-implementation` after `v1.8.1`
- Commit: `86c7079`
- Date: 2026-05-11 09:01:15 MST
- Runner: `jeremywatt`
- macOS version: 26.3.1 (a), build 25D771280a
- Xcode version: Xcode 26.3, build 17C529

## Automated Gates

| Gate | Command | Result | Artifact / notes |
| --- | --- | --- | --- |
| Build with warnings as errors | `xcodebuild build -scheme GroqTalk -configuration Debug -destination 'platform=macOS' OTHER_SWIFT_FLAGS='-warnings-as-errors'` | PASS | `** BUILD SUCCEEDED **` on 2026-05-11 09:01 MST. |
| Unit XCTest suite | `make test` | PASS | xcresult: `Test-GroqTalk-2026.05.11_09-01-41--0700.xcresult`; `** TEST SUCCEEDED **`. |
| UI XCTest suite | `make test-ui` | PASS | xcresult: `Test-GroqTalk-2026.05.11_09-01-56--0700.xcresult`; `** TEST SUCCEEDED **`. |
| Installed app real paste | `make test-paste-real` | SKIP RECORDED | Default run exited `2` on AX-window skip as expected; explicit rerun with `ALLOW_LOCAL_QA_SKIP=1` exited `0`. Production `insertAsync` path was exercised and UI-test bypass was not used, but target AX window was not exposed to the installed app process. |
| Cross-app paste | `make test-cross-app` | PASS WITH SKIPS | TextEdit async paste PASS; SkyLight background paste PASS; Terminal PASS; Chrome PASS; VS Code skipped because app is not installed; Notes skipped to avoid mutating persistent Notes data. |
| Live cleanup quality | `GROQ_API_KEY=... make test-cleanup-quality` | BLOCKED | `make test-cleanup-quality` without `GROQ_API_KEY` failed fast as intended. Rerun with a valid key before release sign-off. |
| Semantic release dry run | `npx semantic-release --dry-run --no-ci` | PASS / NO RELEASE | First run failed without `GH_TOKEN`; rerun with `GH_TOKEN="$(gh auth token)"` passed. semantic-release found 3 commits since `v1.8.1`, none release-triggering, so no new version would be published. |

## Local-Only Skips

Any skip must include why it was skipped, the command output, and the risk owner.
Do not set `ALLOW_LOCAL_QA_SKIP=1` unless the skipped result is recorded here.

| Gate | Skip reason | Evidence | Owner / follow-up |
| --- | --- | --- | --- |
| Installed app real paste | `/Applications/GroqTalk.app` entered the mock async path, but this desktop session did not expose the TextEdit target AX window to the app process. | `make test-paste-real` exited `2`; `ALLOW_LOCAL_QA_SKIP=1 make test-paste-real` exited `0`. Diagnostics confirmed automation mock request, async path, production `insertAsync`, no UI-test paste queue, automation smoke enabled, and floating status stayed off by default. | Refresh Accessibility permission for `/Applications/GroqTalk.app` and rerun `make test-paste-real` before public release if this skip is not accepted. |
| VS Code cross-app paste | Visual Studio Code.app is not installed on this runner. | `make test-cross-app` reported `VS Code: Visual Studio Code.app not installed`. | Install VS Code and rerun cross-app paste if VS Code coverage is required for the RC. |
| Notes cross-app paste | Test intentionally avoids mutating persistent Notes data from automation. | `make test-cross-app` reported `Notes: Skipped to avoid mutating persistent Notes data from automation`. | Use a disposable Notes account/container or manual Notes smoke test before public release if Notes is a required target. |
| Live cleanup quality | No `GROQ_API_KEY` was present in the shell. | `make test-cleanup-quality` failed with `ERROR: Missing GROQ_API_KEY environment variable.` | Rerun `GROQ_API_KEY=... make test-cleanup-quality` with a valid key before sign-off. |

## Release Artifact Verification

| Artifact | Command | Result | Notes |
| --- | --- | --- | --- |
| DMG signature | `spctl -a -vv -t open --context context:primary-signature GroqTalk-VERSION-macos.dmg` | BLOCKED | No DMG exists locally for commit `86c7079`. Latest GitHub release is `v1.8.1`, which predates this RC. |
| DMG notarization staple | `xcrun stapler validate /Volumes/GroqTalk/GroqTalk.app` | BLOCKED | Requires a mounted signed/notarized RC DMG. |
| DMG checksum | `shasum -a 256 GroqTalk-VERSION-macos.dmg` | BLOCKED | No RC DMG exists locally. Existing `v1.8.1` asset digest from GitHub is `sha256:9c1a3289fec1e874f24f0dd38c5d3501663b67a59e8fa1597bc42f13eddc29dd`, but that is not an artifact for commit `86c7079`. |
| Homebrew cask install | `brew install --cask groqtalk` | BLOCKED | `gh repo view neonwatty/tap` could not resolve the tap repository. README correctly treats Homebrew as planned/unverified. |

## Manual Smoke

| Scenario | Result | Notes |
| --- | --- | --- |
| Fresh install from DMG | BLOCKED | Requires signed/notarized RC DMG for commit `86c7079`. |
| Accessibility permission prompt and setup check | PARTIAL | Installed debug app was copied to `/Applications/GroqTalk.app`; AX-window exposure was still unavailable for real paste smoke. Requires fresh permission-cycle verification. |
| Microphone permission prompt and setup check | NOT RUN | Requires manual fresh-user state or clean permission reset. |
| API key save and Keychain readiness | NOT RUN | Requires manual app flow with a real or disposable key. |
| One real transcription | NOT RUN | Requires `GROQ_API_KEY` or app-saved key plus microphone input. |
| Paste fallback behavior in a blocked target app | PARTIAL | XCTest covers clipboard fallback restoration for terminated target. Manual blocked-target app smoke not run. |
| Clear History removes retained retry audio | NOT RUN | Requires manual retained-audio scenario or targeted integration test. |

## Sign-Off

- Known P0/P1 issues: None from CI/local deterministic gates. RC sign-off is blocked on live cleanup quality, fresh DMG artifact verification, and final manual smoke.
- Remaining P2/P3 issues accepted for this release: Installed-app paste AX-window skip on this runner; VS Code/Notes cross-app coverage skipped; Homebrew tap unavailable.
- Approver:
