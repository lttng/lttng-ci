FROM docker.io/debian:bookworm

#
# Create the container: podman build -t gcc-5 -f gcc5.Containerfile .
# Build the cross compilers:
#   mkdir -p ~/gcc-5
#   for i in aarch64-linux-gnu arm-linux-gnueabihf i686-linux-gnu powerpc64le-linux-gnu powerpc-linux-gnu riscv64-linux-gnu s390x-linux-gnu ; do podman run --rm -e "TARGET=$i" -e "SRC_DIR=/src/gcc-releases-gcc-5.5.0" -e "BIN_SUFFIX=5" -e "CSTD=gnu11" -e "CXXSTD=gnu++11" -v ~/gcc-5:/output localhost/gcc-5 ; done
#   tar -czf ~/gcc-5.tgz -C ~/gcc-5 ./

RUN echo 'deb-src http://deb.debian.org/debian bookworm main contrib' >> /etc/apt/sources.list
RUN apt-get update

RUN apt-get -y --force-yes build-dep gcc-12
RUN apt-get -y --force-yes install wget
RUN apt-get -y --force-yes install gcc-12-aarch64-linux-gnu gcc-12-riscv64-linux-gnu gcc-12-i686-linux-gnu gcc-12-s390x-linux-gnu gcc-12-powerpc64le-linux-gnu gcc-12-powerpc-linux-gnu gcc-12-arm-linux-gnueabihf
# gcc-5.5.0 isn't compatible with libisl >= 0.21, as that version drops
# the deprecated isl_map_n_out function.
# See libisl commit aed01a35f1cd18ec6c9d3d151aee8d66afd67610
# gcc-5.5.0 ins't compatible with libisl >= 0.19 as isl_band.h was removed in 0.19.
# See libisl commit 4eb5d8f7ea10bd5b47022334640f3c074f5a3d40
#
# RUN wget -q http://snapshot.debian.org/archive/debian/20170106T032927Z/pool/main/i/isl/libisl-dev_0.18-1_amd64.deb
# RUN wget -q http://snapshot.debian.org/archive/debian/20170106T032927Z/pool/main/i/isl/libisl15_0.18-1_amd64.deb
# RUN apt install -y --allow-downgrades ./*.deb

RUN mkdir -p /src/build /src/patches /output
WORKDIR /src
RUN wget -q -O - https://github.com/gcc-mirror/gcc/archive/refs/tags/releases/gcc-5.5.0.tar.gz | tar -xzf -

WORKDIR /src/patches
# ustat.h was removed from glibc 2.28; the build of the compiler piggy backs on
# glibc shipped with the base OS, so a patch to address it's removal is
# necessary to allow the build to pass.
RUN wget -q https://aur.archlinux.org/cgit/aur.git/plain/glibc2.28-ustat.patch?h=gcc5 -O 01-ustat_removal.patch.0

# recent linux kernels removed support for cyclades
COPY gcc5-cyclades_removal.patch /src/patches/02-cyclades_removal.patch.1

# backport of https://github.com/gcc-mirror/gcc/commit/2701442d0cf6292f6624443c15813d6d1a3562fe
COPY gcc5-sanitizer_fs.patch /src/patches/03-sanitizer_fs.patch.1

WORKDIR /src/build
COPY script.sh /usr/bin/build-gcc.sh
CMD /usr/bin/build-gcc.sh

# @TODO: missing crtbegin.o eg., libgcc-5-dev-arm64-cross
# This can be "worked around" by copying the system libc-cross
# eg.
#   cp -r /usr/lib/gcc-cross/aarch64-linux-gnu/12/ /usr/lib/gcc-cross/aarch64-linux-gnu/5.5.0
#   make
#
