#!/bin/bash
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

set -exu

PGREP=pgrep
# Kill any LTTng-related process
lttng_processes="$("$PGREP" -l 'lttng|gen-ust-.+')" || true
if [ ! -z "$lttng_processes" ]; then
    echo "The following LTTng processes were detected running on the system and will be killed:"
    echo "$lttng_processes"

    pids="$(cut -d ' ' -f 1 <<< "$lttng_processes" | tr '\n' ' ')"
    kill -SIGKILL $pids
fi

# Remove any coredump already present
core_files=$(find "/tmp" -name "core\.[0-9]*" -type f 2>/dev/null) || true
if [ ! -z "$core_files" ]; then
    rm -rf $core_files
fi
