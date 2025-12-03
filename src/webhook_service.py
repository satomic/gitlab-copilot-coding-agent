"""Lightweight GitLab issue webhook relay.

This Flask-based service listens for issue update events from repository B and
replays the payload into GitLab's pipeline trigger API so that repository A's
CI/CD pipeline can react to real-world issue activity.
"""
from __future__ import annotations

import hashlib
import json
import logging
import os
from datetime import datetime
from pathlib import Path
from typing import Any, Dict

import requests
from flask import Flask, jsonify, request

def _load_env_file(path: str = ".env") -> None:
    """Populate os.environ from a dotenv-style file if present."""
    env_path = Path(path)
    if not env_path.exists():
        return

    for raw_line in env_path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue

        key, sep, value = line.partition("=")
        if not sep:
            continue
        key = key.strip()
        if not key:
            continue
        if key in os.environ:
            continue  # never override an explicitly provided value
        os.environ[key] = value.strip().strip('"').strip("'")


_load_env_file()


def _configure_logging() -> logging.Logger:
    logs_dir = Path("logs")
    logs_dir.mkdir(parents=True, exist_ok=True)

    log_file = logs_dir / f"{datetime.utcnow().strftime('%Y-%m-%d')}.log"
    debug_enabled = os.getenv("LOG_DEBUG", "false").lower() in {"1", "true", "yes", "on"}
    level = logging.DEBUG if debug_enabled else logging.INFO

    formatter = logging.Formatter("%(asctime)s [%(levelname)s] %(name)s: %(message)s")

    root_logger = logging.getLogger()
    root_logger.setLevel(level)
    for handler in list(root_logger.handlers):
        root_logger.removeHandler(handler)

    stream_handler = logging.StreamHandler()
    stream_handler.setFormatter(formatter)
    stream_handler.setLevel(level)

    file_handler = logging.FileHandler(log_file, encoding="utf-8")
    file_handler.setFormatter(formatter)
    file_handler.setLevel(level)

    root_logger.addHandler(stream_handler)
    root_logger.addHandler(file_handler)
    root_logger.debug("Logging configured (level=%s, file=%s)", logging.getLevelName(level), log_file)
    return logging.getLogger(__name__)


app = Flask(__name__)
logger = _configure_logging()


def _sanitize_headers(headers: Any) -> Dict[str, str]:
    sensitive = {"authorization", "x-gitlab-token", "private-token"}
    sanitized: Dict[str, str] = {}
    for key, value in headers.items():
        sanitized[key] = "***" if key.lower() in sensitive else value
    return sanitized


class Settings:
    """Centralized runtime configuration with basic validation."""

    def __init__(self) -> None:
        self.pipeline_trigger_token = self._require("PIPELINE_TRIGGER_TOKEN")
        self.pipeline_project_id = self._require("PIPELINE_PROJECT_ID")
        self.pipeline_ref = os.getenv("PIPELINE_REF", "main")
        self.gitlab_api_base = os.getenv("GITLAB_API_BASE", "https://gitlab.com")
        self.webhook_secret_token = os.getenv("WEBHOOK_SECRET_TOKEN")
        self.default_target_branch = os.getenv("FALLBACK_TARGET_BRANCH", "main")
        self.original_needs_max_chars = int(os.getenv("ORIGINAL_NEEDS_MAX_CHARS", "8192"))
        self.copilot_agent_username = os.getenv("COPILOT_AGENT_USERNAME", "copilot-agent")
        self.copilot_agent_commit_email = os.getenv("COPILOT_AGENT_COMMIT_EMAIL", "copilot@github.com")
        self.enable_inline_review_comments = os.getenv("ENABLE_INLINE_REVIEW_COMMENTS", "true").lower() in {"true", "1", "yes", "on"}

    @staticmethod
    def _require(name: str) -> str:
        value = os.getenv(name)
        if not value:
            raise RuntimeError(f"Environment variable {name} is required")
        return value


settings = Settings()


def _validate_signature() -> bool:
    """Ensure webhook secret (if configured) matches inbound header.
    
    Returns:
        True if validation passes, False otherwise.
    """
    if not settings.webhook_secret_token:
        return True

    header_token = request.headers.get("X-Gitlab-Token")
    if header_token != settings.webhook_secret_token:
        logger.warning("Invalid webhook token received")
        return False
    return True


def _extract_mr_note_variables(payload: Dict[str, Any]) -> Dict[str, str]:
    """Extract variables from MR note event for pipeline.

    Raises:
        ValueError: If required fields are missing or copilot-agent not mentioned.
    """
    note_attrs = payload.get("object_attributes") or {}
    note_text = note_attrs.get("note", "")

    # Check if copilot agent is mentioned
    agent_mention = f"@{settings.copilot_agent_username}"
    if agent_mention not in note_text:
        raise ValueError(f"{agent_mention} not mentioned in note")

    mr = payload.get("merge_request") or {}
    project = payload.get("project") or {}
    user = payload.get("user") or {}

    source_branch = mr.get("source_branch", "")
    target_branch = mr.get("target_branch", "")
    mr_iid = mr.get("iid", "")
    mr_id = mr.get("id", "")

    target_repo_url = (
        project.get("http_url")
        or project.get("git_http_url")
        or ""
    )

    target_project_id = project.get("id") or mr.get("target_project_id")
    target_project_path = project.get("path_with_namespace", "")

    # Extract instruction from note (remove agent mention prefix)
    agent_mention = f"@{settings.copilot_agent_username}"
    instruction = note_text.replace(agent_mention, "").strip()

    variables = {
        "TRIGGER_TYPE": "mr_note",
        "MR_NOTE_INSTRUCTION": instruction,
        "TARGET_REPO_URL": target_repo_url,
        "TARGET_BRANCH": target_branch,
        "SOURCE_BRANCH": source_branch,
        "NEW_BRANCH_NAME": source_branch,  # Work on existing source branch
        "TARGET_PROJECT_ID": str(target_project_id or ""),
        "TARGET_PROJECT_PATH": target_project_path,
        "TARGET_MR_IID": str(mr_iid),
        "TARGET_MR_ID": str(mr_id),
        "MR_TITLE": mr.get("title", ""),
        "MR_URL": mr.get("url", ""),
        "MR_AUTHOR_ID": str(mr.get("author_id", "")),
        "NOTE_AUTHOR_ID": str(user.get("id", "")),
        "NOTE_AUTHOR_USERNAME": user.get("username", ""),
        "COPILOT_AGENT_USERNAME": settings.copilot_agent_username,
        "COPILOT_AGENT_COMMIT_EMAIL": settings.copilot_agent_commit_email,
    }

    missing = [k for k in ("TARGET_REPO_URL", "TARGET_PROJECT_ID", "SOURCE_BRANCH", "TARGET_MR_IID") if not variables.get(k)]
    if missing:
        raise ValueError(f"Missing required MR/project fields: {', '.join(missing)}")

    logger.debug(
        "Extracted MR note vars project_id=%s source_branch=%s target_branch=%s mr_iid=%s",
        variables["TARGET_PROJECT_ID"],
        variables["SOURCE_BRANCH"],
        variables["TARGET_BRANCH"],
        variables["TARGET_MR_IID"],
    )

    return variables


def _extract_mr_reviewer_variables(payload: Dict[str, Any]) -> Dict[str, str]:
    """Extract variables from MR reviewer assignment event for pipeline.

    Raises:
        ValueError: If required fields are missing or copilot-agent not assigned as reviewer.
    """
    mr = payload.get("object_attributes") or {}
    project = payload.get("project") or {}
    user = payload.get("user") or {}
    changes = payload.get("changes") or {}

    action = (mr.get("action") or "").lower()
    allowed_actions = {"open", "reopen", "update", "edited"}
    if action not in allowed_actions:
        logger.debug("Ignoring action '%s' (allowed=%s)", action, allowed_actions)
        raise ValueError(f"Ignoring unsupported MR action '{action}'")

    # Check if Copilot is assigned as reviewer in the changes
    reviewers_change = changes.get("reviewers") or {}
    current_reviewers = reviewers_change.get("current") or []

    is_copilot_reviewer = False
    if current_reviewers and len(current_reviewers) > 0:
        for reviewer in current_reviewers:
            reviewer_username = reviewer.get("username", "")
            if reviewer_username == settings.copilot_agent_username:
                is_copilot_reviewer = True
                logger.info("%s assigned as reviewer detected, will trigger pipeline", settings.copilot_agent_username)
                break

    if not is_copilot_reviewer:
        logger.info("%s not assigned as reviewer in changes, skipping pipeline trigger", settings.copilot_agent_username)
        raise ValueError(f"{settings.copilot_agent_username} not assigned as reviewer, ignoring event")

    source_branch = mr.get("source_branch", "")
    target_branch = mr.get("target_branch", "")
    mr_iid = mr.get("iid", "")
    mr_id = mr.get("id", "")
    mr_title = mr.get("title", "")
    mr_description = mr.get("description", "")

    target_repo_url = (
        project.get("http_url")
        or project.get("git_http_url")
        or ""
    )

    target_project_id = project.get("id") or mr.get("target_project_id")
    target_project_path = project.get("path_with_namespace", "")

    variables = {
        "TRIGGER_TYPE": "mr_reviewer",
        "TARGET_REPO_URL": target_repo_url,
        "TARGET_BRANCH": target_branch,
        "SOURCE_BRANCH": source_branch,
        "TARGET_PROJECT_ID": str(target_project_id or ""),
        "TARGET_PROJECT_PATH": target_project_path,
        "TARGET_MR_IID": str(mr_iid),
        "TARGET_MR_ID": str(mr_id),
        "MR_TITLE": mr_title,
        "MR_DESCRIPTION": mr_description,
        "MR_URL": mr.get("url", ""),
        "MR_AUTHOR_ID": str(mr.get("author_id", "")),
        "MR_ACTION": action,
        "MR_STATE": mr.get("state", ""),
        "REVIEWER_ASSIGNER_ID": str(user.get("id", "")),
        "REVIEWER_ASSIGNER_USERNAME": user.get("username", ""),
        "COPILOT_AGENT_USERNAME": settings.copilot_agent_username,
        "COPILOT_AGENT_COMMIT_EMAIL": settings.copilot_agent_commit_email,
        "ENABLE_INLINE_REVIEW_COMMENTS": "true" if settings.enable_inline_review_comments else "false",
    }

    missing = [k for k in ("TARGET_REPO_URL", "TARGET_PROJECT_ID", "SOURCE_BRANCH", "TARGET_MR_IID") if not variables.get(k)]
    if missing:
        raise ValueError(f"Missing required MR/project fields: {', '.join(missing)}")

    logger.debug(
        "Extracted MR reviewer vars project_id=%s source_branch=%s target_branch=%s mr_iid=%s",
        variables["TARGET_PROJECT_ID"],
        variables["SOURCE_BRANCH"],
        variables["TARGET_BRANCH"],
        variables["TARGET_MR_IID"],
    )

    return variables


def _extract_variables(payload: Dict[str, Any]) -> Dict[str, str]:
    """Project the GitLab issue payload into pipeline variables.
    
    Raises:
        ValueError: If action is not allowed or required fields are missing.
    """
    issue = payload.get("object_attributes") or {}
    project = payload.get("project") or {}
    repository = payload.get("repository") or {}

    action = (issue.get("action") or "").lower()
    allowed_actions = {"open", "reopen", "update", "edited"}
    if action not in allowed_actions:
        logger.debug("Ignoring action '%s' (allowed=%s)", action, allowed_actions)
        raise ValueError(f"Ignoring unsupported issue action '{action}'")

    # Check if Copilot is assigned in the changes
    changes = payload.get("changes") or {}
    assignees_change = changes.get("assignees") or {}
    current_assignees = assignees_change.get("current") or []
    
    is_copilot_assigned = False
    if current_assignees and len(current_assignees) > 0:
        first_assignee_name = current_assignees[0].get("username", "")
        if first_assignee_name == settings.copilot_agent_username:
            is_copilot_assigned = True
            logger.info("%s assigned detected, will trigger pipeline", settings.copilot_agent_username)
        else:
            logger.debug("First assignee is '%s', not '%s'", first_assignee_name, settings.copilot_agent_username)
    
    if not is_copilot_assigned:
        logger.info("%s not assigned in changes, skipping pipeline trigger", settings.copilot_agent_username)
        raise ValueError(f"{settings.copilot_agent_username} not assigned, ignoring event")

    original_needs = issue.get("description") or ""
    if len(original_needs) > settings.original_needs_max_chars:
        suffix = "\n\n<!-- truncated -->"
        original_needs = original_needs[: settings.original_needs_max_chars - len(suffix)] + suffix
        logger.debug("Original needs truncated to %s chars", len(original_needs))

    target_branch = (
        project.get("default_branch")
        or repository.get("default_branch")
        or settings.default_target_branch
    )

    target_repo_url = (
        project.get("http_url")
        or project.get("git_http_url")
        or repository.get("url")
        or repository.get("homepage")
        or ""
    )

    target_project_id = project.get("id") or issue.get("project_id")
    target_project_path = project.get("path_with_namespace") or repository.get("name")

    variables = {
        "TRIGGER_TYPE": "issue_assignee",
        "ORIGINAL_NEEDS": original_needs,
        "TARGET_REPO_URL": target_repo_url,
        "TARGET_BRANCH": target_branch,
        "TARGET_PROJECT_ID": str(target_project_id or ""),
        "TARGET_PROJECT_PATH": target_project_path or "",
        "TARGET_ISSUE_IID": str(issue.get("iid", "")),
        "TARGET_ISSUE_ID": str(issue.get("id", "")),
        "ISSUE_AUTHOR_ID": str(issue.get("author_id", "")),
        "ISSUE_TITLE": issue.get("title", ""),
        "ISSUE_URL": issue.get("url", ""),
        "ISSUE_ACTION": issue.get("action", ""),
        "ISSUE_STATE": issue.get("state", ""),
        "ISSUE_UPDATED_AT": issue.get("updated_at", ""),
        "COPILOT_AGENT_USERNAME": settings.copilot_agent_username,
        "COPILOT_AGENT_COMMIT_EMAIL": settings.copilot_agent_commit_email,
    }

    missing = [k for k in ("TARGET_REPO_URL", "TARGET_PROJECT_ID", "TARGET_ISSUE_IID") if not variables.get(k)]
    if missing:
        raise ValueError(f"Missing required issue/project fields: {', '.join(missing)}")

    logger.debug(
        "Extracted vars action=%s project_id=%s branch=%s repo=%s",
        action,
        variables["TARGET_PROJECT_ID"],
        variables["TARGET_BRANCH"],
        variables["TARGET_REPO_URL"],
    )

    return variables


def _persist_payload(payload: Dict[str, Any]) -> Path:
    """Store the raw webhook payload under hooks/ for later inspection."""
    hooks_dir = Path("hooks")
    hooks_dir.mkdir(parents=True, exist_ok=True)

    timestamp = datetime.utcnow().strftime("%Y%m%dT%H%M%S%fZ")
    digest = hashlib.sha1(json.dumps(payload, sort_keys=True).encode()).hexdigest()[:10]
    hook_path = hooks_dir / f"issue-{timestamp}-{digest}.json"
    hook_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    return hook_path


@app.post("/webhook")
def issue_webhook() -> Any:
    """Handle GitLab issue update events, MR note events, and MR reviewer events, triggering the CI pipeline."""
    # Validate webhook signature
    if not _validate_signature():
        return jsonify({"status": "ignored", "reason": "Invalid webhook token"}), 401

    event_name = request.headers.get("X-Gitlab-Event")
    logger.debug("Incoming headers: %s", _sanitize_headers(request.headers))
    if event_name not in  ["Issue Hook", "Note Hook", "Merge Request Hook"]:
        logger.debug("Ignoring event: %s", event_name)
        return jsonify({"status": "ignored", "reason": "Unsupported event type"}), 202

    payload = request.get_json(silent=True)
    if not payload:
        logger.warning("Received request without JSON payload")
        return jsonify({"status": "error", "reason": "Expected JSON payload"}), 400

    saved_path = _persist_payload(payload)
    logger.info("Persisted webhook payload to %s", saved_path)

    # Determine event type and extract variables
    try:
        if event_name == "Note Hook":
            noteable_type = payload.get("object_attributes", {}).get("noteable_type")
            if noteable_type == "MergeRequest":
                logger.info("Processing MR note event")
                vars_for_pipeline = _extract_mr_note_variables(payload)
            else:
                logger.debug("Ignoring note on %s", noteable_type)
                return jsonify({"status": "ignored", "reason": f"Note on {noteable_type} not supported"}), 202
        elif event_name == "Merge Request Hook":
            logger.info("Processing MR reviewer event")
            vars_for_pipeline = _extract_mr_reviewer_variables(payload)
        else:
            logger.info("Processing issue event")
            vars_for_pipeline = _extract_variables(payload)
    except ValueError as exc:
        logger.info("Skipping event: %s", exc)
        return jsonify({"status": "ignored", "reason": str(exc)}), 202
    
    pipeline_project_id = settings.pipeline_project_id

    trigger_url = f"{settings.gitlab_api_base}/api/v4/projects/{pipeline_project_id}/trigger/pipeline"
    data = {
        "token": settings.pipeline_trigger_token,
        "ref": settings.pipeline_ref,
    }
    for key, value in vars_for_pipeline.items():
        data[f"variables[{key}]"] = value

    logger.debug(
        "Trigger URL=%s ref=%s variable_keys=%s",
        trigger_url,
        settings.pipeline_ref,
        sorted(vars_for_pipeline.keys()),
    )

    logger.info(
        "Triggering pipeline %s (ref=%s) for issue #%s",
        pipeline_project_id,
        settings.pipeline_ref,
        vars_for_pipeline.get("TARGET_ISSUE_IID"),
    )

    # return jsonify({})

    try:
        response = requests.post(trigger_url, data=data, timeout=15)
    except requests.RequestException as exc:  # pragma: no cover - network failure
        logger.exception("Pipeline trigger HTTP request failed")
        return jsonify({
            "status": "error",
            "reason": f"Pipeline trigger request failed: {exc}"
        }), 502

    if response.status_code >= 300:
        logger.error("Pipeline trigger failed: %s", response.text)
        return jsonify({
            "status": "error",
            "reason": response.text or "Failed to trigger pipeline"
        }), response.status_code

    body = response.json()
    return jsonify({
        "status": "queued",
        "pipeline_id": body.get("id"),
        "web_url": body.get("web_url"),
        "ref": body.get("ref"),
    })


def main() -> None:
    host = os.getenv("LISTEN_HOST", "0.0.0.0")
    port = int(os.getenv("LISTEN_PORT", "8080"))
    app.run(host=host, port=port)


if __name__ == "__main__":
    main()
