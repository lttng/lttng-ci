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

export COREDUMP_DIR="$SCRATCH_DIR/coredump"
export LOG_DIR="$SCRATCH_DIR/log"

# Move the home directory to the local disk so we don't run the test suite on NFS
cp -pr /root "$SCRATCH_DIR/"
export HOME="$SCRATCH_DIR/root"

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

# Enter the lttng-tools source directory
cd "$WORKSPACE/src/lttng-tools"

print_header "Run perf regression test"

# Need to check if the file is present for branches where the testcase was not backported
if [ -f "./tests/perf_regression" ]; then
    cd "./tests"
    test_result="pass"
    prove --nocolor --verbose --merge --exec '' - < perf_regression || test_result="fail"
    lava-test-case run-perf-regression --result $test_result
else
    test_result="pass"
    make -C tests/perf --keep-going check || test_result="fail"
    lava-test-case run-perf-regression --result $test_result

    # Archive the test logs produced by 'make check'
    if [ "${test_result}" == "fail" ] ; then
        find tests/ -iname '*.trs' -print0 -or -iname '*.log' -print0 | tar cJf "$LOG_DIR/logs.tar.xz" --null -T -
    fi
fi
