#!/usr/bin/env bash
set -euo pipefail

if [[ "${RUN_LIVE_MICROPHONE_TESTS:-}" != "1" ]]; then
  echo "skip: set RUN_LIVE_MICROPHONE_TESTS=1 to run live microphone QA"
  exit 0
fi

SCHEME="${SCHEME:-GroqTalk}"
CONFIG="${CONFIG:-Debug}"
DESTINATION="${DESTINATION:-platform=macOS}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-}"
LIVE_MICROPHONE_RESULT_PATH="${LIVE_MICROPHONE_RESULT_PATH:-/tmp/groqtalk-live-microphone-result.txt}"
LIVE_MICROPHONE_DURATION_SECONDS="${LIVE_MICROPHONE_DURATION_SECONDS:-2}"
PLISTBUDDY="/usr/libexec/PlistBuddy"
patched=""

cleanup() {
  if [[ -n "${patched}" ]]; then
    rm -f "${patched}"
  fi
}
trap cleanup EXIT

echo "Live microphone QA prerequisites:"
echo "- A working input device is selected in macOS Sound settings."
echo "- The Xcode-built GroqTalk test app can be granted Microphone permission when prompted."
echo "- This target is local-only; regular CI should use make test-ui."
echo ""
echo "If permission state is stale, run:"
echo "  tccutil reset Microphone com.neonwatty.GroqTalk"
echo ""

build_args=(
  -scheme "${SCHEME}" \
  -configuration "${CONFIG}" \
  -destination "${DESTINATION}"
)
if [[ -n "${DERIVED_DATA_PATH}" ]]; then
  build_args+=( -derivedDataPath "${DERIVED_DATA_PATH}" )
fi

echo "== Build for testing"
xcodebuild build-for-testing "${build_args[@]}"

find_root="${DERIVED_DATA_PATH:-${HOME}/Library/Developer/Xcode/DerivedData}"
xctestrun="$(find "${find_root}" -name '*.xctestrun' -path '*GroqTalk*' -print0 2>/dev/null | xargs -0 ls -t 2>/dev/null | head -1 || true)"
if [[ -z "${xctestrun}" || ! -f "${xctestrun}" ]]; then
  echo "error: could not locate generated .xctestrun" >&2
  exit 1
fi

patched="${xctestrun%.xctestrun}.live-microphone-qa.xctestrun"
cp "${xctestrun}" "${patched}"

ui_target_index=""
for index in $(seq 0 20); do
  blueprint="$("${PLISTBUDDY}" -c "Print :TestConfigurations:0:TestTargets:${index}:BlueprintName" "${patched}" 2>/dev/null || true)"
  if [[ "${blueprint}" == "GroqTalkUITests" ]]; then
    ui_target_index="${index}"
    break
  fi
  if [[ -z "${blueprint}" ]]; then
    break
  fi
done

if [[ -z "${ui_target_index}" ]]; then
  echo "error: GroqTalkUITests target not found in ${patched}" >&2
  exit 1
fi

env_root=":TestConfigurations:0:TestTargets:${ui_target_index}:EnvironmentVariables"
for key in RUN_LIVE_MICROPHONE_TESTS LIVE_MICROPHONE_RESULT_PATH LIVE_MICROPHONE_DURATION_SECONDS; do
  "${PLISTBUDDY}" -c "Delete ${env_root}:${key}" "${patched}" >/dev/null 2>&1 || true
done

test_host="$("${PLISTBUDDY}" -c "Print :TestConfigurations:0:TestTargets:${ui_target_index}:TestHostPath" "${patched}" 2>/dev/null || true)"
if [[ -z "${test_host}" || ! -e "${test_host}" ]]; then
  test_host="$(find "${find_root}" -path '*Build/Products/Debug/GroqTalk.app' -type d -print0 2>/dev/null | xargs -0 ls -dt 2>/dev/null | head -1 || true)"
fi
signing_identity="unknown"
if [[ -n "${test_host}" && -e "${test_host}" ]]; then
  echo "app_path=${test_host}"
  signing_identity="$(codesign -dv "${test_host}" 2>&1 | sed -n 's/^Authority=//p' | head -1 || true)"
  if [[ -z "${signing_identity}" ]]; then
    signing_identity="$(codesign -dv "${test_host}" 2>&1 | sed -n 's/^Signature=//p' | head -1 || true)"
  fi
  signing_identity="${signing_identity:-Sign to Run Locally (ad-hoc)}"
  echo "signing_identity=${signing_identity}"
else
  echo "app_path=unknown"
  signing_identity="Sign to Run Locally (ad-hoc)"
  echo "signing_identity=${signing_identity}"
fi

for key in LIVE_MICROPHONE_SIGNING_IDENTITY; do
  "${PLISTBUDDY}" -c "Delete ${env_root}:${key}" "${patched}" >/dev/null 2>&1 || true
done
"${PLISTBUDDY}" -c "Add ${env_root}:RUN_LIVE_MICROPHONE_TESTS string 1" "${patched}"
"${PLISTBUDDY}" -c "Add ${env_root}:LIVE_MICROPHONE_RESULT_PATH string ${LIVE_MICROPHONE_RESULT_PATH}" "${patched}"
"${PLISTBUDDY}" -c "Add ${env_root}:LIVE_MICROPHONE_DURATION_SECONDS string ${LIVE_MICROPHONE_DURATION_SECONDS}" "${patched}"
"${PLISTBUDDY}" -c "Add ${env_root}:LIVE_MICROPHONE_SIGNING_IDENTITY string ${signing_identity}" "${patched}"
rm -f "${LIVE_MICROPHONE_RESULT_PATH}"

echo "== XCUITest live microphone QA"
xcodebuild test-without-building \
  -xctestrun "${patched}" \
  -destination "${DESTINATION}" \
  -only-testing:GroqTalkUITests/GroqTalkUITests/testLiveMicrophoneSmoke
