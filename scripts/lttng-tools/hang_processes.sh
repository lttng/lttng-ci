#!/bin/bash -exu
#
# Copyright (C) 2018 - Jonathan Rajotte-Julien <jonathan.rajotte-julien@efficios.com>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

PGREP=pgrep
pids=""
dependencies=""
file_list=$(mktemp)
ret=0

# WORKSPACE is normally set by Jenkins.  Use the current directory otherwise,
# like when testing this script manually.
WORKSPACE=${WORKSPACE:-$PWD}

lttng_processes="$("$PGREP" -l 'lttng|gen-ust-.+')" || true
if [ -n "$lttng_processes" ]; then

    pids="$(cut -d ' ' -f 1 <<< "$lttng_processes" | tr '\n' ' ')"
    echo "The following LTTng processes were detected running on the system and will be aborted:"
    echo "$lttng_processes"

    # Stop the processes to make sure everything is frozen
    kill -SIGSTOP $pids

    # Get dependencies for coredump analysis
    # Use /proc/$PID/exe and ldd to get all shared libs necessary
    array=(${pids})
    # Add the /proc/ prefix using parameter expansion
    array=("${array[@]/#/\/proc\/}")
    # Add the /exe suffix using parameter expansion
    array=("${array[@]/%/\/exe}")
    dependencies=$(ldd "${array[@]}" | grep -v "not found")
    dependencies=$(awk '/=>/{print$(NF-1)}' <<< "$dependencies" | sort | uniq)

    kill -SIGABRT $pids
    kill -SIGCONT $pids
    ret=1
fi

core_files=$(find "/tmp" -name "core\.[0-9]*" -type f 2>/dev/null) || true
if [ -n "$core_files" ]; then
    echo "$core_files" >> "$file_list"
    echo "$dependencies" >> "$file_list"

    # Make sure the coredump is finished using fuser
    for core in $core_files; do
        while fuser "$core"; do
            sleep 1
        done
    done

    mkdir -p "${WORKSPACE}/build"
    tar cfzh "${WORKSPACE}/build/core.tar.gz" -T "$file_list"
    rm -f "$core_files"
    ret=1
fi

rm -rf "$file_list"
exit $ret
