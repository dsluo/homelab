#!/usr/bin/env bash
TARGET_SHELL="${1:-$(basename $SHELL)}"
COMPLETIONS_DIR="./.completions/${TARGET_SHELL}"
mkdir -p $COMPLETIONS_DIR

if [[ "$TARGET_SHELL" -eq "fish" ]]; then
    COMPLETION_EXT="fish"
elif [[ "$TARGET_SHELL" -eq "zsh" ]]; then
    COMPLETION_EXT="zsh"
elif [[ "$TARGET_SHELL" -eq "pwsh" ]]; then
    COMPLETION_EXT="ps1"
else
    COMPLETION_EXT="sh"
fi

export MISE_QUIET=true
# this ensures that we only get the tools defined in the local config.
TOOLS=$(mise config get tools | cut -d'"' -f2)

for TOOL in $TOOLS; do
    BINPATH="$(mise bin-paths $TOOL)"

    for ITEM in $BINPATH/*; do

        if [[ -f "$ITEM" && -x "$ITEM" ]]; then
            EXEC_NAME=$(basename $ITEM)
            
            # try to generate completion
            COMPLETION="$($ITEM completion $TARGET_SHELL 2>/dev/null)"
            if [[ "$?" -ne 0 ]]; then

                # try again with --completion; Task does it this way.
                COMPLETION="$($ITEM --completion $TARGET_SHELL 2>/dev/null)"
                if [[ "$?" -ne 0 ]]; then
                    # give up
                    continue
                fi
            fi

            echo "$COMPLETION" > $COMPLETIONS_DIR/$EXEC_NAME.$COMPLETION_EXT
        fi
    done
done
