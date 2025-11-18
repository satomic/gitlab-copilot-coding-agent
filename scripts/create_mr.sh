#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/common.sh"

cd "${REPO_ROOT}"

require_env GITLAB_TOKEN
require_env TARGET_PROJECT_ID
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

# Build MR description with pipeline link
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

echo "[INFO] Merge request created successfully"
echo "  MR IID: $(grep NEW_MR_IID= mr.env | cut -d= -f2)"
echo "  MR URL: $(grep NEW_MR_URL= mr.env | cut -d= -f2)"

