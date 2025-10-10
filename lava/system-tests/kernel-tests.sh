#!/bin/bash
# SPDX-FileCopyrightText: 2021 Jonathan Rajotte <jonathan.rajotte-julien@efficios.com>
# SPDX-FileCopyrightText: 2025 Michael Jeanson <mjeanson@efficios.com>
# SPDX-License-Identifier: GPL-3.0-or-later

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
    local timeout_minutes="${1:-90}"
    shift 1

    local elapsed_minutes=0
    local wait_on_pid
    local pids_to_dump
    local pid
    local outfile

    set +x

    "${@}" &
    wait_on_pid="${!}"

    while true; do
        echo "LAVA: Waiting for timeout of pid: $wait_on_pid ($elapsed_minutes / $timeout_minutes min)"
        sleep 1m

        if ! ps -q "${wait_on_pid}" > /dev/null ; then
            # The process ID doesn't exist anymore
            echo "LAVA: Done waiting, pid ${wait_on_pid} exited"
            break
        fi

        elapsed_minutes=$((elapsed_minutes+1))
        if [[ "${elapsed_minutes}" -ge "${timeout_minutes}" ]]; then
            echo "LAVA: Command '${*}' timed out (${elapsed_minutes} minutes) " \
                 "attempting to get backtraces for lttng/babeltrace binaries"

            set -x
            # Abort all lttng-sessiond, lttng, lttng-relayd, lttng-consumerd,
            # and babeltrace process so there are coredumps available.
            pids_to_dump=$(pgrep 'babeltrace*|[l]ttng*')
            for pid in ${pids_to_dump}; do
                outfile=$(mktemp -t "backtrace-${pid}.XXXXXX")
                ps -f "${pid}" | tee -a "${outfile}"
                gdb -p "${pid}" --batch -ex 'thread apply all bt' 2>&1 | tee -a "${outfile}"
                mv "${outfile}" "$COREDUMP_DIR"
            done

            # Send sigterm to make
            kill "${wait_on_pid}"
        fi
    done

    set -x

    wait "${wait_on_pid}"

    return "${?}"
}

export COREDUMP_DIR="$SCRATCH_DIR/coredump"
export LOG_DIR="$SCRATCH_DIR/log"

# Move the home directory to the local disk so we don't run the test suite on NFS
cp -pr /root "$SCRATCH_DIR/"
export HOME=$SCRATCH_DIR/root

# Setup coredumps
mkdir -p "$COREDUMP_DIR"
echo "$COREDUMP_DIR/core.%e.%p.%h.%t" > /proc/sys/kernel/core_pattern
ulimit -c unlimited

# Create log directory
mkdir -p "$LOG_DIR"

# Set the environment
export PREFIX="$SCRATCH_DIR/opt"
export LD_LIBRARY_PATH="$PREFIX/lib"
export PATH="$PREFIX/bin:$PATH"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"

P3_VERSION=$(python3 -c 'import sys;v = sys.version.split()[0].split("."); print("{}.{}".format(v[0], v[1]))')
export PYTHONPATH="$PREFIX/lib/python$P3_VERSION/site-packages"

# Fail tests with missing optionnal dependencies
export LTTNG_TEST_ABORT_ON_MISSING_PLATFORM_REQUIREMENTS=1

# Allow the destructive tests to run
export LTTNG_ENABLE_DESTRUCTIVE_TESTS="will-break-my-system"

# Disable ntp sync, the destructive tests play wih the clock
timedatectl set-ntp false

# Enter the lttng-tools source directory
cd "$WORKSPACE/src/lttng-tools"

print_header "Run full test suite"

# When make check is interrupted, the default test driver
# (`config/test-driver`) will still delete the log and trs
# files for the currently running test.
test_result="pass"
test_timeout 90 make --keep-going check || test_result="fail"
lava-test-case run-test-suite --result $test_result

# Archive the test logs produced by 'make check'
if [ "${test_result}" == "fail" ] ; then
    # Fetch the kernel/system log
    journalctl > tests/system.log

    find tests/ -iname '*.trs' -print0 -or -iname '*.log' -print0 | tar cJf "$LOG_DIR/logs.tar.xz" --null -T -
fi

# This was removed in stable-2.15
if [ -f "./tests/root_regression" ]; then
    print_header "Run root_regression tests"
    cd "./tests"
    test_result="pass"
    prove --nocolor --verbose --merge --exec '' - < root_regression || test_result="fail"
    lava-test-case run-root-regression --result $test_result
    cd ..
fi

# This was removed in stable-2.14
if [ -f "./tests/root_destructive_tests" ]; then
    print_header "Run root_destructive tests"
    cd "./tests"
    test_result="pass"
    prove --nocolor --verbose --merge --exec '' - < root_destructive_tests || test_result="fail"
    lava-test-case run-root-destructive --result $test_result
    cd ..
fi
