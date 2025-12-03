#!/usr/bin/env bash
# Prompt loader utility for i18n support
# Usage: source scripts/load_prompt.sh && load_prompt <template_name> [var1=val1 var2=val2 ...]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROMPTS_DIR="${SCRIPT_DIR}/../prompts"

# Get language from environment variable, default to English
COPILOT_LANGUAGE="${COPILOT_LANGUAGE:-en}"

# Validate language code
validate_language() {
    local lang="$1"
    if [ ! -d "${PROMPTS_DIR}/${lang}" ]; then
        echo "[WARN] Language '${lang}' not found, falling back to English" >&2
        echo "en"
    else
        echo "${lang}"
    fi
}

# Load a prompt template and replace variables
# Usage: load_prompt <template_name> <variables_as_args>
load_prompt() {
    local template_name="$1"
    shift

    local lang=$(validate_language "${COPILOT_LANGUAGE}")
    local template_file="${PROMPTS_DIR}/${lang}/${template_name}.txt"

    if [ ! -f "${template_file}" ]; then
        echo "[ERROR] Prompt template '${template_name}' not found for language '${lang}'" >&2
        return 1
    fi

    # Convert Git Bash path to Windows path for Python (if on Windows)
    local python_template_file="${template_file}"
    if [[ "${template_file}" =~ ^/([a-z])/ ]]; then
        # Convert /c/path to C:/path for Python
        python_template_file=$(echo "${template_file}" | sed -E 's|^/([a-z])/|\U\1:/|')
    fi

    # Export all variable arguments as environment variables for Python
    for arg in "$@"; do
        if [[ "$arg" =~ ^([^=]+)=(.*)$ ]]; then
            export "PROMPT_VAR_${BASH_REMATCH[1]}=${BASH_REMATCH[2]}"
        fi
    done

    # Use Python for safe variable replacement
    python3 -c '
import sys
import os
import io

# Ensure stdout uses UTF-8 encoding
if sys.platform == "win32":
    sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8")

# Read template
with open(r"'"${python_template_file}"'", "r", encoding="utf-8") as f:
    content = f.read()

# Get all PROMPT_VAR_ environment variables
for key, value in os.environ.items():
    if key.startswith("PROMPT_VAR_"):
        var_name = key[11:].lower()  # Remove PROMPT_VAR_ prefix and convert to lowercase
        placeholder = "{" + var_name + "}"
        content = content.replace(placeholder, value)

print(content, end="")
'

    # Clean up exported variables
    for arg in "$@"; do
        if [[ "$arg" =~ ^([^=]+)=(.*)$ ]]; then
            unset "PROMPT_VAR_${BASH_REMATCH[1]}"
        fi
    done
}

# Export the function for use in subshells
export -f load_prompt
export -f validate_language
export PROMPTS_DIR
export COPILOT_LANGUAGE
