#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/common.sh"

cd "${REPO_ROOT}"

require_env GITLAB_TOKEN
require_env TARGET_REPO_URL
require_env TARGET_BRANCH
require_env NEW_BRANCH_NAME

if ! command -v copilot >/dev/null; then
  echo "[ERROR] copilot CLI not found in PATH" >&2
  exit 1
fi

echo "[INFO] Cloning target repository..."

python3 <<'PY' > authed_repo_url.txt
import os
from urllib.parse import quote, urlparse, urlunparse

token = os.environ["GITLAB_TOKEN"]
repo = os.environ["TARGET_REPO_URL"]
parsed = urlparse(repo)
netloc = f"oauth2:{quote(token, safe='')}@{parsed.netloc}"
authed = urlunparse((parsed.scheme, netloc, parsed.path, parsed.params, parsed.query, parsed.fragment))
print(authed)
PY

AUTHED_URL="$(cat authed_repo_url.txt)"
rm -rf repo-b
GIT_TERMINAL_PROMPT=0 git clone "${AUTHED_URL}" repo-b >/dev/null 2>&1

if [ ! -d repo-b ]; then
  echo "[ERROR] Failed to clone repository" >&2
  exit 1
fi

cd repo-b

echo "[INFO] Setting up branch ${NEW_BRANCH_NAME}..."
git fetch origin "${NEW_BRANCH_NAME}" >/dev/null 2>&1 || true
git checkout -B "${NEW_BRANCH_NAME}" "origin/${NEW_BRANCH_NAME}" >/dev/null 2>&1 || git checkout -b "${NEW_BRANCH_NAME}" "${TARGET_BRANCH}" >/dev/null

cp ../todo.md ./todo.md

echo "[INFO] Building implementation prompt for Copilot..."

# Get repository context
REPO_FILES=$(find . -type f -not -path '*/.git/*' -not -path '*/node_modules/*' | head -50 | tr '\n' ', ')

IMPL_PROMPT="You are GitHub Copilot CLI acting as a coding agent.

Repository Context:
- Path: $(pwd)
- Branch: ${NEW_BRANCH_NAME}
- Base branch: ${TARGET_BRANCH}
- Sample files: ${REPO_FILES}

Task List:
$(cat todo.md)

Your job:
1. Analyze the repository structure
2. Implement ALL tasks from the checklist above
3. Generate a unified diff patch with your changes
4. Enclose the patch in triple backticks with 'diff' language marker

Requirements:
- Produce working, tested code
- Follow existing code style and patterns
- Include necessary imports and dependencies
- Add inline comments for complex logic

Output format:
\`\`\`diff
[your unified diff here]
\`\`\`

Generate the implementation now."

echo "[INFO] Invoking Copilot for code generation (timeout: 600s)..."
if timeout 600 copilot -p "$IMPL_PROMPT" > patch_raw.txt 2>&1; then
  echo "[INFO] Copilot code generation completed"
  # Clean ANSI escape sequences and carriage returns
  sed -E 's/\x1B\[[0-9;]*[A-Za-z]//g' patch_raw.txt | tr -d '\r' > patch_clean.txt
  mv patch_clean.txt patch_raw.txt
else
  EXIT_CODE=$?
  if [ $EXIT_CODE -eq 124 ]; then
    echo "[ERROR] Copilot timed out after 600 seconds" >&2
  else
    echo "[ERROR] Copilot failed with exit code ${EXIT_CODE}" >&2
  fi
  cat patch_raw.txt >&2
  exit 1
fi

python3 <<'PY'
import re
from pathlib import Path

raw = Path("patch_raw.txt").read_text(encoding="utf-8")
matches = re.findall(r"```(?:diff|patch)?\n(.*?)```", raw, flags=re.DOTALL)
if matches:
    Path("copilot.patch").write_text(matches[-1].strip() + "\n", encoding="utf-8")
PY

if [[ -f copilot.patch ]]; then
  git apply copilot.patch && git status --short
else
  echo "Copilot did not return an applyable patch"
fi

git config user.name "copilot-agent"
git config user.email "copilot@example.com"

if ! git diff --quiet; then
  git add -A
  git commit -m "feat: apply copilot automation" >/dev/null
  git push --set-upstream origin "${NEW_BRANCH_NAME}" >/dev/null
else
  echo "No changes were generated"
fi

python3 <<'PY'
from pathlib import Path

text = Path("todo.md").read_text(encoding="utf-8")
done = text.replace("[ ]", "[x]")
Path("todo_completed.md").write_text(done if done.endswith("\n") else done + "\n", encoding="utf-8")
PY

cd "${REPO_ROOT}"
