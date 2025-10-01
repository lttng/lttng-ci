#!/bin/bash
# SPDX-FileCopyrightText: 2021 Jonathan Rajotte <jonathan.rajotte-julien@efficios.com>
# SPDX-FileCopyrightText: 2025 Michael Jeanson <mjeanson@efficios.com>
# SPDX-License-Identifier: GPL-3.0-or-later

set -exu

# shellcheck disable=SC2317
function cleanup
{
    timedatectl set-ntp true
    # The false dates used in the tests are far in the past and it may take
    # some time for the ntp update to actually happen.  If the date is still in
    # the past, it is possible that subsequent steps will fail (eg. TLS
    # certificates cannot be validated).
    while [[ "$(date +%Y)" -lt "2024" ]] ; do
        sleep 1
    done
}
trap cleanup EXIT SIGINT SIGTERM

function test_timeout
{
    local TIMEOUT=0
    local TIMEOUT_MINUTES="${1:-90}"
    shift 1

    "${@}" &
    PID="${!}"

    while true; do
        sleep 1m

        if ! ps -q "${PID}" > /dev/null ; then
            # The process ID doesn't exist anymore
            break
        fi

        TIMEOUT=$((TIMEOUT+1))
        if [[ "${TIMEOUT}" -ge "${TIMEOUT_MINUTES}" ]]; then
            echo "Command '${*}' timed out (${TIMEOUT} minutes) " \
                 "attempting to get backtraces for lttng/babeltrace binaries"

            # Abort all lttng-sessiond, lttng, lttng-relayd, lttng-consumerd,
            # and babeltrace process so there are coredumps available.
            PIDS=$(pgrep 'babeltrace*|[l]ttng*')
            for P in ${PIDS}; do
                OUTFILE=$(mktemp -t "backtrace-${P}.XXXXXX")
                ps -f "${P}" | tee -a "${OUTFILE}"
                gdb -p "${P}" --batch -ex 'thread apply all bt' 2>&1 | tee -a "${OUTFILE}"
                mv "${OUTFILE}" "$COREDUMP_DIR"
            done

            # Send sigterm to make
            kill "${PID}"
        fi
    done

    wait "${PID}"

    return "${?}"
}

export TMPDIR="/tmp"
export COREDUMP_DIR="$TMPDIR/coredump"
export LOG_DIR="$TMPDIR/log"

# Move the home directory to the local disk so we don't run the test suite on NFS
cp -pr /root $TMPDIR/
export HOME=$TMPDIR/root

# Setup coredumps
mkdir -p "$COREDUMP_DIR"
echo "$COREDUMP_DIR/core.%e.%p.%h.%t" > /proc/sys/kernel/core_pattern
ulimit -c unlimited

# Create log directory
mkdir -p "$LOG_DIR"

set +ux
# Active the python venv for vlttng
# shellcheck disable=SC1091
. "$TMPDIR/python-venv/bin/activate"

# Activate the vlttng env
# shellcheck disable=SC1091
. "$TMPDIR/vlttng-venv/activate"
set -ux

# Allow the destructive tests to run
export LTTNG_ENABLE_DESTRUCTIVE_TESTS="will-break-my-system"

# Disable ntp sync, the destructive tests play wih the clock
timedatectl set-ntp false

# Enter the lttng-tools source directory
cd "$TMPDIR/vlttng-venv/src/lttng-tools"

# Build the test suite
lava-test-case build-test-suite --shell make -j "$(nproc)"

# When make check is interrupted, the default test driver
# (`config/test-driver`) will still delete the log and trs
# files for the currently running test.
test_result="pass"
test_timeout 90 make --keep-going check || test_result="fail"
lava-test-case run-test-suite --result $test_result

# Archive the test logs produced by 'make check'
if [ "${test_result}" == "fail" ] ; then
    find tests/ -iname '*.trs' -print0 -or -iname '*.log' -print0 | tar cJf $LOG_DIR/logs.tar.xz --null -T -
fi

# This was removed in stable-2.15
if [ -f "./tests/root_regression" ]; then
    cd "./tests"
    test_result="pass"
    prove --nocolor --verbose --merge --exec '' - < root_regression || test_result="fail"
    lava-test-case run-root-regression --result $test_result
    cd ..
fi

# This was removed in stable-2.14
if [ -f "./tests/root_destructive_tests" ]; then
    cd "./tests"
    test_result="pass"
    prove --nocolor --verbose --merge --exec '' - < root_destructive_tests || test_result="fail"
    lava-test-case run-root-destructive --result $test_result
    cd ..
fi
