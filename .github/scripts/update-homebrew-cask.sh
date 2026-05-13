#!/usr/bin/env bash
set -euo pipefail

# Required environment variables:
#   VERSION       — release version string, e.g. "1.2.3"
#   GITHUB_TOKEN  — token with repo write access to the tap repo

if [[ -z "${VERSION:-}" ]]; then
  echo "ERROR: VERSION env var is required" >&2
  exit 1
fi

if [[ -z "${GITHUB_TOKEN:-}" ]]; then
  echo "ERROR: GITHUB_TOKEN env var is required" >&2
  exit 1
fi

TAP_REPO="mean-weasel/homebrew-groqtalk"
DMG_PATH="${RUNNER_TEMP:-/tmp}/GroqTalk-${VERSION}-macos.dmg"

# Verify the DMG exists before attempting to hash it
if [[ ! -f "$DMG_PATH" ]]; then
  echo "ERROR: DMG not found at $DMG_PATH" >&2
  exit 1
fi

echo "Computing SHA256 for $DMG_PATH ..."
SHA256=$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')
echo "SHA256: $SHA256"

# Check whether the tap repo exists
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
  -H "Authorization: token ${GITHUB_TOKEN}" \
  "https://api.github.com/repos/${TAP_REPO}")

if [[ "$HTTP_STATUS" == "404" ]]; then
  echo "Tap repo ${TAP_REPO} does not exist yet — skipping Homebrew cask update."
  exit 0
fi

if [[ "$HTTP_STATUS" != "200" ]]; then
  echo "ERROR: Unexpected HTTP status ${HTTP_STATUS} when checking tap repo ${TAP_REPO}" >&2
  exit 1
fi

echo "Tap repo ${TAP_REPO} found. Cloning ..."

CLONE_DIR=$(mktemp -d)
trap 'rm -rf "$CLONE_DIR"' EXIT

git clone \
  "https://x-access-token:${GITHUB_TOKEN}@github.com/${TAP_REPO}.git" \
  "$CLONE_DIR"

mkdir -p "$CLONE_DIR/Casks"

cat > "$CLONE_DIR/Casks/groqtalk.rb" <<RUBY
cask "groqtalk" do
  version "${VERSION}"
  sha256 "${SHA256}"

  url "https://github.com/mean-weasel/groqtalk/releases/download/v${VERSION}/GroqTalk-${VERSION}-macos.dmg"
  name "GroqTalk"
  desc "Menu bar speech-to-text transcription powered by Groq"
  homepage "https://github.com/mean-weasel/groqtalk"

  auto_updates true
  depends_on macos: ">= :sonoma"

  app "GroqTalk.app"

  zap trash: [
    "~/Library/Application Support/com.neonwatty.GroqTalk",
    "~/Library/Preferences/com.neonwatty.GroqTalk.plist",
    "~/Library/Caches/com.neonwatty.GroqTalk",
  ]
end
RUBY

cd "$CLONE_DIR"
git config user.email "github-actions[bot]@users.noreply.github.com"
git config user.name "github-actions[bot]"

git add Casks/groqtalk.rb

if git diff --cached --quiet; then
  echo "No changes to commit — cask is already up to date."
  exit 0
fi

git commit -m "chore: update groqtalk cask to v${VERSION}"
git push

echo "Homebrew cask updated to v${VERSION} in ${TAP_REPO}."
