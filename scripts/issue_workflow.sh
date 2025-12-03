#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/common.sh"

cd "${REPO_ROOT}"

# ============================================================================
# Step 1: Post Acknowledgment to Issue
# ============================================================================
echo "=========================================="
echo "STEP 1: Post Acknowledgment to Issue"
echo "=========================================="

require_env GITLAB_TOKEN
require_env TARGET_PROJECT_ID
require_env TARGET_ISSUE_IID

echo "[INFO] Posting acknowledgment to issue ${TARGET_ISSUE_IID}..."

NOTE_BODY="👀 Got it! Copilot Coding task 🚀 started at $(date -Iseconds)."

if [ -n "${CI_PIPELINE_URL:-}" ]; then
  NOTE_BODY="${NOTE_BODY}

---
- [🔗 Copilot Coding Session](${CI_PIPELINE_URL})"
fi

if ! curl --fail --silent --show-error \
  --request POST \
  --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
  --data-urlencode "body=${NOTE_BODY}" \
  "${UPSTREAM_GITLAB_BASE_URL}/api/v4/projects/${TARGET_PROJECT_ID}/issues/${TARGET_ISSUE_IID}/notes" > /dev/null; then
  echo "[WARN] Failed to post acknowledgment comment" >&2
fi

echo "[INFO] Acknowledgment posted successfully"

# ============================================================================
# Step 2: Generate TODO Plan with Copilot
# ============================================================================
echo ""
echo "=========================================="
echo "STEP 2: Generate TODO Plan with Copilot"
echo "=========================================="

require_env ORIGINAL_NEEDS
require_env ISSUE_TITLE
require_env TARGET_PROJECT_PATH

if ! command -v copilot >/dev/null; then
  echo "[ERROR] copilot CLI not found in PATH" >&2
  exit 1
fi

echo "[INFO] Generating execution plan with Copilot..."

PLAN_PROMPT="You are GitHub Copilot CLI acting as a technical delivery lead.

Task: Analyze the following GitLab issue and generate a concrete engineering plan.

Issue Context:
- Title: ${ISSUE_TITLE}
- IID: ${TARGET_ISSUE_IID}
- Project: ${TARGET_PROJECT_PATH}
- URL: ${ISSUE_URL}

Issue Description:
${ORIGINAL_NEEDS}

CRITICAL: You must write your response directly to a file named 'plan.json' in the current directory.
Use the file writing capability to create this file with valid JSON containing exactly two keys:
1. \"branch\": A kebab-case branch name (e.g., issue-${TARGET_ISSUE_IID}-add-login-feature)
2. \"todo_markdown\": A Markdown checklist with actionable tasks using - [ ] format

Requirements for the plan:
- Break the issue into concrete, testable steps
- Reference specific files/components when applicable
- Include implementation, testing, and documentation tasks
- Keep tasks focused and atomic
- Use clear, imperative language

Example JSON structure to write to plan.json:
{
  \"branch\": \"issue-${TARGET_ISSUE_IID}-implement-feature\",
  \"todo_markdown\": \"- [ ] Create auth module\\n- [ ] Add unit tests\\n- [ ] Update documentation\"
}

Write the JSON file now. Do not output anything else."

echo "[INFO] Invoking Copilot to generate plan.json (timeout: 3600s)..."
if timeout 3600 copilot -p "$PLAN_PROMPT" --allow-all-tools > copilot_output.log 2>&1; then
  echo "[INFO] Copilot execution completed"
else
  EXIT_CODE=$?
  if [ $EXIT_CODE -eq 124 ]; then
    echo "[ERROR] Copilot timed out after 3600 seconds" >&2
  else
    echo "[ERROR] Copilot failed with exit code ${EXIT_CODE}" >&2
  fi
  cat copilot_output.log >&2
  exit 1
fi

echo "[INFO] Checking for plan.json..."
if [ ! -f plan.json ]; then
  echo "[ERROR] plan.json not found. Copilot did not create the expected file." >&2
  echo "Copilot output:" >&2
  cat copilot_output.log >&2
  exit 1
fi

echo "[INFO] Parsing plan.json..."
python3 <<'PY'
import json
from pathlib import Path

try:
    plan_file = Path("plan.json")
    data = json.loads(plan_file.read_text(encoding="utf-8"))

    branch = data.get("branch", "").strip()
    todo = data.get("todo_markdown", "").strip()

    if not branch:
        raise SystemExit("plan.json missing 'branch' field")
    if not todo:
        raise SystemExit("plan.json missing 'todo_markdown' field")

    if not todo.endswith("\n"):
        todo += "\n"
    Path("todo.md").write_text(todo, encoding="utf-8")

    with open("plan.env", "w", encoding="utf-8") as env_file:
        env_file.write(f"NEW_BRANCH_NAME={branch}\n")
        env_file.write("TODO_FILE=todo.md\n")

    plan_file.unlink()
    print("[INFO] plan.json parsed and deleted successfully")

except json.JSONDecodeError as e:
    raise SystemExit(f"Invalid JSON in plan.json: {e}")
except Exception as e:
    raise SystemExit(f"Error processing plan.json: {e}")
PY

# Source the generated environment variables
source plan.env

echo "[INFO] Plan generated successfully"
echo "  Branch: ${NEW_BRANCH_NAME}"
echo "  TODO file: todo.md"

# ============================================================================
# Step 3: Create Merge Request
# ============================================================================
echo ""
echo "=========================================="
echo "STEP 3: Create Merge Request"
echo "=========================================="

require_env TARGET_BRANCH
require_env NEW_BRANCH_NAME

echo "[INFO] Creating merge request for branch ${NEW_BRANCH_NAME}..."

API="${UPSTREAM_GITLAB_BASE_URL}/api/v4/projects/${TARGET_PROJECT_ID}"

echo "[INFO] Ensuring branch ${NEW_BRANCH_NAME} exists..."
if curl --silent --show-error --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
  --data "branch=${NEW_BRANCH_NAME}" \
  --data "ref=${TARGET_BRANCH}" \
  --request POST "${API}/repository/branches" > /dev/null 2>&1; then
  echo "[INFO] Branch created"
else
  echo "[INFO] Branch may already exist"
fi

TODO_BODY="$(cat todo.md)"

MR_DESC="## TODO
${TODO_BODY}

---
- Original issue: ${ISSUE_URL:-unknown}"

if [ -n "${CI_PIPELINE_URL:-}" ]; then
  MR_DESC="${MR_DESC}
- [🔗 Copilot Coding Session](${CI_PIPELINE_URL})"
fi

cat <<EOF > mr_description.txt
${MR_DESC}
EOF

MR_TITLE="Copilot Generated MR for issue #${TARGET_ISSUE_IID:-unknown}"

echo "[INFO] Creating merge request: ${MR_TITLE}..."
if ! curl --silent --show-error --fail \
  --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
  --data-urlencode "source_branch=${NEW_BRANCH_NAME}" \
  --data-urlencode "target_branch=${TARGET_BRANCH}" \
  --data-urlencode "title=${MR_TITLE}" \
  --data-urlencode description@mr_description.txt \
  "${API}/merge_requests" > mr.json; then
  echo "[ERROR] Failed to create merge request" >&2
  exit 1
fi

echo "[INFO] Parsing merge request response..."
python3 <<'PY'
import json
from pathlib import Path

data = json.loads(Path("mr.json").read_text(encoding="utf-8"))
iid = data.get("iid")
url = data.get("web_url", "")
if not iid:
    raise SystemExit("Merge request creation failed")
Path("mr.env").write_text(f"NEW_MR_IID={iid}\nNEW_MR_URL={url}\n", encoding="utf-8")
PY

# Source the MR environment variables
source mr.env

echo "[INFO] Merge request created successfully"
echo "  MR IID: ${NEW_MR_IID}"
echo "  MR URL: ${NEW_MR_URL}"

# ============================================================================
# Step 4: Implement Tasks with Copilot
# ============================================================================
echo ""
echo "=========================================="
echo "STEP 4: Implement Tasks with Copilot"
echo "=========================================="

require_env TARGET_REPO_URL

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

HAS_CHANGES=false

if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
  HAS_CHANGES=true
fi

UNTRACKED_FILES=$(git ls-files --others --exclude-standard | grep -v -E '(patch_raw\.txt|copilot\.patch|todo\.md|todo_completed\.md|plan\.json|commit_msg\.txt|commit_msg_raw\.txt|__pycache__|\.pyc$)' || true)

if [ -n "$UNTRACKED_FILES" ]; then
  HAS_CHANGES=true
fi

if [ "$HAS_CHANGES" = true ]; then
  echo "[INFO] Changes detected, staging files..."

  git add -u || {
    echo "[ERROR] Failed to stage tracked files" >&2
    exit 1
  }

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

  timeout 60 copilot -p "$COMMIT_MSG_PROMPT" --allow-all-tools 2>&1 || true

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
    exit 1
  fi

  echo "[INFO] Pushing changes to ${NEW_BRANCH_NAME}..."

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
    exit 1
  fi
else
  echo "[ERROR] No changes were generated by Copilot" >&2
  exit 1
fi

python3 <<'PY'
from pathlib import Path

text = Path("todo.md").read_text(encoding="utf-8")
done = text.replace("[ ]", "[x]")
Path("todo_completed.md").write_text(done if done.endswith("\n") else done + "\n", encoding="utf-8")
PY

cd "${REPO_ROOT}"

# ============================================================================
# Step 5: Finalize Workflow
# ============================================================================
echo ""
echo "=========================================="
echo "STEP 5: Finalize Workflow"
echo "=========================================="

echo "[INFO] Finalizing automation workflow..."

if [ ! -f repo-b/todo_completed.md ]; then
  echo "[WARN] todo_completed.md not found, using original todo.md"
  cp todo.md ./todo_completed.md
else
  cp repo-b/todo_completed.md ./todo_completed.md
fi

TODO_BODY="$(cat todo_completed.md)"

MR_DESC="## TODO
${TODO_BODY}

---
- Original issue: ${ISSUE_URL:-unknown}"

if [ -n "${CI_PIPELINE_URL:-}" ]; then
  MR_DESC="${MR_DESC}
- [🔗 Copilot Coding Session](${CI_PIPELINE_URL})"
fi

cat <<EOF > updated_description.txt
${MR_DESC}
EOF

echo "[INFO] Updating MR ${NEW_MR_IID} description..."

if [[ -n "${ISSUE_AUTHOR_ID:-}" ]]; then
  REVIEWER_ARGS=(--data "reviewer_ids[]=${ISSUE_AUTHOR_ID}")
else
  REVIEWER_ARGS=()
fi

CURL_ARGS=(
  --silent --show-error --fail
  --request PUT
  --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}"
  --data-urlencode description@updated_description.txt
)

if [[ ${#REVIEWER_ARGS[@]} -gt 0 ]]; then
  CURL_ARGS+=("${REVIEWER_ARGS[@]}")
fi

if ! curl "${CURL_ARGS[@]}" "${API}/merge_requests/${NEW_MR_IID}" > /dev/null; then
  echo "[ERROR] Failed to update MR description" >&2
  exit 1
fi

echo "[INFO] Posting completion comment to issue ${TARGET_ISSUE_IID}..."
if ! curl --silent --show-error --fail \
  --request POST \
  --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
  --data-urlencode "body=🤖 Copilot Coding completed, the latest TODO has been synced to MR: ${NEW_MR_URL} 👈" \
  "${API}/issues/${TARGET_ISSUE_IID}/notes" > /dev/null; then
  echo "[ERROR] Failed to post issue comment" >&2
  exit 1
fi

echo ""
echo "=========================================="
echo "WORKFLOW COMPLETED SUCCESSFULLY"
echo "=========================================="
echo "  MR URL: ${NEW_MR_URL}"
echo "  Issue: ${ISSUE_URL}"
echo "=========================================="
