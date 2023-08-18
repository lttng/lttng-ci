#!/bin/bash -x

SRC_DIR="${SRC_DIR:-/src/gcc-releases-gcc-4.8.5}"
PATCH_DIR="${PATCH_DIR:-/src/patches}"
TARGET="${TARGET:-aarch64-linux-gnu}"
HOST="${HOST:-x86_64-linux-gnu}"
CONFIGURE_ARGS="${CONFIGURE_ARGS:-}"
MAKE_ARGS="${MAKE_ARGS:-}"
MAKE_INSTALL_ARGS="${MAKE_INSTALL_ARGS:-}"

OWD="$(pwd)"
cd "${SRC_DIR}" || exit 1
while read -r line ; do
    EXT=$(echo "$line" | rev | cut -d. -f1 | rev)
    PATCH_LEVEL=1
    if [[ "${EXT}" =~ [0-9]+ ]] ; then
        PATCH_LEVEL="${EXT}"
    fi
    patch -p"${PATCH_LEVEL}" < "${line}"
done < <(find "${PATCH_DIR}" -type f)
cd "${OWD}"

TARGET_ARGS=()
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
        TARGET_ARGS+=(
            --enable-secureplt
            --enable-targets=powerpcle-linux
            --with-cpu=power8
            --with-long-double-128
        )
        ;;
    powerpc-linux-gnu)
        TARGET_ARGS+=(
            --disable-softfloat
            --enable-secureplt
            --enable-targets=powerpc-linux,powerpc64-linux
            --with-cpu=default32
            --with-long-double-128
        )
        ;;
    riscv64-linux-gnu)
        echo "Not supported in gcc-4.8"
        exit 0
        ;;
    s390x-linux-gnu)
        TARGET_ARGS+=(
            --with-arch=zEC12
            --with-long-double-128
        )
        ;;
    *)
        echo "Unrecognized target: ${TARGET}"
        exit 0
        ;;
esac

"${SRC_DIR}/configure" --build="${HOST}" --host="${HOST}" --enable-languages=c,c++ \
            --program-prefix="${TARGET}-" --target="${TARGET}" --program-suffix=-4.8 \
            --prefix=/usr/ --with-system-zlib \
            --libexecdir=/usr/lib/ --libdir=/usr/lib/ \
            --disable-nls --disable-shared --enable-host-shared \
            --disable-bootstrap --enable-threads=posix --enable-default-pie \
            --with-sysroot=/ --includedir=/usr/"${TARGET}"/include \
            --without-target-system-zlib --enable-multiarch
            ${TARGET_ARGS[@]} ${CONFIGURE_ARGS} \
            CFLAGS='-std=gnu99' CXXFLAGS='-std=gnu++98'

make -j"${NPROC:-$(nproc)}" ${MAKE_ARGS} \
      CFLAGS='-std=gnu99' CXXFLAGS='-std=gnu++98'

make install ${MAKE_INSTALL_ARGS}
mkdir -p /output/usr/lib/ /output/usr/bin/
cp -r /usr/lib/gcc-cross /output/usr/lib/
cp /usr/bin/*-4.8 /output/usr/bin/
