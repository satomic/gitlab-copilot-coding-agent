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

echo "[INFO] Finalizing automation workflow..."

if [ ! -f repo-b/todo_completed.md ]; then
  echo "[WARN] todo_completed.md not found, using original todo.md"
  cp todo.md ./todo_completed.md
else
  cp repo-b/todo_completed.md ./todo_completed.md
fi

TODO_BODY="$(cat todo_completed.md)"

# Build updated MR description preserving pipeline and issue links
MR_DESC="## TODO
${TODO_BODY}

---
**Original issue:** ${ISSUE_URL:-unknown}"

if [ -n "${CI_PIPELINE_URL:-}" ]; then
  MR_DESC="${MR_DESC}
**Copilot CI Pipeline:** ${CI_PIPELINE_URL}"
fi

cat <<EOF > updated_description.txt
${MR_DESC}
EOF

echo "[INFO] Updating MR ${NEW_MR_IID} description..."
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

echo "[INFO] Finalization completed successfully"
echo "  MR: ${NEW_MR_URL}"
echo "  Issue: ${ISSUE_URL}"

