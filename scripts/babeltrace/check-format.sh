#!/bin/bash
# SPDX-FileCopyrightText: 2023 Michael Jeanson <mjeanson@efficios.com>
# SPDX-License-Identifier: GPL-2.0-or-later

set -exu

cd src/babeltrace

# Check if the topmost patch is properly formatted
git diff -U0 --no-color --relative HEAD^ | clang-format-diff-14 -p1 -i

GIT_DIFF_OUTPUT=$(git diff)

if [ -n "$GIT_DIFF_OUTPUT" ]; then
        echo "$GIT_DIFF_OUTPUT"
        exit 1
fi

# EOF
