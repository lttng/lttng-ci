#!/bin/bash
#
# SPDX-FileCopyrightText: 2018 Jonathan Rajotte-Julien <jonathan.rajotte-julien@efficios.com>
#
# SPDX-License-Identifier: GPL-2.0-or-later

set -exu

pids=()

# Kill any LTTng-related process
lttng_processes="$(pgrep -l 'lttng|gen-ust-.+')" || true
if [ -n "$lttng_processes" ]; then
    echo "The following LTTng processes were detected running on the system and will be killed:"
    echo "$lttng_processes"

    # Build the pids array
    while read -r pid; do
        pids+=("$pid")
    done < <(cut -d ' ' -f 1 <<< "$lttng_processes")

    kill -SIGKILL "${pids[@]}"
fi

# Remove any coredump already present
find "/tmp" -name "core\.[0-9]*" -type f -delete || true
