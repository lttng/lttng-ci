#!/bin/bash -x
#
# SPDX-FileCopyrightText: 2024 Kienan Stewart <kstewart@efficios.com
# SPDX-License-Identifier: GPL-2.0-or-later
#

SRC_DIR="${SRC_DIR:-/src/gcc-releases-gcc-4.8.5}"
PATCH_DIR="${PATCH_DIR:-/src/patches}"
BIN_SUFFIX="${BIN_SUFFIX:-4.8}"
IFS=' ' read -r -a TARGETS <<< "${TARGETS:-aarch64-linux-gnu}"
HOST="${HOST:-x86_64-pc-linux-gnu}"
CONFIGURE_ARGS=(${CONFIGURE_ARGS:-})
MAKE_ARGS=(${MAKE_ARGS:-})
MAKE_INSTALL_ARGS=(${MAKE_INSTALL_ARGS:-})
DEBUG="${DEBUG:-}"
CSTD="${CSTD:-gnu99}"
CXXSTD="${CXXSTD:-gnu++98}"

BUILD_DIR="$(pwd)"

cd "${SRC_DIR}" || exit 1
while read -r line ; do
    EXT=$(echo "$line" | rev | cut -d. -f1 | rev)
    PATCH_LEVEL=1
    if [[ "${EXT}" =~ [0-9]+ ]] ; then
        PATCH_LEVEL="${EXT}"
    fi
    patch -p"${PATCH_LEVEL}" < "${line}"
done < <(find "${PATCH_DIR}" -type f | sort)

NPROC="${NPROC:=$(nproc)}"
CFLAGS=(-std="${CSTD}" -w)
CXXFLAGS=(-std="${CXXSTD}" -w)


cd "${SRC_DIR}" || exit 1
mkdir -p "/output/usr/local/gcc${BIN_SUFFIX}"
./contrib/download_prerequisites
PREREQS=(gmp isl mpfr mpc)
for PREREQ in "${PREREQS[@]}" ; do
    cd "${SRC_DIR}/${PREREQ}" || continue
    ARGS=(
        --prefix="/usr/local/gcc${BIN_SUFFIX}"
    )
    case "${PREREQ}" in
        "isl")
            ARG+=(
                --with-gmp-prefix="/usr/local/gcc${BIN_SUFFIX}"
            )
            ;;
        "mpc")
            ARGS+=(
                --with-gmp="/usr/local/gcc${BIN_SUFFIX}"
                --with-mpfr="/usr/local/gcc${BIN_SUFFIX}"
            )
            ;;
        "mpfr")
            ARGS+=(--with-gmp="/usr/local/gcc${BIN_SUFFIX}")
            ;;
    esac
    ./configure "${ARGS[@]}"
    make -j"${NPROC}"
    make install
    cd ..
    rm -rf "${PREREQ}"*
done
cd "${BUILD_DIR}" || exit 1

for TARGET in "${TARGETS[@]}" ; do
    echo "*** Building for target: ${TARGET} ***"
    rm -rf "${BUILD_DIR}"
    mkdir -p "${BUILD_DIR}"
    cd "${BUILD_DIR}" || continue

    TARGET_ARGS=()
    PROGRAM_PREFIX="${TARGET}-"
    case "${TARGET}" in
        aarch64-linux-gnu)
            TARGET_ARGS+=(
                --enable-fix-cortex-a64-84319
            )
            ;;
        arm-linux-gnueabihf)
            TARGET_ARGS+=(
                --with-arch=armv7-a
                --with-float=hard
                --with-fpu=vfpv3-d16
                --with-mode=thumb
            )
            ;;
        i686-linux-gnu)
            TARGET_ARGS+=(
                --with-arch-i686
                --with-tune=generic
            )
            ;;
        powerpc64le-linux-gnu)
            # Disable multilib so that ppc64el kernel can be built, since
            # legacy Makefiles compile vdso in 32bits unconditionally.
            # @see https://bugzilla.redhat.com/show_bug.cgi?id=1237363
            # @see https://bugzilla.redhat.com/show_bug.cgi?id=1205236
            # @see https://bugs.launchpad.net/ubuntu/trusty/+source/linux/+bug/1433809/
            TARGET_ARGS+=(
                --disable-multilib
                --enable-targets=powerpcle-linux
                --with-cpu=power8
                --with-long-double-128
            )
            ;;
        powerpc-linux-gnu)
            TARGET_ARGS+=(
                '--disable-softfloat'
                '--enable-secureplt'
                '--enable-targets=powerpc-linux,powerpc64-linux'
                '--with-cpu=default32'
                '--with-long-double-128'
            )
            ;;
        riscv64-linux-gnu)
            echo "Not supported in gcc-4.8"
            continue
            ;;
        s390x-linux-gnu)
            TARGET_ARGS+=(
                --with-arch=zEC12
                --with-long-double-128
            )
            ;;
        "${HOST}")
            TARGET="${HOST}"
            PROGRAM_PREFIX=''
            ;;
        *)
            echo "Unrecognized target: ${TARGET}"
            continue
            ;;
    esac
    mkdir -p "/output/usr/local/gcc${BIN_SUFFIX}/lib/gcc-cross/${TARGET}" /output/usr/local

    START=$(date +%s)
    "${SRC_DIR}/configure" --build="${HOST}" --host="${HOST}" --enable-languages=c,c++ \
                           --program-prefix="${PROGRAM_PREFIX}" --target="${TARGET}" --program-suffix="-${BIN_SUFFIX}" \
                           --prefix="/usr/local/gcc${BIN_SUFFIX}" --with-system-zlib \
                           --libexecdir="/usr/local/gcc${BIN_SUFFIX}/lib/" \
                           --libdir="/usr/local/gcc${BIN_SUFFIX}/lib/" \
                           --includedir="/usr/local/gcc${BIN_SUFFIX}/${TARGET}/include" \
                           --disable-bootstrap --disable-nls --disable-shared --enable-host-shared \
                           --enable-threads=posix --enable-default-pie --with-sysroot=/ \
                           --without-target-system-zlib --enable-multiarch \
                           --with-isl="/usr/local/gcc${BIN_SUFFIX}" \
                           --with-gmp="/usr/local/gcc${BIN_SUFFIX}" \
                           --with-mpfr="/usr/local/gcc${BIN_SUFFIX}" \
                           --with-mpc="/usr/local/gcc${BIN_SUFFIX}" \
                           "${TARGET_ARGS[@]}" "${CONFIGURE_ARGS[@]}" \
                           CFLAGS="${CFLAGS[*]}" CXXFLAGS="${CXXFLAGS[*]}"

    # This avoids building libgcc and binutils
    # Copy include files from gcc-12 cross prior to build
    mkdir -p "/usr/local/gcc${BIN_SUFFIX}/${TARGET}/lib"
    mkdir -p "/usr/local/gcc${BIN_SUFFIX}/bin/"
    cp -r "/usr/lib/gcc-cross/${TARGET}/12/"* "/usr/local/gcc${BIN_SUFFIX}/${TARGET}/"
    cp -r "/usr/lib/gcc/x86_64-linux-gnu/12/"* "/usr/local/gcc${BIN_SUFFIX}/${TARGET}/lib/"
    cp -r "/usr/${TARGET}/"* "/usr/local/gcc${BIN_SUFFIX}/${TARGET}/"
    # And the binutils binaries
    cp "/usr/bin/${TARGET}-"* "/usr/local/gcc${BIN_SUFFIX}/bin/"

    make -j"${NPROC}" "${MAKE_ARGS[@]}" CFLAGS="${CFLAGS[*]}" CXXFLAGS="${CXXFLAGS[*]}" \
         LD_LIBRARY_PATH="/usr/local/gcc${BIN_SUFFIX}/lib:${LD_LIBRARY_PATH}"
    # Do not use -jN with make install, it often breaks.
    make install "${MAKE_INSTALL_ARGS[@]}" \
         LD_LIBRARY_PATH="/usr/local/gcc${BIN_SUFFIX}/lib:${LD_LIBRARY_PATH}"

    if [ -n "${DEBUG}" ] ; then
        echo $(($(date +%s) - START)) > "/output/${TARGET}.time"
    fi

    cp config.log "/output/config-${TARGET}.log"
done

cp -r "/usr/local/gcc${BIN_SUFFIX}" "/output/usr/local/"

# To test
# 1. Copy the output tarball from the Makefile to a Debian bookworm instance
# 2. Unpack, eg. `tar -xzf gcc55.tar.gz -C /`
# 3. Build a small test program, eg.
#    LD_LIBRARY_PATH=$LD_LIBRARY_PATH:/usr/local/gcc5.5/bin \
#    PATH=$PATH:/usr/local/gcc5.5/bin \
#    aarch64-linux-gnu-gcc-5.5 -o hello hello.c
# 4. Copy the built binary to a system with that native architecture and run it
# 5. Upload to object storage, eg.
#    s3cmd put gcc55.tar.gz s3://jenkins/gcc-5.5-x86_64-linux-gnu-cross.tgz
#
