#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/common.sh"

cd "${REPO_ROOT}"

require_env GITLAB_TOKEN
require_env TARGET_PROJECT_ID
require_env TARGET_ISSUE_IID
require_env NEW_MR_IID

cp repo-b/todo_completed.md ./todo_completed.md

TODO_BODY="$(cat todo_completed.md)"
cat <<EOF > updated_description.txt
## TODO
${TODO_BODY}
EOF

API="${UPSTREAM_GITLAB_BASE_URL}/api/v4/projects/${TARGET_PROJECT_ID}"

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

curl "${CURL_ARGS[@]}" "${API}/merge_requests/${NEW_MR_IID}"

curl --silent --show-error --fail \
  --request POST \
  --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
  --data-urlencode "body=自动化任务完成，最新 TODO 已同步到 MR: ${NEW_MR_URL}" \
  "${API}/issues/${TARGET_ISSUE_IID}/notes"
