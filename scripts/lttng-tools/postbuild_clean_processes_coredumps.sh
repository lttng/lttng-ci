#!/bin/bash
#
# SPDX-FileCopyrightText: 2018 Jonathan Rajotte-Julien <jonathan.rajotte-julien@efficios.com>
#
# SPDX-License-Identifier: GPL-2.0-or-later

set -exu

# Add the file passed as $1 to the list of files to collect.
#
# If that file is a symlink, follow it and collect the target, recursively.
function collect_recursive
{
    file_to_collect=$1

    if [ -f "$file_to_collect" ]; then
        echo "Collecting '${file_to_collect}'"
        echo "$file_to_collect" >> "$file_list"

        if [ -L "$file_to_collect" ]; then
            collect_recursive "$(readlink "$file_to_collect")"
        fi
    fi
}

pids=()
file_list=$(mktemp -t "postbuild_file_list.XXXXXX")
ret=0

# WORKSPACE is normally set by Jenkins.  Use the current directory otherwise,
# like when testing this script manually.
WORKSPACE=${WORKSPACE:-$PWD}

lttng_processes="$(pgrep -l 'lttng|gen-ust-.+')" || true
if [ -n "$lttng_processes" ]; then

    echo "The following LTTng processes were detected running on the system and will be aborted:"
    echo "$lttng_processes"

    # Build the pids array
    while read -r pid; do
        pids+=("$pid")
    done < <(cut -d ' ' -f 1 <<< "$lttng_processes")

    # Abort the leftover processes to generate core files
    kill -SIGSTOP "${pids[@]}"
    kill -SIGABRT "${pids[@]}"
    kill -SIGCONT "${pids[@]}"

    # Exit with failure when leftover processes are found
    ret=1
fi

# For each core file...
while read -r core_file; do
    sleep_count=0

    # Make sure the coredump is finished using fuser
    while fuser "$core_file"; do
        sleep 1
        sleep_count+=1

        # Skip the core file if it takes more than 30 seconds
        if [ "$sleep_count" -ge 30 ]; then
            continue
        fi
    done

    # Print a full backtrace of all threads
    if command -v gdb >/dev/null 2>&1; then
        gdb -nh -c "$core_file" -ex "thread apply all bt full" -ex q
    fi

    # Collect everything in the core file that looks like a reference to a
    # shared lib
    set +x
    strings "$core_file" | while read -r str; do
        if [[ "${str}" =~ ^/.*\.so.* ]]; then
            collect_recursive "${str}"
        fi
        if [[ -f "${str}" ]] && [[ -x "${str}" ]]; then
            collect_recursive "${str}"
        fi
    done
    set -x

    echo "$core_file" >> "$file_list"
    # Exit with failure when core files are found
    ret=1
done < <(find "/tmp" -maxdepth 1 -name "core\.[0-9]*" -type f 2>/dev/null)

# If we recorded some files to collect, pack them up.
if [ -s "$file_list" ]; then
    mkdir -p "${WORKSPACE}/"
    tar cJfh "${WORKSPACE}/core.tar.xz" -T <(sort "$file_list" | uniq)
fi

# Remove core files
find "/tmp" -maxdepth 1 -name "core\.[0-9]*" -type f -delete || true

rm -f "$file_list"

exit $ret
