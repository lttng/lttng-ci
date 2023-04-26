#!/bin/bash
# SPDX-FileCopyrightText: 2023 Michael Jeanson <mjeanson@efficios.com>
# SPDX-License-Identifier: GPL-2.0-or-later

set -exu

print_header() {
    set +x

    local message=" $1 "
    local message_len
    local padding_len

    message_len="${#message}"
    padding_len=$(( (80 - (message_len)) / 2 ))


    printf '\n'; printf -- '#%.0s' {1..80}; printf '\n'
    printf -- '-%.0s' {1..80}; printf '\n'
    printf -- '#%.0s' $(seq 1 $padding_len); printf '%s' "$message"; printf -- '#%.0s' $(seq 1 $padding_len); printf '\n'
    printf -- '-%.0s' {1..80}; printf '\n'
    printf -- '#%.0s' {1..80}; printf '\n\n'

    set -x
}

cd "src/$PROJECT_NAME"

# Check if the topmost patch is properly formatted
git diff -U0 --no-color --relative HEAD^ | clang-format-diff-14 -p1 -i

# If the tree has local changes, the formatting was incorrect
GIT_DIFF_OUTPUT=$(git diff)
if [ -n "$GIT_DIFF_OUTPUT" ]; then
        print_header "Saving clang-format proposed fixes in clang-format-fixes.diff"
        git diff > "$WORKSPACE/clang-format-fixes.diff"
        exit 1
fi

print_header "clang-format is happy!"
# EOF
