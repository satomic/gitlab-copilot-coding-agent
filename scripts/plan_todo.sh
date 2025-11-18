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
echo "[INFO] Contents of plan.json:"
cat plan.json
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
    
    # Delete the JSON file after successful parsing
    plan_file.unlink()
    print("[INFO] plan.json parsed and deleted successfully")
    
except json.JSONDecodeError as e:
    raise SystemExit(f"Invalid JSON in plan.json: {e}")
except Exception as e:
    raise SystemExit(f"Error processing plan.json: {e}")
PY

echo "[INFO] Plan generated successfully"
echo "  Branch: $(grep NEW_BRANCH_NAME= plan.env | cut -d= -f2)"
echo "  TODO file: todo.md"

