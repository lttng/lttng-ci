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

# Parameters
arch=${arch:-}
cross_arch=${cross_arch:-}
ktag=${ktag:-}


## FUNCTIONS ##

# Kernel version compare functions
verlte() {
    [  "$1" = "$(printf '%s\n%s' "$1" "$2" | sort -V | head -n1)" ]
}

verlt() {
    [ "$1" = "$2" ] && return 1 || verlte "$1" "$2"
}

vergte() {
    [  "$1" = "$(printf '%s\n%s' "$1" "$2" | sort -V | tail -n1)" ]
}

vergt() {
    [ "$1" = "$2" ] && return 1 || vergte "$1" "$2"
}


prepare_lnx_sources() {

    outdir=$1

    if [ "$outdir" = "." ]; then
      koutput=""
    else
      koutput="O=${outdir}"
    fi

    # Generate kernel configuration
    case "$ktag" in
      Ubuntu*)
        if [ "${cross_arch}" = "powerpc" ]; then
          if vergte "$KVERSION" "4.10"; then
            echo "Ubuntu removed big endian powerpc configuration from kernel >= 4.10. Don't try to build it."
            exit 0
          fi
        fi
        fakeroot debian/rules clean
        fakeroot debian/rules genconfigs
        cp CONFIGS/"${ubuntu_config}" "${outdir}"/.config
        ;;
      *)
        # Que sera sera
        make "${vanilla_config}" CC="$CC" ${koutput}
        ;;
    esac

    # GCC 4.8
    sed -i "s/CONFIG_CC_STACKPROTECTOR_STRONG=y/# CONFIG_CC_STACKPROTECTOR_STRONG is not set/g" "${outdir}"/.config

    # Don't try to sign modules
    sed -i "s/CONFIG_MODULE_SIG=y/# CONFIG_MODULE_SIG is not set/g" "${outdir}"/.config

    # Disable kernel stack frame correctness validation, introduced in 4.6.0 and currently fails
    sed -i "s/CONFIG_STACK_VALIDATION=y/# CONFIG_STACK_VALIDATION is not set/g" "${outdir}"/.config

    # Set required options
    {
        echo "CONFIG_KPROBES=y";
        echo "CONFIG_FTRACE=y";
        echo "CONFIG_BLK_DEV_IO_TRACE=y";
        echo "CONFIG_TRACEPOINTS=y";
        echo "CONFIG_KALLSYMS_ALL=y";
    } >> "${outdir}"/.config


    make "$oldconf_target" CC="$CC" ${koutput}
    make modules_prepare CC="$CC" ${koutput}

    # Debug
    #cat "${outdir}"/.config

    # On powerpc this object is required to link modules
    if [ "${karch}" = "powerpc" ]; then
        make arch/powerpc/lib/crtsavres.o CC="$CC" ${koutput}
    fi

    # On arm64 this object is required to build with ftrace support
    if [ "${karch}" = "arm64" ]; then
        if vergte "$KVERSION" "4.13-rc1"; then
            make arch/arm64/kernel/ftrace-mod.o CC="$CC" ${koutput}
        fi
    fi

    # Version specific tasks
    case "$ktag" in
      Ubuntu*)
        # Add Ubuntu ABI number to kernel headers, this is normally done by the packaging code
        ABINUM="$(echo "$ktag" | grep -P -o 'Ubuntu-(lts-)?.*-\K\d+(?=\..*)')"
        echo "#define UTS_UBUNTU_RELEASE_ABI $ABINUM" >> "${outdir}"/include/generated/utsrelease.h
        ;;
    esac
}



build_modules() {

    kdir="$1"
    bdir="$2"

    # Enter lttng-modules source dir
    cd "${LTTSRCDIR}"

    # kernels 3.10 to 3.10.13 and 3.11 to 3.11.2 introduce a deadlock in the
    # timekeeping subsystem. We want those build to fail.
    if { vergte "$KVERSION" "3.10" && verlte "$KVERSION" "3.10.13"; } || \
       { vergte "$KVERSION" "3.11" && verlte "$KVERSION" "3.11.2"; }; then

        set +e

        # Build modules
        KERNELDIR="${kdir}" make -j"${NPROC}" V=1 CC="$CC"

        # We expect this build to fail, if it doesn't, fail the job.
        if [ "$?" -eq 0 ]; then
            echo "This build should have failed."
            exit 1
        fi

        # We have to publish at least one file or the build will fail
        echo "This kernel is broken, there is a deadlock in the timekeeping subsystem." > "${bdir}/BROKEN.txt.ko"

        set -e

        KERNELDIR="${kdir}" make clean CC="$CC"

    else # Regular build

        # Build modules against full kernel sources
        KERNELDIR="${kdir}" make -j"${NPROC}" V=1 CC="$CC"

        # Install modules to build dir
        KERNELDIR="${kdir}" make INSTALL_MOD_PATH="${bdir}" modules_install CC="$CC"

        # Clean build dir
        KERNELDIR="${kdir}" make clean CC="$CC"
    fi
}


## MAIN ##

# Use all CPU cores
NPROC=$(nproc)

LTTSRCDIR="${WORKSPACE}/src/lttng-modules"
LNXSRCDIR="${WORKSPACE}/src/linux"

LNXBUILDDIR="${WORKSPACE}/build/linux"
LNXHDRDIR="${WORKSPACE}/build/linux-headers"

LTTBUILDKSRCDIR="${WORKSPACE}/build/lttng-modules-ksrc"
LTTBUILDKHDRDIR="${WORKSPACE}/build/lttng-modules-khdr"


# Setup cross compile env if available
if [ "x${cross_arch}" != "x" ]; then

    case "$cross_arch" in
        "armhf")
            karch="arm"
            cross_compile="arm-linux-gnueabihf-"
            vanilla_config="allyesconfig"
            ubuntu_config="armhf-config.flavour.generic"
            ;;

        "arm64")
            karch="arm64"
            cross_compile="aarch64-linux-gnu-"
            vanilla_config="allyesconfig"
            ubuntu_config="arm64-config.flavour.generic"
            ;;

        "powerpc")
            karch="powerpc"
            cross_compile="powerpc-linux-gnu-"
            vanilla_config="ppc44x_defconfig"
            ubuntu_config="powerpc-config.flavour.powerpc-smp"
            ;;

        "ppc64el")
            karch="powerpc"
            cross_compile="powerpc64le-linux-gnu-"
            vanilla_config="pseries_le_defconfig"
            ubuntu_config="ppc64el-config.flavour.generic"
            ;;

        *)
            echo "Unsupported cross arch $cross_arch"
            exit 1
            ;;
    esac

    # Use gcc 4.9, older kernel don't build with gcc 5
    CC="${cross_compile}gcc-4.9"

    # Export variables used by Kbuild for cross compilation
    export ARCH="${karch}"
    export CROSS_COMPILE="${cross_compile}"

    oldconf_target="olddefconfig"

# Set arch specific values if we are not cross compiling
elif [ "x${arch}" != "x" ]; then

    case "$arch" in
        "x86-32")
            karch="x86"
            vanilla_config="allyesconfig"
            ubuntu_config="i386-config.flavour.generic"
            ;;

        "x86-64")
            karch="x86"
            vanilla_config="allyesconfig"
            ubuntu_config="amd64-config.flavour.generic"
            ;;

        "armhf")
            karch="arm"
            vanilla_config="allyesconfig"
            ubuntu_config="armhf-config.flavour.generic"
            ;;

        "arm64")
            karch="arm64"
            vanilla_config="allyesconfig"
            ubuntu_config="arm64-config.flavour.generic"
            ;;

        "powerpc")
            karch="powerpc"
            vanilla_config="allyesconfig"
            ubuntu_config="powerpc-config.flavour.powerpc-smp"
            ;;

        "ppc64el")
            karch="powerpc"
            vanilla_config="allyesconfig"
            ubuntu_config="ppc64el-config.flavour.generic"
            ;;

        *)
            echo "Unsupported arch $arch"
            exit 1
            ;;
    esac

    # Use gcc 4.9, older kernel don't build with gcc 5
    CC=gcc-4.9

    oldconf_target="silentoldconfig"

else
    echo "Not arch or cross_arch specified"
    exit 1
fi




# Create build directories
mkdir -p "${LNXBUILDDIR}" "${LNXHDRDIR}" "${LTTBUILDKSRCDIR}" "${LTTBUILDKHDRDIR}"



## PREPARE DISTRO STYLE KERNEL HEADERS / DEVEL

# Enter linux source dir
cd "${LNXSRCDIR}"

# Get kernel version from source tree
KVERSION=$(make kernelversion)

prepare_lnx_sources "."

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
(find arch -name include -type d -print0 | \
    xargs -0 -n1 -i: find : -type f) | \
	cpio -pd --preserve-modification-time "${LNXHDRDIR}"

# Copy arch scripts
(find arch -name scripts -type d -print0 | \
    xargs -0 -n1 -i: find : -type f) | \
	cpio -pd --preserve-modification-time "${LNXHDRDIR}"

# Cleanup scripts
rm -f "${LNXHDRDIR}/scripts/*.o"
rm -f "${LNXHDRDIR}/scripts/*/*.o"

# On powerpc this object is required to link modules
if [ "${karch}" = "powerpc" ]; then
    cp -a --parents arch/powerpc/lib/crtsavres.[So] "${LNXHDRDIR}/"
fi

# On arm64 this object is required to build with ftrace support
if [ "${karch}" = "arm64" ]; then
    if vergte "$KVERSION" "4.13-rc1"; then
        cp -a --parents arch/arm64/kernel/ftrace-mod.[So] "${LNXHDRDIR}/"
    fi
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
git clean -xdf

prepare_lnx_sources "${LNXBUILDDIR}"


## BUILD modules

# Build modules against full kernel sources
build_modules "${LNXBUILDDIR}" "${LTTBUILDKSRCDIR}"

# Build modules against kernel headers
build_modules "${LNXHDRDIR}" "${LTTBUILDKHDRDIR}"

# Make sure modules were built
tree "${LTTBUILDKSRCDIR}"
if [ "x$(find "${LTTBUILDKSRCDIR}" -name '*.ko*' -printf yes -quit)" != "xyes" ]; then
  echo "No modules built!"
  exit 1
fi

tree "${LTTBUILDKHDRDIR}"
if [ "x$(find "${LTTBUILDKHDRDIR}" -name '*.ko*' -printf yes -quit)" != "xyes" ]; then
  echo "No modules built!"
  exit 1
fi

# EOF
