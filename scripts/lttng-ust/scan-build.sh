#!/bin/sh -exu
#
# Copyright (C) 2015 - Jonathan Rajotte-Julien <jonathan.rajotte-julien@efficios.com>
#               2016 - Michael Jeanson <mjeanson@efficios.com>
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


# do not exit immediately if any command fails
set +e

SRCDIR="$WORKSPACE/src/lttng-ust"
TMPDIR="$WORKSPACE/tmp"
PREFIX="$WORKSPACE/build"

# Directory to archive the scan-build report
SCAN_BUILD_ARCHIVE="${WORKSPACE}/scan-build-archive"

# Create build and tmp directories
rm -rf "$PREFIX" "$TMPDIR"
mkdir -p "$PREFIX" "$TMPDIR"

export TMPDIR

# temp directory to store the scan-build report
SCAN_BUILD_TMPDIR=$( mktemp -d )

# liburcu
URCU_INCS="$WORKSPACE/deps/liburcu/build/include/"
URCU_LIBS="$WORKSPACE/deps/liburcu/build/lib/"

export CFLAGS="-O0 -g -DDEBUG"
export CPPFLAGS="-I$URCU_INCS"
export LDFLAGS="-L$URCU_LIBS"
export LD_LIBRARY_PATH="$URCU_LIBS:${LD_LIBRARY_PATH:-}"

# Enter the source directory
cd "$SRCDIR"

# Run bootstrap in the source directory prior to configure
./bootstrap


./configure --prefix=$PREFIX

# generate the scan-build report
scan-build -k -o ${SCAN_BUILD_TMPDIR} make

# get the directory name of the report created by scan-build
SCAN_BUILD_REPORT=$( find ${SCAN_BUILD_TMPDIR} -maxdepth 1 -not -empty -not -name `basename ${SCAN_BUILD_TMPDIR}` )
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
    mv ${SCAN_BUILD_REPORT}/* ${SCAN_BUILD_ARCHIVE}/

    echo ">>> Removing any temporary files and directories"
    rm -rf "${SCAN_BUILD_TMPDIR}"
fi

exit ${rc}
