#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/common.sh"

cd "${REPO_ROOT}"

require_env GITLAB_TOKEN
require_env TARGET_REPO_URL
require_env TARGET_BRANCH
require_env SOURCE_BRANCH
require_env TARGET_MR_IID
require_env MR_TITLE
require_env MR_DESCRIPTION

if ! command -v copilot >/dev/null; then
  echo "[ERROR] copilot CLI not found in PATH" >&2
  exit 1
fi

echo "[INFO] Processing MR code review request..."
echo "[INFO] MR Title: ${MR_TITLE}"
echo "[INFO] MR IID: ${TARGET_MR_IID}"

# Post acknowledgment comment to MR
echo "[INFO] Posting acknowledgment to MR ${TARGET_MR_IID}..."

NOTE_BODY="👀 Starting code review! 🔍 Copilot is analyzing your changes at $(date -Iseconds)."

if [ -n "${CI_PIPELINE_URL:-}" ]; then
  NOTE_BODY="${NOTE_BODY}

---
- [🔗 Review Session](${CI_PIPELINE_URL})"
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

echo "[INFO] Fetching branches..."
git fetch origin "${SOURCE_BRANCH}" "${TARGET_BRANCH}" >/dev/null 2>&1 || {
  echo "[ERROR] Failed to fetch branches" >&2
  exit 1
}

echo "[INFO] Checking out source branch ${SOURCE_BRANCH}..."
git checkout "${SOURCE_BRANCH}" >/dev/null 2>&1 || {
  echo "[ERROR] Failed to checkout source branch ${SOURCE_BRANCH}" >&2
  exit 1
}

echo "[INFO] Getting diff between ${TARGET_BRANCH} and ${SOURCE_BRANCH}..."

# Get the diff
DIFF_OUTPUT=$(git diff "origin/${TARGET_BRANCH}...${SOURCE_BRANCH}" || echo "")

if [ -z "$DIFF_OUTPUT" ]; then
  echo "[WARN] No changes found between branches"

  # Post no-changes comment
  NO_CHANGE_BODY="🤖 No code changes detected between **${TARGET_BRANCH}** and **${SOURCE_BRANCH}**.

The branches appear to be in sync."

  if [ -n "${CI_PIPELINE_URL:-}" ]; then
    NO_CHANGE_BODY="${NO_CHANGE_BODY}

---
- [🔗 Review Session](${CI_PIPELINE_URL})"
  fi

  curl --silent --show-error --fail \
    --request POST \
    --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
    --data-urlencode "body=${NO_CHANGE_BODY}" \
    "${API}/merge_requests/${TARGET_MR_IID}/notes" > /dev/null || true

  exit 0
fi

# Get list of changed files
CHANGED_FILES=$(git diff --name-only "origin/${TARGET_BRANCH}...${SOURCE_BRANCH}" | tr '\n' ', ' | sed 's/,$//')

echo "[INFO] Changed files: ${CHANGED_FILES}"

# Get commit messages
COMMIT_MESSAGES=$(git log --oneline "origin/${TARGET_BRANCH}..${SOURCE_BRANCH}" || echo "")

echo "[INFO] Building review prompt for Copilot..."

# Build comprehensive review prompt
REVIEW_PROMPT="You are GitHub Copilot CLI acting as an expert code reviewer.

**Merge Request Information:**
- Title: ${MR_TITLE}
- Description: ${MR_DESCRIPTION}
- Source Branch: ${SOURCE_BRANCH}
- Target Branch: ${TARGET_BRANCH}

**Changed Files:**
${CHANGED_FILES}

**Recent Commits:**
${COMMIT_MESSAGES}

**Code Diff:**
\`\`\`diff
${DIFF_OUTPUT}
\`\`\`

**Your Task:**
Perform a comprehensive code review focusing on:

1. **Code Quality**
   - Code structure and organization
   - Naming conventions and readability
   - Code duplication and reusability
   - Complexity and maintainability

2. **Best Practices**
   - Design patterns and architectural decisions
   - Error handling and edge cases
   - Resource management (memory, connections, etc.)
   - Logging and debugging capabilities

3. **Security**
   - Input validation and sanitization
   - Authentication and authorization
   - Security vulnerabilities (SQL injection, XSS, etc.)
   - Sensitive data handling

4. **Performance**
   - Algorithm efficiency
   - Database query optimization
   - Caching strategies
   - Potential bottlenecks

5. **Testing**
   - Test coverage
   - Test quality and relevance
   - Missing test cases

6. **Documentation**
   - Code comments
   - API documentation
   - README updates if needed

**Output Requirements:**
- Start with an overall summary (2-3 sentences)
- List findings by severity: Critical, Major, Minor, Suggestions
- For each finding, include:
  - File and line reference
  - Clear description of the issue
  - Recommended fix or improvement
- End with a recommendation: APPROVE, REQUEST_CHANGES, or NEEDS_DISCUSSION
- Use markdown formatting for clarity
- Write the review to a file named 'review_summary.txt'

Generate the comprehensive code review now."

echo "[INFO] Invoking Copilot for code review (timeout: 3600s)..."
if timeout 3600 copilot -p "$REVIEW_PROMPT" --allow-all-tools > review_raw.txt 2>&1; then
  echo "[INFO] Copilot code review completed"
  # Clean ANSI escape sequences and carriage returns
  sed -E 's/\x1B\[[0-9;]*[A-Za-z]//g' review_raw.txt | tr -d '\r' > review_clean.txt
  mv review_clean.txt review_raw.txt
else
  EXIT_CODE=$?
  if [ $EXIT_CODE -eq 124 ]; then
    echo "[ERROR] Copilot timed out after 3600 seconds" >&2
  else
    echo "[ERROR] Copilot failed with exit code ${EXIT_CODE}" >&2
  fi
  cat review_raw.txt >&2
  exit 1
fi

echo "[INFO] Reading review summary..."

# Read the review summary
if [ -f review_summary.txt ]; then
  REVIEW_SUMMARY=$(cat review_summary.txt)
else
  # Fallback: use the raw output
  REVIEW_SUMMARY=$(cat review_raw.txt)
  echo "[WARN] review_summary.txt not found, using raw output"
fi

# Post review comment to MR
echo "[INFO] Posting review comment to MR ${TARGET_MR_IID}..."

REVIEW_BODY="## 🤖 Copilot Code Review

${REVIEW_SUMMARY}"

if [ -n "${CI_PIPELINE_URL:-}" ]; then
  REVIEW_BODY="${REVIEW_BODY}

---
- [🔗 Review Session](${CI_PIPELINE_URL})"
fi

# Save review body to a temp file for better handling of multiline content
echo "$REVIEW_BODY" > review_comment.txt

if ! curl --silent --show-error --fail \
  --request POST \
  --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
  --data-urlencode "body@review_comment.txt" \
  "${API}/merge_requests/${TARGET_MR_IID}/notes" > /dev/null; then
  echo "[WARN] Failed to post review comment" >&2
fi

echo "[INFO] Review comment posted successfully"

cd "${REPO_ROOT}"
