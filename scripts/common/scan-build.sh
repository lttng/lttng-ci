#!/bin/bash
#
# Copyright (C) 2015 Jonathan Rajotte-Julien <jonathan.rajotte-julien@efficios.com>
# Copyright (C) 2019 Michael Jeanson <mjeanson@efficios.com>
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

# Required variables
WORKSPACE=${WORKSPACE:-}

DEPS_INC="$WORKSPACE/deps/build/include"
DEPS_LIB="$WORKSPACE/deps/build/lib"
DEPS_PKGCONFIG="$DEPS_LIB/pkgconfig"
DEPS_BIN="$WORKSPACE/deps/build/bin"

export PATH="$DEPS_BIN:$PATH"
export LD_LIBRARY_PATH="$DEPS_LIB:${LD_LIBRARY_PATH:-}"
export PKG_CONFIG_PATH="$DEPS_PKGCONFIG"
export CPPFLAGS="-I$DEPS_INC"
export LDFLAGS="-L$DEPS_LIB"

SRCDIR="$WORKSPACE/src/$PROJECT_NAME"
TMPDIR="$WORKSPACE/tmp"

NPROC=$(nproc)
export CFLAGS="-O0 -g"
export CXXFLAGS="-O0 -g"

# Directory to archive the scan-build report
SCAN_BUILD_ARCHIVE="${WORKSPACE}/scan-build-archive"

# Create tmp directory
rm -rf "$TMPDIR"
mkdir -p "$TMPDIR"

export TMPDIR

# Builds configured with '-Werror=missing-include-dirs' if this directory
# doesn't exist
mkdir -p "$DEPS_INC"

# temp directory to store the scan-build report
SCAN_BUILD_TMPDIR=$(mktemp -d)

case "$PROJECT_NAME" in
babeltrace)
    export BABELTRACE_DEV_MODE=1
    export BABELTRACE_DEBUG_MODE=1
    export BABELTRACE_MINIMAL_LOG_LEVEL=TRACE
    CONF_OPTS="--enable-python-bindings --enable-python-bindings-doc --enable-python-plugins"
    BUILD_TYPE="autotools"
    ;;
liburcu)
    CONF_OPTS=""
    BUILD_TYPE="autotools"
    ;;
lttng-modules)
    CONF_OPTS=""
    BUILD_TYPE="autotools"
    ;;
lttng-tools)
    CONF_OPTS=""
    BUILD_TYPE="autotools"
    ;;
lttng-ust)
    CONF_OPTS="--enable-java-agent-all --enable-python-agent"
    BUILD_TYPE="autotools"
    export CLASSPATH="/usr/share/java/log4j-api.jar:/usr/share/java/log4j-core.jar:/usr/share/java/log4j-1.2.jar"
    ;;
*)
    echo "Generic project, no configure options."
    CONF_OPTS=""
    BUILD_TYPE="autotools"
    ;;
esac

if [ -d "$WORKSPACE/src/linux" ]; then
    export KERNELDIR="$WORKSPACE/src/linux"
fi

# Enter the source directory
cd "$SRCDIR"

# Build
case "$BUILD_TYPE" in
autotools)
    # Prepare build dir for autotools based projects
    if [ -f "./bootstrap" ]; then
      ./bootstrap
      ./configure $CONF_OPTS
    fi

    scan-build -k -o "${SCAN_BUILD_TMPDIR}" make -j"$NPROC" V=1
    ;;
*)
    echo "Unsupported build type: $BUILD_TYPE"
    exit 1
    ;;
esac


# get the directory name of the report created by scan-build
SCAN_BUILD_REPORT=$(find "${SCAN_BUILD_TMPDIR}" -maxdepth 1 -not -empty -not -name "$(basename "${SCAN_BUILD_TMPDIR}")")
rc=$?

if [ -z "${SCAN_BUILD_REPORT}" ]; then
    echo ">>> No new bugs identified."
    echo ">>> No scan-build report has been generated"
else
    echo ">>> New scan-build report generated in ${SCAN_BUILD_REPORT}"

    if [ ! -d "${SCAN_BUILD_ARCHIVE}" ]; then
        echo ">>> Creating scan-build archive directory"
        mkdir "${SCAN_BUILD_ARCHIVE}"
    else
        echo ">>> Removing any previous scan-build reports from ${SCAN_BUILD_ARCHIVE}"
        rm -f "${SCAN_BUILD_ARCHIVE}/*"
    fi

    echo ">>> Archiving scan-build report to ${SCAN_BUILD_ARCHIVE}"
    mv "${SCAN_BUILD_REPORT}"/* "${SCAN_BUILD_ARCHIVE}/"

    echo ">>> Removing any temporary files and directories"
    rm -rf "${SCAN_BUILD_TMPDIR}"
fi

exit ${rc}
