#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "${0}")/lib/common.sh"

export LOG_LEVEL="debug"
CACHE_COMPLETIONS="false"

TARGET_SHELL="${1:-$(basename $SHELL)}"
REPO_ROOT="$(git rev-parse --show-toplevel)"
COMPLETIONS_DIR="${REPO_ROOT}/.completions/${TARGET_SHELL}"

log debug "Generating $TARGET_SHELL completions to $COMPLETIONS_DIR"

if [[ "$CACHE_COMPLETIONS" != "true" ]]; then
    rm -rf $COMPLETIONS_DIR
fi
mkdir -p $COMPLETIONS_DIR

if [[ "$TARGET_SHELL" == "fish" ]]; then
    COMPLETION_EXT="fish"
elif [[ "$TARGET_SHELL" == "zsh" ]]; then
    COMPLETION_EXT="zsh"
elif [[ "$TARGET_SHELL" == "pwsh" ]]; then
    COMPLETION_EXT="ps1"
else
    COMPLETION_EXT="sh"
fi

if [[ LOG_LEVEL != "debug" ]]; then
    export MISE_QUIET=true
fi
TOOLS=$(
  # this ensures that we only get the tools defined in the local config.
  mise config get tools \
  | yq -ptoml -oj -I0 \
  'to_entries
  | .[]
  | {
    "tool": .key,
    "version": .value.version // .value,
    "completion_flag": .value.completion_flag // "completion",
    "completions": with(select(.value.completions == null); . = true) 
        | with(select(.value.completions != null); . = .value.completions)
  }'
)

# todo: make use of MISE_INSTALLED_TOOLS to only run this for tools that were newly installed.
while read -r TOOL; do
    TOOL_NAME=$(echo "$TOOL" | jq -r '.tool')
    VERSION=$(echo "$TOOL" | jq -r '.version')
    DO_COMPLETIONS=$(echo "$TOOL" | jq -r '.completions')
    COMPLETION_FLAG=$(echo "$TOOL" | jq -r '.completion_flag')

    if [[ "$DO_COMPLETIONS" == "false" ]]; then
        log debug "Skipping $TOOL_NAME $VERSION; disabled"
        continue
    fi

    BINPATH="$(mise bin-paths "$TOOL_NAME")"

    for ITEM in $BINPATH/*; do
        if [[ ! -f "$ITEM" || ! -x "$ITEM" ]]; then
            continue
        fi
        EXEC_NAME=$(basename $ITEM)
        COMPLETION_FILE="$COMPLETIONS_DIR/$EXEC_NAME.$COMPLETION_EXT"

        if [[ -f "$COMPLETION_FILE" && "$CACHE_COMPLETIONS" == "true" ]]; then
            log debug "Skipping $EXEC_NAME v$VERSION; already exists"
            continue
        fi

        log info "Generating completions for $EXEC_NAME v$VERSION"

        if COMPLETION="$($ITEM "$COMPLETION_FLAG" "$TARGET_SHELL")"; then
            echo "$COMPLETION" > "$COMPLETION_FILE"
        else
            log warn "Failed to generate completion for $EXEC_NAME v$VERSION. Maybe disable it?"
        fi
    done
done <<< "$TOOLS"
