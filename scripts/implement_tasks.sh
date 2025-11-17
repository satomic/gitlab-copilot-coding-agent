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
copilot_login

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
GIT_TERMINAL_PROMPT=0 git clone "${AUTHED_URL}" repo-b >/dev/null
cd repo-b

git fetch origin "${NEW_BRANCH_NAME}" >/dev/null 2>&1 || true
git checkout -B "${NEW_BRANCH_NAME}" "origin/${NEW_BRANCH_NAME}" >/dev/null 2>&1 || git checkout -b "${NEW_BRANCH_NAME}" "${TARGET_BRANCH}" >/dev/null
cp ../todo.md ./todo.md

{
  echo "Act as a coding agent. Repository path: $(pwd). Finish every todo item described below and output a unified diff patch enclosed in triple backticks."
  echo
  cat todo.md
} > ../copilot_prompt.txt

copilot -p "$(cat ../copilot_prompt.txt)" > patch_raw.txt

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
