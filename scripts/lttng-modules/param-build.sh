#!/bin/sh -exu
#
# Copyright (C) 2016 - Michael Jeanson <mjeanson@efficios.com>
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

SRCDIR="${WORKSPACE}/lttng-modules"
BUILDDIR="${WORKSPACE}/build"
LNXSRCDIR="${WORKSPACE}/linux"
LNXBUILDDIR="${WORKSPACE}/linux-build"

# Create build directory
mkdir -p "${BUILDDIR}" "${LNXBUILDDIR}"

# Enter linux source dir
cd "${LNXSRCDIR}"

# Prepare linux sources for modules OOT build
make O="${LNXBUILDDIR}" defconfig

# Enable CONFIG_KALLSYMS_ALL
sed -i "s/# CONFIG_KALLSYMS_ALL is not set/CONFIG_KALLSYMS_ALL=y/g" "${LNXBUILDDIR}"/.config

# Build to out of tree dir
make O="${LNXBUILDDIR}" modules_prepare

case "$kversion" in
  Ubuntu*)
    #fakeroot debian/rules clean
    #fakeroot debian/rules genconfigs
    #cp CONFIGS/amd64-config.flavour.generic .config

    # Add Ubuntu ABI number to kernel headers, this is normally done by the packaging code
    ABINUM=$(echo $kversion | grep -P -o 'Ubuntu-(lts-)?.*-\K\d+(?=\..*)')
    echo "#define UTS_UBUNTU_RELEASE_ABI $ABINUM" >> ${LNXBUILDDIR}/include/generated/utsrelease.h
    ;;
esac

# Get kernel version from source tree
cd "${LNXBUILDDIR}"
KVERSION=$(make kernelversion)

# Enter source dir
cd "${SRCDIR}"

# kernels 3.10 to 3.10.13 and 3.11 to 3.11.2 introduce a deadlock in the
# timekeeping subsystem. We want those build to fail.
if { vergte "$KVERSION" "3.10" && verlte "$KVERSION" "3.10.13"; } || \
   { vergte "$KVERSION" "3.11" && verlte "$KVERSION" "3.11.2"; }; then

    set +e

    # Build modules
    KERNELDIR="${LNXBUILDDIR}" make -j${NPROC} V=1

    # We expect this build to fail, if it doesn't, fail the job.
    if [ "$?" -eq 0 ]; then
        exit 1
    fi

    # We have to publish at least one file or the build will fail
    echo "This kernel is broken, there is a deadlock in the timekeeping subsystem." > "${BUILDDIR}/BROKEN.txt"

    set -e

else # Regular build

    # Build modules
    KERNELDIR="${LNXBUILDDIR}" make -j${NPROC} V=1

    # Install modules to build dir
    KERNELDIR="${LNXBUILDDIR}" make INSTALL_MOD_PATH="${BUILDDIR}" modules_install
fi

# EOF
