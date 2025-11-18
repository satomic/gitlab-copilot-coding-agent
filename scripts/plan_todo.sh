#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

cd "${REPO_ROOT}"

require_env ORIGINAL_NEEDS
require_env ISSUE_TITLE
require_env TARGET_PROJECT_PATH

if ! command -v copilot >/dev/null; then
  echo "[ERROR] copilot CLI not found in PATH" >&2
  exit 1
fi

echo "[INFO] Generating execution plan with Copilot..."

# Build comprehensive prompt for Copilot
PLAN_PROMPT="You are GitHub Copilot CLI acting as a technical delivery lead.

Task: Analyze the following GitLab issue and generate a concrete engineering plan.

Issue Context:
- Title: ${ISSUE_TITLE}
- IID: ${TARGET_ISSUE_IID}
- Project: ${TARGET_PROJECT_PATH}
- URL: ${ISSUE_URL}

Issue Description:
${ORIGINAL_NEEDS}

Your output must be valid JSON with exactly two keys:
1. \"branch\": A kebab-case branch name (e.g., issue-${TARGET_ISSUE_IID}-add-login-feature)
2. \"todo_markdown\": A Markdown checklist with actionable tasks using - [ ] format

Requirements for the plan:
- Break the issue into concrete, testable steps
- Reference specific files/components when applicable
- Include implementation, testing, and documentation tasks
- Keep tasks focused and atomic
- Use clear, imperative language

Example output format:
{
  \"branch\": \"issue-1-implement-feature\",
  \"todo_markdown\": \"- [ ] Create auth module\\n- [ ] Add unit tests\\n- [ ] Update documentation\"
}

Return ONLY the JSON, no additional commentary."

echo "[INFO] Invoking Copilot with prompt (timeout: 3600s)..."
if timeout 3600 copilot -p "$PLAN_PROMPT" > plan_raw.txt 2>&1; then
  echo "[INFO] Copilot execution completed"
  # Clean ANSI escape sequences and carriage returns
  sed -E 's/\x1B\[[0-9;]*[A-Za-z]//g' plan_raw.txt | tr -d '\r' > plan_clean.txt
  mv plan_clean.txt plan_raw.txt
  echo "[INFO] Raw output: $(cat plan_raw.txt)"
else
  EXIT_CODE=$?
  if [ $EXIT_CODE -eq 124 ]; then
    echo "[ERROR] Copilot timed out after 3600 seconds" >&2
  else
    echo "[ERROR] Copilot failed with exit code ${EXIT_CODE}" >&2
  fi
  echo "Raw output: $(cat plan_raw.txt 2>/dev/null || echo 'none')" >&2
  exit 1
fi

echo "[INFO] Parsing Copilot response..."
python3 <<'PY'
import json
import re
from pathlib import Path

raw = Path("plan_raw.txt").read_text(encoding="utf-8").strip()
if raw.startswith("```"):
    raw = re.sub(r"^```[a-zA-Z]*\n", "", raw)
    raw = raw.rsplit("```", 1)[0]

data = json.loads(raw)
branch = data.get("branch", "").strip()
todo = data.get("todo_markdown", "").strip()

if not branch:
    raise SystemExit("Copilot response missing branch")
if not todo:
    raise SystemExit("Copilot response missing todo_markdown")

if not todo.endswith("\n"):
    todo += "\n"
Path("todo.md").write_text(todo, encoding="utf-8")

with open("plan.env", "w", encoding="utf-8") as env_file:
    env_file.write(f"NEW_BRANCH_NAME={branch}\n")
    env_file.write("TODO_FILE=todo.md\n")
PY

echo "[INFO] Plan generated successfully"
echo "  Branch: $(grep NEW_BRANCH_NAME= plan.env | cut -d= -f2)"
echo "  TODO file: todo.md"

