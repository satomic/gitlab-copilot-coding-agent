#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/common.sh"
# shellcheck source=scripts/load_prompt.sh
source "${SCRIPT_DIR}/load_prompt.sh"

cd "${REPO_ROOT}"

require_env GITLAB_TOKEN
require_env TARGET_REPO_URL
require_env TARGET_BRANCH
require_env SOURCE_BRANCH
require_env NEW_BRANCH_NAME
require_env TARGET_MR_IID
require_env MR_NOTE_INSTRUCTION

if ! command -v copilot >/dev/null; then
  echo "[ERROR] copilot CLI not found in PATH" >&2
  exit 1
fi

echo "[INFO] Processing MR note request..."
echo "[INFO] Instruction: ${MR_NOTE_INSTRUCTION}"

# Post acknowledgment comment to MR
echo "[INFO] Posting acknowledgment to MR ${TARGET_MR_IID}..."

# Load acknowledgment message template
NOTE_BODY=$(load_prompt "issue_ack" "timestamp=$(date -Iseconds)")

if [ -n "${CI_PIPELINE_URL:-}" ]; then
  NOTE_BODY="${NOTE_BODY}

---
- [🔗 Copilot Coding Session](${CI_PIPELINE_URL})"
fi

API="${UPSTREAM_GITLAB_BASE_URL}/api/v4/projects/${TARGET_PROJECT_ID}"

if ! curl --fail --silent --show-error \
  --request POST \
  --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
  --data-urlencode "body=${NOTE_BODY}" \
  "${API}/merge_requests/${TARGET_MR_IID}/notes" > /dev/null; then
  echo "[WARN] Failed to post acknowledgment comment" >&2
fi

echo "[INFO] Acknowledgment posted successfully"

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

echo "[INFO] Checking out source branch ${SOURCE_BRANCH}..."
git fetch origin "${SOURCE_BRANCH}" >/dev/null 2>&1 || {
  echo "[ERROR] Failed to fetch source branch ${SOURCE_BRANCH}" >&2
  exit 1
}
git checkout "${SOURCE_BRANCH}" >/dev/null 2>&1 || {
  echo "[ERROR] Failed to checkout source branch ${SOURCE_BRANCH}" >&2
  exit 1
}

echo "[INFO] Building implementation prompt for Copilot..."

# Get repository context
REPO_FILES=$(find . -type f -not -path '*/.git/*' -not -path '*/node_modules/*' | head -50 | tr '\n' ', ')

IMPL_PROMPT="You are GitHub Copilot CLI acting as a coding agent.

Repository Context:
- Path: $(pwd)
- Branch: ${SOURCE_BRANCH}
- Base branch: ${TARGET_BRANCH}
- Sample files: ${REPO_FILES}

User Request:
${MR_NOTE_INSTRUCTION}

Your job:
1. Analyze the repository structure
2. Implement the requested changes based on the user instruction above
3. Generate a unified diff patch with your changes
4. Enclose the patch in triple backticks with 'diff' language marker

Requirements:
- Produce working, tested code
- Follow existing code style and patterns
- Include necessary imports and dependencies
- Add inline comments for complex logic
- Check if there is an appropriate .gitignore file; if not, create one based on the current technology stack. If it already exists, update it to match the technology stack and ensure it includes these automation files: patch_raw.txt, todo.md, plan.json, commit_msg.txt, mr_summary.txt

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
UNTRACKED_FILES=$(git ls-files --others --exclude-standard | grep -v -E '(patch_raw\.txt|copilot\.patch|todo\.md|todo_completed\.md|plan\.json|commit_msg\.txt|commit_msg_raw\.txt|mr_summary\.txt|__pycache__|\.pyc$)' || true)

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

  # Load commit message generation prompt template
  COMMIT_MSG_PROMPT=$(load_prompt "commit_msg" "changes_summary=$(git diff --cached --stat)")

  # Let Copilot create the file directly
  timeout 60 copilot -p "$COMMIT_MSG_PROMPT" --allow-all-tools 2>&1 || true
  
  # Read the commit message from the file created by Copilot
  if [ -f commit_msg.txt ]; then
    COMMIT_MSG=$(cat commit_msg.txt | tr -d '\r\n' | xargs)
  else
    COMMIT_MSG=""
  fi
  
  if [ -z "$COMMIT_MSG" ]; then
    COMMIT_MSG="feat: apply updates from MR note"
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
  
  echo "[INFO] Pushing changes to ${SOURCE_BRANCH}..."
  
  # Retry push up to 3 times
  PUSH_RETRY=0
  PUSH_MAX_RETRIES=3
  PUSH_SUCCESS=false
  
  while [ $PUSH_RETRY -lt $PUSH_MAX_RETRIES ]; do
    echo "[DEBUG] Push attempt $((PUSH_RETRY + 1))/$PUSH_MAX_RETRIES..."
    
    if git push origin "${SOURCE_BRANCH}" 2>&1; then
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
  
  # Generate summary of changes
  echo "[INFO] Generating summary of changes..."
  
  SUMMARY_PROMPT="Generate a concise summary of the code changes that were made.
  
Changes:
$(git log --oneline -1)
$(git diff HEAD~1 --stat)

Requirements:
- Start with a brief one-line summary
- List key changes as bullet points
- Be clear and professional
- Output ONLY the summary, no extra context
- Write the summary to a file named 'mr_summary.txt'

Generate the summary now."

  timeout 60 copilot -p "$SUMMARY_PROMPT" --allow-all-tools 2>&1 || true
  
  # Read the summary
  if [ -f mr_summary.txt ]; then
    CHANGE_SUMMARY=$(cat mr_summary.txt)
  else
    CHANGE_SUMMARY="Applied requested changes: ${MR_NOTE_INSTRUCTION}"
  fi
  
  # Post completion comment to MR with summary
  echo "[INFO] Posting completion comment to MR ${TARGET_MR_IID}..."
  
  COMPLETION_BODY="🤖 Copilot Coding completed! ✅

**Changes Applied:**
${CHANGE_SUMMARY}

**Commit:** \`${COMMIT_MSG}\`"

  if [ -n "${CI_PIPELINE_URL:-}" ]; then
    COMPLETION_BODY="${COMPLETION_BODY}

---
- [🔗 Copilot Coding Session](${CI_PIPELINE_URL})"
  fi
  
  if ! curl --silent --show-error --fail \
    --request POST \
    --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
    --data-urlencode "body=${COMPLETION_BODY}" \
    "${API}/merge_requests/${TARGET_MR_IID}/notes" > /dev/null; then
    echo "[WARN] Failed to post MR comment" >&2
  fi
else
  echo "[WARN] No changes were generated by Copilot"
  echo "[DEBUG] Final git status:"
  git status
  
  # Post comment about no changes
  echo "[INFO] Posting no-changes comment to MR ${TARGET_MR_IID}..."
  
  NO_CHANGE_BODY="🤖 Copilot analyzed your request but determined no changes are needed.

**Request:** ${MR_NOTE_INSTRUCTION}"

  if [ -n "${CI_PIPELINE_URL:-}" ]; then
    NO_CHANGE_BODY="${NO_CHANGE_BODY}

---
- [🔗 Copilot Coding Session](${CI_PIPELINE_URL})"
  fi
  
  if ! curl --silent --show-error --fail \
    --request POST \
    --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
    --data-urlencode "body=${NO_CHANGE_BODY}" \
    "${API}/merge_requests/${TARGET_MR_IID}/notes" > /dev/null; then
    echo "[WARN] Failed to post MR comment" >&2
  fi
fi

cd "${REPO_ROOT}"
