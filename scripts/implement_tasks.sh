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

# echo "[DEBUG] Contents of repo-b directory:"
# ls -ltr
# cat .gitlab-ci.yml

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
- Check if there is an appropriate .gitignore file; if not, create one based on the current technology stack. If it already exists, update it to match the technology stack and ensure it includes these automation files: patch_raw.txt, todo.md, plan.json, commit_msg.txt

Output format:
\`\`\`diff
[your unified diff here]
\`\`\`

Generate the implementation now."

echo "[INFO] Invoking Copilot for code generation (timeout: 3600s)..."
if timeout 3600 copilot -p "$IMPL_PROMPT" --allow-all-tools > patch_raw.txt 2>&1; then
  echo "[INFO] Copilot code generation completed"
  # Clean ANSI escape sequences and carriage returns
  sed -E 's/\x1B\[[0-9;]*[A-Za-z]//g' patch_raw.txt | tr -d '\r' > patch_clean.txt
  mv patch_clean.txt patch_raw.txt
  # echo "[INFO] Raw output: $(cat patch_raw.txt)"
else
  EXIT_CODE=$?
  if [ $EXIT_CODE -eq 124 ]; then
    echo "[ERROR] Copilot timed out after 3600 seconds" >&2
  else
    echo "[ERROR] Copilot failed with exit code ${EXIT_CODE}" >&2
  fi
  cat patch_raw.txt >&2
  exit 1
fi

echo "[INFO] Copilot execution completed, checking for changes..."

GIT_USER_NAME="${COPILOT_AGENT_USERNAME:-Copilot}"
GIT_USER_EMAIL="${COPILOT_AGENT_COMMIT_EMAIL:-copilot@github.com}"

git config user.name "${GIT_USER_NAME}"
git config user.email "${GIT_USER_EMAIL}"

echo "[DEBUG] Current git status:"
git status

echo "[DEBUG] Checking for tracked file modifications..."
if ! git diff --quiet 2>/dev/null; then
  echo "[DEBUG] Found modified tracked files"
fi

if ! git diff --cached --quiet 2>/dev/null; then
  echo "[DEBUG] Found staged changes"
fi

# Check if there are any changes (tracked modifications or untracked files)
HAS_CHANGES=false

if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
  HAS_CHANGES=true
fi

echo "[DEBUG] Listing untracked files..."
git ls-files --others --exclude-standard || true

# Exclude intermediate files from being tracked
UNTRACKED_FILES=$(git ls-files --others --exclude-standard | grep -v -E '(patch_raw\.txt|copilot\.patch|todo\.md|todo_completed\.md|plan\.json|commit_msg\.txt|commit_msg_raw\.txt|__pycache__|\.pyc$)' || true)

echo "[DEBUG] Untracked files to be added: ${UNTRACKED_FILES:-<none>}"

if [ -n "$UNTRACKED_FILES" ]; then
  HAS_CHANGES=true
fi

if [ "$HAS_CHANGES" = true ]; then
  echo "[INFO] Changes detected, staging files (excluding intermediate files)..."
  
  # Stage tracked file modifications
  echo "[DEBUG] Staging modified tracked files..."
  git add -u || {
    echo "[ERROR] Failed to stage tracked files" >&2
    git status
    exit 1
  }
  
  # Add new files except intermediate ones
  if [ -n "$UNTRACKED_FILES" ]; then
    echo "[DEBUG] Adding new files: $UNTRACKED_FILES"
    echo "$UNTRACKED_FILES" | xargs -r git add || {
      echo "[ERROR] Failed to add new files" >&2
      exit 1
    }
  fi
  
  echo "[DEBUG] Staged changes:"
  git diff --cached --stat
  
  echo "[INFO] Generating commit message with Copilot..."
  COMMIT_MSG_PROMPT="Generate a concise conventional commit message for the following changes.
  
Changes summary:
$(git diff --cached --stat)

Requirements:
- Use conventional commit format (e.g., feat:, fix:, refactor:)
- Keep it under 72 characters
- Be descriptive but concise
- Output ONLY the commit message, no explanations or context
- Write the commit message to a file named 'commit_msg.txt'

Generate the commit message now."

  # Let Copilot create the file directly
  timeout 60 copilot -p "$COMMIT_MSG_PROMPT" --allow-all-tools 2>&1 || true
  
  # Read the commit message from the file created by Copilot
  if [ -f commit_msg.txt ]; then
    COMMIT_MSG=$(cat commit_msg.txt | tr -d '\r\n' | xargs)
  else
    COMMIT_MSG=""
  fi
  
  if [ -z "$COMMIT_MSG" ]; then
    COMMIT_MSG="feat: implement tasks via copilot automation"
    echo "[WARN] Failed to generate commit message, using default"
  else
    echo "[INFO] Generated commit message: $COMMIT_MSG"
  fi
  
  echo "[DEBUG] Committing changes..."
  if ! git commit -m "$COMMIT_MSG"; then
    echo "[ERROR] Git commit failed" >&2
    git status
    exit 1
  fi
  
  echo "[INFO] Pushing changes to ${NEW_BRANCH_NAME}..."
  
  # Retry push up to 3 times
  PUSH_RETRY=0
  PUSH_MAX_RETRIES=3
  PUSH_SUCCESS=false
  
  while [ $PUSH_RETRY -lt $PUSH_MAX_RETRIES ]; do
    echo "[DEBUG] Push attempt $((PUSH_RETRY + 1))/$PUSH_MAX_RETRIES..."
    
    if git push --set-upstream origin "${NEW_BRANCH_NAME}" 2>&1; then
      PUSH_SUCCESS=true
      echo "[INFO] Push succeeded"
      break
    else
      PUSH_RETRY=$((PUSH_RETRY + 1))
      if [ $PUSH_RETRY -lt $PUSH_MAX_RETRIES ]; then
        echo "[WARN] Push failed, retrying in 5 seconds..." >&2
        sleep 5
      fi
    fi
  done
  
  if [ "$PUSH_SUCCESS" = false ]; then
    echo "[ERROR] Failed to push after $PUSH_MAX_RETRIES attempts" >&2
    git status
    git remote -v
    exit 1
  fi
else
  echo "[ERROR] No changes were generated by Copilot" >&2
  echo "[DEBUG] Final git status:"
  git status
  echo "[DEBUG] All files in directory:"
  ls -la
  exit 1
fi

python3 <<'PY'
from pathlib import Path

text = Path("todo.md").read_text(encoding="utf-8")
done = text.replace("[ ]", "[x]")
Path("todo_completed.md").write_text(done if done.endswith("\n") else done + "\n", encoding="utf-8")
PY

cd "${REPO_ROOT}"
