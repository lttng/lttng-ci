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
    kill -SIGABRT $pids
    kill -SIGCONT $pids
    ret=1
fi

# Add the file passed as $1 to the list of files to collect.
#
# If that file is a symlink, follow it and collect the target, recursively.

function collect_recursive
{
    file_to_collect=$1

    if [ -f "$file_to_collect" ]; then
        echo "$file_to_collect" >> "$file_list"

        if [ -L "$file_to_collect" ]; then
            collect_recursive "$(readlink "$file_to_collect")"
        fi
    fi
}

# For each core file...
while read -r core_file; do
    # Make sure the coredump is finished using fuser.
    while fuser "$core_file"; do
        sleep 1
    done

    # Collect everything in the core file that looks like a reference to a
    # shared lib.
    strings "$core_file" | grep '^/.*\.so.*' | while read -r str; do
        collect_recursive "$str"
    done

    echo "$core_file" >> $file_list
    ret=1
done < <(find "/tmp" -maxdepth 1 -name "core\.[0-9]*" -type f 2>/dev/null)

# If we recorded some files to collect, pack them up.
if [ -s "$file_list" ]; then
    mkdir -p "${WORKSPACE}/build"
    tar cfzh "${WORKSPACE}/build/core.tar.gz" -T <(sort "$file_list" | uniq)
fi

# Remove core file
while read -r core_file; do
	rm -rf "$core_file"
done < <(find "/tmp" -maxdepth 1 -name "core\.[0-9]*" -type f 2>/dev/null)

rm -f "$file_list"
exit $ret
