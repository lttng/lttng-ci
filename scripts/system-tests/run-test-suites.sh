#!/bin/bash -xeu
#
# Copyright (C) 2021 - Jonathan Rajotte <jonathan.rajotte-julien@efficios.com>
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

# Version compare functions
vercomp () {
    set +u
    if [[ "$1" == "$2" ]]; then
        return 0
    fi
    local IFS=.
    local i ver1=($1) ver2=($2)
    # fill empty fields in ver1 with zeros
    for ((i=${#ver1[@]}; i<${#ver2[@]}; i++)); do
        ver1[i]=0
    done
    for ((i=0; i<${#ver1[@]}; i++)); do
        if [[ -z ${ver2[i]} ]]; then
            # fill empty fields in ver2 with zeros
            ver2[i]=0
        fi
        if ((10#${ver1[i]} > 10#${ver2[i]})); then
            return 1
        fi
        if ((10#${ver1[i]} < 10#${ver2[i]})); then
            return 2
        fi
    done
    set -u
    return 0
}

verlte() {
    vercomp "$1" "$2"; local res="$?"
    [ "$res" -eq "0" ] || [ "$res" -eq "2" ]
}

verlt() {
    vercomp "$1" "$2"; local res="$?"
    [ "$res" -eq "2" ]
}

vergte() {
    vercomp "$1" "$2"; local res="$?"
    [ "$res" -eq "0" ] || [ "$res" -eq "1" ]
}

vergt() {
    vercomp "$1" "$2"; local res="$?"
    [ "$res" -eq "1" ]
}

verne() {
    vercomp "$1" "$2"; local res="$?"
    [ "$res" -ne "0" ]
}

function cleanup
{
    timedatectl set-ntp true
    # The false dates used in the tests are far in the past
    # and it may take some time for the ntp update to actually
    # happen.
    # If the date is still in the past, it is possible that
    # subsequent steps will fail (eg. TLS certificates cannot
    # be validated).
    while [[ "$(date +%Y)" -lt "2024" ]] ; do
        sleep 1
    done
}

trap cleanup EXIT SIGINT SIGTERM

lttng_version="$1"
failed_tests=0

export LTTNG_ENABLE_DESTRUCTIVE_TESTS="will-break-my-system"
timedatectl set-ntp false

# When make check is interrupted, the default test driver
# (`config/test-driver`) will still delete the log and trs
# files for the currently running test.
#
timeout 90m make --keep-going check || failed_tests=1

if [ -f "./tests/root_regression" ]; then
    cd "./tests" || exit 1
    prove --nocolor --verbose --merge --exec '' - < root_regression || failed_tests=2
    cd ..
fi

# This script doesn't exist in master anymore, but compatibility with old branches
# should be retained until lttng-tools 2.13 is no longer supported
if [ -f "./tests/root_destructive_tests" ]; then
    cd "./tests" || exit 1
    prove --nocolor --verbose --merge --exec '' - < root_destructive_tests || failed_tests=3
    cd ..
else
    echo 'root_destructive_tests not found'
fi

if [[ "${failed_tests}" != "0" ]] ; then
    find tests/ -iname '*.trs' -print0 -or -iname '*.log' -print0 | tar czf /tmp/coredump/logs.tgz --null -T -
fi

exit $failed_tests
