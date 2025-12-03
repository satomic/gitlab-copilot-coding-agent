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
require_env TARGET_MR_IID
require_env MR_TITLE
require_env MR_DESCRIPTION

if ! command -v copilot >/dev/null; then
  echo "[ERROR] copilot CLI not found in PATH" >&2
  exit 1
fi

echo "[INFO] Processing MR code review request with inline comments..."
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

export API="${UPSTREAM_GITLAB_BASE_URL}/api/v4/projects/${TARGET_PROJECT_ID}"

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

echo "[INFO] Getting commit SHAs for position info..."
export BASE_SHA=$(git rev-parse "origin/${TARGET_BRANCH}")
export HEAD_SHA=$(git rev-parse "origin/${SOURCE_BRANCH}")
export START_SHA=$(git merge-base "origin/${TARGET_BRANCH}" "origin/${SOURCE_BRANCH}")

echo "[DEBUG] BASE_SHA=${BASE_SHA}"
echo "[DEBUG] HEAD_SHA=${HEAD_SHA}"
echo "[DEBUG] START_SHA=${START_SHA}"

echo "[INFO] Getting diff between ${TARGET_BRANCH} and ${SOURCE_BRANCH}..."

# Get the diff
DIFF_OUTPUT=$(git diff "origin/${TARGET_BRANCH}...${SOURCE_BRANCH}" || echo "")

if [ -z "$DIFF_OUTPUT" ]; then
  echo "[WARN] No changes found between branches"

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

# Get list of changed files with line numbers
CHANGED_FILES=$(git diff --name-only "origin/${TARGET_BRANCH}...${SOURCE_BRANCH}" | tr '\n' ', ' | sed 's/,$//')

echo "[INFO] Changed files: ${CHANGED_FILES}"

# Get commit messages
COMMIT_MESSAGES=$(git log --oneline "origin/${TARGET_BRANCH}..${SOURCE_BRANCH}" || echo "")

# Get detailed file changes for review
git diff "origin/${TARGET_BRANCH}...${SOURCE_BRANCH}" > full_diff.txt

echo "[INFO] Building review prompt for Copilot..."

# Load code review prompt template
REVIEW_PROMPT=$(load_prompt "code_review" \
  "mr_title=${MR_TITLE}" \
  "mr_description=${MR_DESCRIPTION}" \
  "source_branch=${SOURCE_BRANCH}" \
  "target_branch=${TARGET_BRANCH}" \
  "changed_files=${CHANGED_FILES}" \
  "commit_messages=${COMMIT_MESSAGES}" \
  "code_diff=${DIFF_OUTPUT}")

echo "[INFO] Invoking Copilot for code review (timeout: 3600s)..."
if timeout 3600 copilot -p "$REVIEW_PROMPT" --allow-all-tools > review_raw.txt 2>&1; then
  echo "[INFO] Copilot code review completed"
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

echo "[INFO] Checking for review_findings.json..."
if [ ! -f review_findings.json ]; then
  echo "[WARN] review_findings.json not found, will post general comment only"

  # Fallback to general comment
  if [ -f review_summary.txt ]; then
    REVIEW_SUMMARY=$(cat review_summary.txt)
  else
    REVIEW_SUMMARY=$(cat review_raw.txt)
  fi

  REVIEW_BODY="## 🤖 Copilot Code Review

${REVIEW_SUMMARY}"

  if [ -n "${CI_PIPELINE_URL:-}" ]; then
    REVIEW_BODY="${REVIEW_BODY}

---
- [🔗 Review Session](${CI_PIPELINE_URL})"
  fi

  echo "$REVIEW_BODY" > review_comment.txt

  curl --silent --show-error --fail \
    --request POST \
    --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
    --data-urlencode "body@review_comment.txt" \
    "${API}/merge_requests/${TARGET_MR_IID}/notes" > /dev/null || true

  exit 0
fi

echo "[INFO] Parsing review findings and posting inline comments..."

# Process findings and post inline comments
python3 <<'PYSCRIPT'
import json
import os
import sys
import subprocess
from pathlib import Path
from typing import Dict, List, Any

def post_inline_discussion(
    api_url: str,
    token: str,
    mr_iid: str,
    base_sha: str,
    start_sha: str,
    head_sha: str,
    file_path: str,
    line_number: int,
    comment_body: str
) -> bool:
    """Post an inline discussion comment on a specific line."""

    discussions_url = f"{api_url}/merge_requests/{mr_iid}/discussions"

    # Build curl command with proper form field names for position
    # GitLab expects position[xxx] format for nested parameters
    cmd = [
        "curl", "--silent", "--show-error",
        "--request", "POST",
        "--header", f"PRIVATE-TOKEN: {token}",
        "--data-urlencode", f"body={comment_body}",
        "--data-urlencode", f"position[base_sha]={base_sha}",
        "--data-urlencode", f"position[start_sha]={start_sha}",
        "--data-urlencode", f"position[head_sha]={head_sha}",
        "--data-urlencode", "position[position_type]=text",
        "--data-urlencode", f"position[new_path]={file_path}",
        "--data-urlencode", f"position[new_line]={line_number}",
        discussions_url
    ]

    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        if result.returncode == 0:
            print(f"[INFO] Posted inline comment on {file_path}:{line_number}")
            return True
        else:
            # Print the error response for debugging
            error_msg = result.stderr if result.stderr else result.stdout
            print(f"[WARN] Failed to post inline comment on {file_path}:{line_number}", file=sys.stderr)
            if error_msg:
                print(f"[DEBUG] Error: {error_msg[:200]}", file=sys.stderr)
            return False
    except Exception as e:
        print(f"[WARN] Exception posting inline comment: {e}", file=sys.stderr)
        return False

def post_general_comment(api_url: str, token: str, mr_iid: str, body: str) -> bool:
    """Post a general comment on the MR."""
    notes_url = f"{api_url}/merge_requests/{mr_iid}/notes"

    cmd = [
        "curl", "--silent", "--show-error", "--fail",
        "--request", "POST",
        "--header", f"PRIVATE-TOKEN: {token}",
        "--data-urlencode", f"body={body}",
        notes_url
    ]

    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        return result.returncode == 0
    except Exception as e:
        print(f"[WARN] Exception posting general comment: {e}", file=sys.stderr)
        return False

try:
    # Load review findings
    findings_file = Path("review_findings.json")
    if not findings_file.exists():
        print("[ERROR] review_findings.json not found", file=sys.stderr)
        sys.exit(1)

    with open(findings_file, 'r', encoding='utf-8') as f:
        review_data = json.load(f)

    # Get environment variables
    api_url = os.environ["API"]
    token = os.environ["GITLAB_TOKEN"]
    mr_iid = os.environ["TARGET_MR_IID"]
    base_sha = os.environ["BASE_SHA"]
    start_sha = os.environ["START_SHA"]
    head_sha = os.environ["HEAD_SHA"]
    pipeline_url = os.environ.get("CI_PIPELINE_URL", "")

    summary = review_data.get("summary", "No summary provided")
    recommendation = review_data.get("recommendation", "NEEDS_DISCUSSION")
    findings = review_data.get("findings", [])

    print(f"[INFO] Found {len(findings)} review findings")

    # Post inline comments for each finding
    severity_emoji = {
        "critical": "🔴",
        "major": "🟠",
        "minor": "🟡",
        "suggestion": "💡"
    }

    inline_count = 0
    failed_inlines = []

    for finding in findings:
        severity = finding.get("severity", "minor")
        category = finding.get("category", "general")
        file_path = finding.get("file", "")
        line = finding.get("line", 0)
        title = finding.get("title", "Issue found")
        description = finding.get("description", "")
        suggestion = finding.get("suggestion", "")

        if not file_path or line <= 0:
            print(f"[WARN] Skipping finding with invalid file/line: {title}")
            failed_inlines.append(finding)
            continue

        emoji = severity_emoji.get(severity, "ℹ️")

        comment_body = f"""{emoji} **{severity.upper()}**: {title}

**Category**: {category}

**Issue**: {description}

**Suggestion**: {suggestion}"""

        success = post_inline_discussion(
            api_url, token, mr_iid,
            base_sha, start_sha, head_sha,
            file_path, line, comment_body
        )

        if success:
            inline_count += 1
        else:
            failed_inlines.append(finding)

    print(f"[INFO] Posted {inline_count} inline comments")

    # Build summary comment
    summary_body = f"""## 🤖 Copilot Code Review Summary

**Overall Assessment**: {summary}

**Recommendation**: **{recommendation}**

**Review Statistics**:
- 🔴 Critical: {sum(1 for f in findings if f.get('severity') == 'critical')}
- 🟠 Major: {sum(1 for f in findings if f.get('severity') == 'major')}
- 🟡 Minor: {sum(1 for f in findings if f.get('severity') == 'minor')}
- 💡 Suggestions: {sum(1 for f in findings if f.get('severity') == 'suggestion')}

**Total Issues Found**: {len(findings)}
**Inline Comments Posted**: {inline_count}
"""

    # Add failed inlines to summary if any
    if failed_inlines:
        summary_body += f"\n### ⚠️ Additional Findings\n\n"
        summary_body += "The following issues could not be posted as inline comments:\n\n"

        for finding in failed_inlines:
            severity = finding.get("severity", "minor")
            emoji = severity_emoji.get(severity, "ℹ️")
            file_path = finding.get("file", "unknown")
            line = finding.get("line", 0)
            title = finding.get("title", "Issue")
            description = finding.get("description", "")
            suggestion = finding.get("suggestion", "")

            summary_body += f"""
{emoji} **{severity.upper()}**: {title}
- **File**: `{file_path}:{line}`
- **Issue**: {description}
- **Suggestion**: {suggestion}

"""

    if pipeline_url:
        summary_body += f"\n---\n- [🔗 Review Session]({pipeline_url})"

    # Save and post summary
    Path("review_summary_final.txt").write_text(summary_body, encoding="utf-8")

    print("[INFO] Posting summary comment...")
    post_general_comment(api_url, token, mr_iid, summary_body)

    print("[INFO] Review complete!")

except json.JSONDecodeError as e:
    print(f"[ERROR] Invalid JSON in review_findings.json: {e}", file=sys.stderr)
    sys.exit(1)
except Exception as e:
    print(f"[ERROR] Error processing review: {e}", file=sys.stderr)
    import traceback
    traceback.print_exc()
    sys.exit(1)
PYSCRIPT

cd "${REPO_ROOT}"

echo "[INFO] Code review with inline comments completed successfully"
