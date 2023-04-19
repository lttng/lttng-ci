#!/bin/bash
#
# SPDX-FileCopyrightText: 2021 Jonathan Rajotte-Julien <jonathan.rajotte-julien@efficios.com>
#
# SPDX-License-Identifier: GPL-2.0-or-later

# Collect the tap logs in a post build step when the build was terminated due
# to timeout.

set -exu

# Required variables
WORKSPACE=${WORKSPACE:-}

SRCDIR="$WORKSPACE/src/lttng-tools"
TAPDIR="$WORKSPACE/tap"
LOGDIR="$WORKSPACE/log"

cd "$SRCDIR"

# Collect all available tap logs
rsync -a --exclude 'test-suite.log' --include '*/' --include '*.log' --exclude='*' tests/ "$TAPDIR" || true

# Collect the test suites top-level log which includes all tests failures
rsync -a --include 'test-suite.log' --include '*/' --exclude='*' tests/ "$LOGDIR" || true

# EOF
