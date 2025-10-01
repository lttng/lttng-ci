#!/bin/bash
# SPDX-FileCopyrightText: 2025 Michael Jeanson <mjeanson@efficios.com>
# SPDX-License-Identifier: GPL-3.0-or-later

set -exu

export PREFIX="$SCRATCH_DIR/opt"
export DESTDIR=/

mkdir "$WORKSPACE"

# Get the sources
git clone --quiet "$URCU_REPO" "$WORKSPACE/src/liburcu"
git -C "$WORKSPACE/src/liburcu" checkout "$URCU_BRANCH"

git clone --quiet "$BT_REPO" "$WORKSPACE/src/babeltrace"
git -C "$WORKSPACE/src/babeltrace" checkout "$BT_BRANCH"

git clone --quiet "$UST_REPO" "$WORKSPACE/src/lttng-ust"
git -C "$WORKSPACE/src/lttng-ust" checkout "$UST_COMMIT"

git clone --quiet "$TOOLS_REPO" "$WORKSPACE/src/lttng-tools"
git -C "$WORKSPACE/src/lttng-tools" checkout "$TOOLS_COMMIT"

export conf="system-tests"
export java_preferred_jdk="default"

# Configure the liburcu build
export USERSPACE_RCU_MAKE_CLEAN=no
export USERSPACE_RCU_RUN_TESTS=no

scripts/liburcu/build.sh

# Configure the babeltrace build
export BABELTRACE_MAKE_CLEAN=no
export BABELTRACE_RUN_TESTS=no

scripts/babeltrace/build.sh

# Set the environment
export LD_LIBRARY_PATH="$PREFIX/lib"
export PATH="$PREFIX/bin:$PATH"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
export JAVA_PATH="$PREFIX/share/java"

P3_VERSION=$(python3 -c 'import sys;v = sys.version.split()[0].split("."); print("{}.{}".format(v[0], v[1]))')
export PYTHONPATH="$PREFIX/lib/python$P3_VERSION/site-packages"

# Configure the lttng-ust build
export LTTNG_UST_MAKE_CLEAN=no
export LTTNG_UST_RUN_TESTS=no

scripts/lttng-ust/build.sh

# Configure the lttng-tools build
export LTTNG_TOOLS_MAKE_INSTALL=no
export LTTNG_TOOLS_MAKE_CLEAN=no
export LTTNG_TOOLS_RUN_TESTS=no

scripts/lttng-tools/build.sh
