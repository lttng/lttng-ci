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

## FUNCTIONS ##

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


build_modules() {

    kdir="$1"
    bdir="$2"

    # Get kernel version from source tree
    cd "${kdir}"
    kversion=$(make kernelversion)

    # Enter lttng-modules source dir
    cd "${LTTSRCDIR}"

    # kernels 3.10 to 3.10.13 and 3.11 to 3.11.2 introduce a deadlock in the
    # timekeeping subsystem. We want those build to fail.
    if { vergte "$kversion" "3.10" && verlte "$kversion" "3.10.13"; } || \
       { vergte "$kversion" "3.11" && verlte "$kversion" "3.11.2"; }; then

        set +e

        # Build modules
        KERNELDIR="${kdir}" make -j${NPROC} V=1

        # We expect this build to fail, if it doesn't, fail the job.
        if [ "$?" -eq 0 ]; then
            exit 1
        fi

        # We have to publish at least one file or the build will fail
        echo "This kernel is broken, there is a deadlock in the timekeeping subsystem." > "${bdir}/BROKEN.txt"

        set -e

    else # Regular build

        # Build modules against full kernel sources
        KERNELDIR="${kdir}" make -j${NPROC} V=1

        # Install modules to build dir
        KERNELDIR="${kdir}" make INSTALL_MOD_PATH="${bdir}" modules_install

        # Clean build dir
        KERNELDIR="${kdir}" make clean
    fi
}


## MAIN ##

# Use all CPU cores
NPROC=$(nproc)

LTTSRCDIR="${WORKSPACE}/src/lttng-modules"
LNXSRCDIR="${WORKSPACE}/src/linux"

LNXBUILDDIR="${WORKSPACE}/build/linux"
LNXHDRDIR="${WORKSPACE}/build/linux-headers"

LTTBUILKSRCDDIR="${WORKSPACE}/build/lttng-modules-ksrc"
LTTBUILDKHDRDIR="${WORKSPACE}/build/lttng-modules-khdr"


# Set arch specific values
case "$arch" in
    "x86-32")
        karch="x86"
        cross_compile=""
        ;;

    "x86-64")
        karch="x86"
        cross_compile=""
        ;;

    "armhf")
        karch="arm"
        cross_compile="arm-linux-gnueabihf-"
        ;;

    "arm64")
        karch="arm64"
        cross_compile="aarch64-linux-gnu-"
        ;;

    "powerpc")
        karch="powerpc"
        cross_compile="powerpc-linux-gnu-"
        ;;

    "ppc64el")
        karch="powerpc"
        cross_compile="powerpc64le-linux-gnu-"
        ;;

    *)
        echo "Unsupported arch $arch"
        exit 1
        ;;
esac

# Setup cross compile env if required
if [ "${cross_build:-}" = "true" ]; then
    export ARCH="${karch}"
    export CROSS_COMPILE="${cross_compile}"
fi


# Create build directories
mkdir -p "${LNXBUILDDIR}" "${LNXHDRDIR}"


## PREPARE DISTRO STYLE KERNEL HEADERS / DEVEL

# Enter linux source dir
cd "${LNXSRCDIR}"

# Prepare linux sources for headers install
make allyesconfig
sed -i "s/CONFIG_MODULE_SIG=y/# CONFIG_MODULE_SIG is not set/g" .config
make silentoldconfig
make modules_prepare

# Version specific tasks
case "$kversion" in
  Ubuntu*)
    # Add Ubuntu ABI number to kernel headers, this is normally done by the packaging code
    ABINUM=$(echo $kversion | grep -P -o 'Ubuntu-(lts-)?.*-\K\d+(?=\..*)')
    echo "#define UTS_UBUNTU_RELEASE_ABI $ABINUM" >> include/generated/utsrelease.h
    ;;
esac

# For RT kernels, copy version file
if [ -s localversion-rt ]; then
    cp -a localversion-rt "${LNXHDRDIR}"
fi

# Copy all Makefile related stuff
find . -path './include/*' -prune \
    -o -path './scripts/*' -prune -o -type f \
	\( -name 'Makefile*' -o -name 'Kconfig*' -o -name 'Kbuild*' -o \
        -name '*.sh' -o -name '*.pl' -o -name '*.lds' \) \
    -print | cpio -pd --preserve-modification-time "${LNXHDRDIR}"

# Copy base scripts and include dirs
cp -a scripts include "${LNXHDRDIR}"

# Copy arch includes
(find arch -name include -type d -print | \
    xargs -n1 -i: find : -type f) | \
	cpio -pd --preserve-modification-time "${LNXHDRDIR}"

# Copy arch scripts
(find arch -name scripts -type d -print | \
    xargs -n1 -i: find : -type f) | \
	cpio -pd --preserve-modification-time "${LNXHDRDIR}"

# Cleanup scripts
rm -f "${LNXHDRDIR}/scripts/*.o"
rm -f "${LNXHDRDIR}/scripts/*/*.o"

# On powerpc this object is required to link modules
if [ "${karch}" = "powerpc" ]; then
    make arch/powerpc/lib/crtsavres.o
    cp -a --parents arch/powerpc/lib/crtsavres.[So] "${LNXHDRDIR}/"
fi

# Copy modules related stuff, if available
if [ -s Module.symvers ]; then
    cp Module.symvers "${LNXHDRDIR}"
fi

if [ -s System.map ]; then
    cp System.map "${LNXHDRDIR}"
fi

if [ -s Module.markers ]; then
    cp Module.markers "${LNXHDRDIR}"
fi

# Copy config file
cp .config "${LNXHDRDIR}"

# Make sure the Makefile and version.h have a matching timestamp so that
# external modules can be built
if [ -s "${LNXHDRDIR}/include/generated/uapi/linux/version.h" ]; then
    touch -r "${LNXHDRDIR}/Makefile" "${LNXHDRDIR}/include/generated/uapi/linux/version.h"
elif [ -s "${LNXHDRDIR}/include/linux/version.h" ]; then
    touch -r "${LNXHDRDIR}/Makefile" "${LNXHDRDIR}/include/linux/version.h"
else
    echo "Missing version.h"
    exit 1
fi
touch -r "${LNXHDRDIR}/.config" "${LNXHDRDIR}/include/generated/autoconf.h"

# Copy .config to include/config/auto.conf so "make prepare" is unnecessary.
cp "${LNXHDRDIR}/.config" "${LNXHDRDIR}/include/config/auto.conf"




## PREPARE FULL LINUX SOURCE TREE

# Enter linux source dir
cd "${LNXSRCDIR}"

# Make sure linux source dir is clean
make mrproper

# Prepare linux sources for modules OOT build
make O="${LNXBUILDDIR}" allyesconfig
sed -i "s/CONFIG_MODULE_SIG=y/# CONFIG_MODULE_SIG is not set/g" "${LNXBUILDDIR}"/.config
make O="${LNXBUILDDIR}" silentoldconfig
make O="${LNXBUILDDIR}" modules_prepare

# On powerpc this object is required to link modules
if [ "${karch}" = "powerpc" ]; then
    make O="${LNXBUILDDIR}" arch/powerpc/lib/crtsavres.o
fi

# Version specific tasks
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

# Build modules against full kernel sources
build_modules "${LNXBUILDDIR}" "${LTTBUILKSRCDDIR}"

# Build modules against kernel headers
build_modules "${LNXHDRDIR}" "${LTTBUILDKHDRDIR}"

# Make sure modules were built
find "${LNXBUILDDIR}" -name "*.ko"
find "${LNXHDRDIR}" -name "*.ko"

# EOF
