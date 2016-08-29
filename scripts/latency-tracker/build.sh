#!/bin/sh -exu
#
# Copyright (C) 2015 - Jonathan Rajotte-Julien <jonathan.rajotte-julien@efficios.com>
#                      Michael Jeanson <mjeanson@efficios.com>
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

# Kernel version compare functions
verlte() {
    [  "$1" = "`printf '%s\n%s' $1 $2 | sort -V | head -n1`" ]
}

verlt() {
    [ "$1" = "$2" ] && return 1 || verlte $1 $2
}

vergte() {
    [  "$1" = "`printf '%s\n%s' $1 $2 | sort -V | tail -n1`" ]
}

vergt() {
    [ "$1" = "$2" ] && return 1 || vergte $1 $2
}


# Use all CPU cores
NPROC=$(nproc)

SRCDIR="${WORKSPACE}/src/latency-tracker"
BUILDDIR="${WORKSPACE}/build"
LNXSRCDIR="${WORKSPACE}/src/linux"
LNXBINDIR="${WORKSPACE}/deps/linux/build"

# Create build directory
rm -rf "${BUILDDIR}"
mkdir -p "${BUILDDIR}"

# Enter source dir
cd "${SRCDIR}"

# Fix path to linux src in builddir Makefile
sed -i "s#MAKEARGS := -C .*#MAKEARGS := -C ${LNXSRCDIR}#" "${LNXBINDIR}"/Makefile

# Get kernel version from source tree
cd "${LNXBINDIR}"
KVERSION=$(make kernelversion)
cd -

# kernels 3.10 to 3.10.13 and 3.11 to 3.11.2 introduce a deadlock in the
# timekeeping subsystem. We want those build to fail.
if { vergte "$KVERSION" "3.10" && verlte "$KVERSION" "3.10.13"; } || \
   { vergte "$KVERSION" "3.11" && verlte "$KVERSION" "3.11.2"; }; then

    set +e

    # Build modules
    KERNELDIR="${LNXBINDIR}" make -j"${NPROC}" V=1

    # We expect this build to fail, if it doesn't, fail the job.
    if [ "$?" -eq 0 ]; then
        exit 1
    fi

    # We have to publish at least one file or the build will fail
    echo "This kernel is broken, there is a deadlock in the timekeeping subsystem." > "${BUILDDIR}/BROKEN.txt"

    set -e

else # Regular build

    # Build modules
    KERNELDIR="${LNXBINDIR}" make -j"${NPROC}" V=1

    # Install modules to build dir
    KERNELDIR="${LNXBINDIR}" make INSTALL_MOD_PATH="${BUILDDIR}" modules_install
fi

# EOF
