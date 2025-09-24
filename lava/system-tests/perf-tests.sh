#!/bin/bash
# SPDX-FileCopyrightText: 2021 Jonathan Rajotte <jonathan.rajotte-julien@efficios.com>
# SPDX-FileCopyrightText: 2025 Michael Jeanson <mjeanson@efficios.com>
# SPDX-License-Identifier: GPL-3.0-or-later

set -exu

# Move the home directory to the local disk so we don't run the test suite on NFS
cp -pr /root /tmp/
export HOME=/tmp/root

export TMPDIR="/tmp"

# Setup coredumps
mkdir -p /tmp/coredump
echo "/tmp/coredump/core.%e.%p.%h.%t" > /proc/sys/kernel/core_pattern
ulimit -c unlimited

set +ux
# Active the python venv for vlttng
# shellcheck disable=SC1091
source /tmp/python-venv/bin/activate

# Activate the vlttng env
# shellcheck disable=SC1091
source /tmp/vlttng-venv/activate
set -ux

# Enter the lttng-tools source directory
cd /tmp/vlttng-venv/src/lttng-tools

# Enter the lttng-tools source directory
lava-test-case build-test-suite --shell make -j "$(nproc)"

# Need to check if the file is present for branches where the testcase was not backported
if [ -f "./tests/perf_regression" ]; then
    cd "./tests"
    test_result="pass"
    prove --nocolor --verbose --merge --exec '' - < perf_regression || test_result="fail"
    lava-test-case run-perf-regression --result $test_result
fi
