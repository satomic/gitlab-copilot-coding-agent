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
# Usage: load_prompt <template_name> <variables_as_env_or_args>
load_prompt() {
    local template_name="$1"
    shift

    local lang=$(validate_language "${COPILOT_LANGUAGE}")
    local template_file="${PROMPTS_DIR}/${lang}/${template_name}.txt"

    if [ ! -f "${template_file}" ]; then
        echo "[ERROR] Prompt template '${template_name}' not found for language '${lang}'" >&2
        return 1
    fi

    # Read template content
    local content=$(cat "${template_file}")

    # Replace variables in format {var_name}
    # Variables can be passed as arguments (var=value) or from environment
    for arg in "$@"; do
        if [[ "$arg" =~ ^([^=]+)=(.*)$ ]]; then
            local var_name="${BASH_REMATCH[1]}"
            local var_value="${BASH_REMATCH[2]}"
            # Escape special characters for sed
            var_value=$(echo "$var_value" | sed 's/[&/\]/\\&/g')
            content=$(echo "$content" | sed "s|{${var_name}}|${var_value}|g")
        fi
    done

    # Also replace from environment variables
    # This allows both explicit passing and environment variable usage
    while IFS= read -r line; do
        if [[ "$line" =~ \{([^}]+)\} ]]; then
            local var_name="${BASH_REMATCH[1]}"
            if [ -n "${!var_name:-}" ]; then
                local var_value="${!var_name}"
                # Escape special characters for sed
                var_value=$(echo "$var_value" | sed 's/[&/\]/\\&/g')
                content=$(echo "$content" | sed "s|{${var_name}}|${var_value}|g")
            fi
        fi
    done <<< "$content"

    echo "$content"
}

# Export the function for use in subshells
export -f load_prompt
export -f validate_language
export PROMPTS_DIR
export COPILOT_LANGUAGE
