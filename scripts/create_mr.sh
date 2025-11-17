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

API="${UPSTREAM_GITLAB_BASE_URL}/api/v4/projects/${TARGET_PROJECT_ID}"

curl --silent --show-error --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
  --data "branch=${NEW_BRANCH_NAME}" \
  --data "ref=${TARGET_BRANCH}" \
  --request POST "${API}/repository/branches" || echo "Branch may already exist"

TODO_BODY="$(cat todo.md)"
cat <<EOF > mr_description.txt
## TODO
${TODO_BODY}
Original issue: ${ISSUE_URL:-unknown}
EOF

MR_TITLE="Auto MR for issue #${TARGET_ISSUE_IID:-unknown}"

curl --silent --show-error --fail \
  --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
  --data-urlencode "source_branch=${NEW_BRANCH_NAME}" \
  --data-urlencode "target_branch=${TARGET_BRANCH}" \
  --data-urlencode "title=${MR_TITLE}" \
  --data-urlencode description@mr_description.txt \
  "${API}/merge_requests" > mr.json

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
