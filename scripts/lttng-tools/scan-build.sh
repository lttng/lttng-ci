#!/bin/sh -exu
#
# Copyright (C) 2015 - Jonathan Rajotte-Julien <jonathan.rajotte-julien@efficios.com>
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


# temp directory to store the scan-build report
SCAN_BUILD_TMPDIR=$( mktemp -d /tmp/scan-build.XXXXXX )
 
# directory to use for archiving the scan-build report
SCAN_BUILD_ARCHIVE="${WORKSPACE}/scan-build-archive"

# Create build directory
rm -rf $WORKSPACE/build
mkdir -p $WORKSPACE/build

# liburcu
URCU_INCS="$WORKSPACE/deps/liburcu/build/include/"
URCU_LIBS="$WORKSPACE/deps/liburcu/build/lib/"

# lttng-ust
UST_INCS="$WORKSPACE/deps/lttng-ust/build/include/"
UST_LIBS="$WORKSPACE/deps/lttng-ust/build/lib/"

export CFLAGS="-O0 -g -DDEBUG"
export CPPFLAGS="-I$URCU_INCS -I$UST_INCS"
export LDFLAGS="-L$URCU_LIBS -L$UST_LIBS"
export LD_LIBRARY_PATH="$URCU_LIBS:$UST_LIBS:${LD_LIBRARY_PATH:-}"

PREFIX="$WORKSPACE/build"

./bootstrap
./configure --prefix=$PREFIX
make clean
# generate the scan-build report
scan-build -k -o ${SCAN_BUILD_TMPDIR} make
 
# get the directory name of the report created by scan-build
set +e
SCAN_BUILD_REPORT=$( find ${SCAN_BUILD_TMPDIR} -maxdepth 1 -not -empty -not -name `basename ${SCAN_BUILD_TMPDIR}` )
rc=$?
set -e
 
if [ -z "${SCAN_BUILD_REPORT}" ]; then
    echo ">>> No new bugs identified."
    echo ">>> No scan-build report has been generated"
else
    echo ">>> New scan-build report generated in ${SCAN_BUILD_REPORT}"
 
    if [ ! -d "${SCAN_BUILD_ARCHIVE}" ]; then
        echo ">>> Creating scan-build archive directory"
        install -d -o jenkins -g jenkins -m 0755 "${SCAN_BUILD_ARCHIVE}"
    else
        echo ">>> Removing any previous scan-build reports from ${SCAN_BUILD_ARCHIVE}"
        rm -f ${SCAN_BUILD_ARCHIVE}/*
    fi
 
    echo ">>> Archiving scan-build report to ${SCAN_BUILD_ARCHIVE}"
    mv ${SCAN_BUILD_REPORT}/* ${SCAN_BUILD_ARCHIVE}/
 
    echo ">>> Removing any temporary files and directories"
    rm -rf "${SCAN_BUILD_TMPDIR}"
fi
 
exit ${rc}
