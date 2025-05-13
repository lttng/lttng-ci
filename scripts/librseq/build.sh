#!/bin/bash
#
# SPDX-FileCopyrightText: 2015 Jonathan Rajotte-Julien <jonathan.rajotte-julien@efficios.com>
# SPDX-FileCopyrightText: 2016-2023 Michael Jeanson <mjeanson@efficios.com>
# SPDX-License-Identifier: GPL-2.0-or-later

set -exu

# Version compare functions
vercomp () {
    set +u
    if [[ "$1" == "$2" ]]; then
        return 0
    fi
    local IFS=.
    # Ignore the shellcheck warning, we want splitting to happen based on IFS.
    # shellcheck disable=SC2206
    local i ver1=($1) ver2=($2)
    # fill empty fields in ver1 with zeros
    for ((i=${#ver1[@]}; i<${#ver2[@]}; i++)); do
        ver1[i]=0
    done
    for ((i=0; i<${#ver1[@]}; i++)); do
        if [[ -z ${ver2[i]} ]]; then
            # fill empty fields in ver2 with zeros
            ver2[i]=0
        fi
        if ((10#${ver1[i]} > 10#${ver2[i]})); then
            return 1
        fi
        if ((10#${ver1[i]} < 10#${ver2[i]})); then
            return 2
        fi
    done
    set -u
    return 0
}

verlte() {
    vercomp "$1" "$2"; local res="$?"
    [ "$res" -eq "0" ] || [ "$res" -eq "2" ]
}

verlt() {
    vercomp "$1" "$2"; local res="$?"
    [ "$res" -eq "2" ]
}

vergte() {
    vercomp "$1" "$2"; local res="$?"
    [ "$res" -eq "0" ] || [ "$res" -eq "1" ]
}

vergt() {
    vercomp "$1" "$2"; local res="$?"
    [ "$res" -eq "1" ]
}

verne() {
    vercomp "$1" "$2"; local res="$?"
    [ "$res" -ne "0" ]
}

print_header() {
    set +x

    local message=" $1 "
    local message_len
    local padding_len

    message_len="${#message}"
    padding_len=$(( (80 - (message_len)) / 2 ))

    printf '\n'; printf -- '#%.0s' {1..80}; printf '\n'
    printf -- '-%.0s' {1..80}; printf '\n'
    printf -- '#%.0s' $(seq 1 $padding_len); printf '%s' "$message"; printf -- '#%.0s' $(seq 1 $padding_len); printf '\n'
    printf -- '-%.0s' {1..80}; printf '\n'
    printf -- '#%.0s' {1..80}; printf '\n\n'

    set -x
}

failed_configure() {
    # Assume we are in the configured build directory
    print_header "BEGIN config.log"
    cat config.log
    print_header "END config.log"

    # End the build with failure
    exit 1
}

print_header "Librseq build script starting"

# Required variables
WORKSPACE=${WORKSPACE:-}

# Axis
platform=${platform:-}
conf=${conf:-}
build=${build:-}
cc=${cc:-}

# Build steps that can be overriden by the environment
LIBRSEQ_MAKE_INSTALL="${LIBRSEQ_MAKE_INSTALL:-yes}"
LIBRSEQ_MAKE_CLEAN="${LIBRSEQ_MAKE_CLEAN:-yes}"
LIBRSEQ_GEN_COMPILE_COMMANDS="${LIBRSEQ_GEN_COMPILE_COMMANDS:-no}"
LIBRSEQ_RUN_TESTS="${LIBRSEQ_RUN_TESTS:-yes}"

SRCDIR="$WORKSPACE/src/librseq"
TMPDIR="$WORKSPACE/tmp"
PREFIX="/build"
LIBDIR="lib"
LIBDIR_ARCH="$LIBDIR"

# RHEL and SLES both use lib64 but don't bother shipping a default autoconf
# site config that matches this.
if [[ ( -f /etc/redhat-release || -f /etc/products.d/SLES.prod || -f /etc/yocto-release ) ]]; then
    # Detect the userspace bitness in a distro agnostic way
    if file -L /bin/bash | grep '64-bit' >/dev/null 2>&1; then
        LIBDIR_ARCH="${LIBDIR}64"
    fi
fi

exit_status=0

# Use bear to generate compile_commands.json when enabled
BEAR=""
if [ "$LIBRSEQ_GEN_COMPILE_COMMANDS" = "yes" ]; then
    BEAR="bear"
fi

# Create tmp directory
rm -rf "$TMPDIR"
mkdir -p "$TMPDIR"

export TMPDIR
export CFLAGS="-g -O2"
export CXXFLAGS="-g -O2"

# Add the convenience headers in extra to the
# include path.
export CPPFLAGS="-I$SRCDIR/extra"

# Set compiler variables
case "$cc" in
gcc)
    export CC=gcc
    export CXX=g++
    ;;
gcc-*)
    export CC=gcc-${cc#gcc-}
    export CXX=g++-${cc#gcc-}
    ;;
clang)
    export CC=clang
    export CXX=clang++
    ;;
clang-*)
    export CC=clang-${cc#clang-}
    export CXX=clang++-${cc#clang-}
    ;;
*)
    if [ "x$cc" != "x" ]; then
        export CC="$cc"
    fi
    ;;
esac

# Set platform variables
case "$platform" in
*)
    export MAKE=make
    export TAR=tar
    export NPROC=nproc
    export PYTHON="python3"
    export PYTHON_CONFIG="python3-config"
    ;;
esac

# Print build env details
print_header "Build environment details"
print_hardware || true
print_os || true
print_tooling || true

# Enter the source directory
cd "$SRCDIR"

# Run bootstrap in the source directory prior to configure
print_header "Bootstrap autotools"
./bootstrap

# Get source version from configure script
eval "$(grep '^PACKAGE_VERSION=' ./configure)"
PACKAGE_VERSION=${PACKAGE_VERSION//\-pre*/}

# Set configure options and environment variables for each build
# configuration.
CONF_OPTS=("--prefix=$PREFIX" "--libdir=$PREFIX/$LIBDIR_ARCH" "--disable-maintainer-mode")
case "$conf" in
static)
    print_header "Conf: Static lib only"

    CONF_OPTS+=("--enable-static" "--disable-shared")
    ;;

*)
    print_header "Conf: Standard"
    ;;
esac

# Build type
# oot     : out-of-tree build
# dist    : build via make dist
# oot-dist: build via make dist out-of-tree
# *       : normal tree build
#
# Make sure to move to the build directory and run configure
# before continuing.
case "$build" in
oot)
    print_header "Build: Out of tree"

    # Create and enter a temporary build directory
    builddir=$(mktemp -d)
    cd "$builddir"

    "$SRCDIR/configure" "${CONF_OPTS[@]}" || failed_configure
    ;;

dist)
    print_header "Build: Distribution In-tree"

    # Run configure and generate the tar file
    # in the source directory
    ./configure || failed_configure
    $MAKE dist

    # Create and enter a temporary build directory
    builddir=$(mktemp -d)
    cd "$builddir"

    # Extract the distribution tar in the build directory,
    # ignore the first directory level
    $TAR xvf "$SRCDIR"/*.tar.* --strip 1

    # Build in extracted source tree
    ./configure "${CONF_OPTS[@]}" || failed_configure
    ;;

oot-dist)
    print_header "Build: Distribution Out of tree"

    # Create and enter a temporary build directory
    builddir=$(mktemp -d)
    cd "$builddir"

    # Run configure out of tree and generate the tar file
    "$SRCDIR/configure" || failed_configure
    $MAKE dist

    dist_srcdir="$(mktemp -d)"
    cd "$dist_srcdir"

    # Extract the distribution tar in the new source directory,
    # ignore the first directory level
    $TAR xvf "$builddir"/*.tar.* --strip 1

    # Create and enter a second temporary build directory
    builddir="$(mktemp -d)"
    cd "$builddir"

    # Run configure from the extracted distribution tar,
    # out of the source tree
    "$dist_srcdir/configure" "${CONF_OPTS[@]}" || failed_configure
    ;;

*)
    print_header "Build: Standard In-tree"

    ./configure "${CONF_OPTS[@]}" || failed_configure
    ;;
esac

# We are now inside a configured build directory

# BUILD!
print_header "BUILD!"
$BEAR ${BEAR:+--} $MAKE -j "$($NPROC)" V=1

# Install in the workspace if enabled
if [ "$LIBRSEQ_MAKE_INSTALL" = "yes" ]; then
    print_header "Install"

    $MAKE install V=1 DESTDIR="$WORKSPACE"

    # Cleanup rpath in executables and shared libraries
    #find "$WORKSPACE/$PREFIX/bin" -type f -perm -0500 -exec chrpath --delete {} \;
    find "$WORKSPACE/$PREFIX/$LIBDIR_ARCH" -name "*.so" -exec chrpath --delete {} \;

    # Remove libtool .la files
    find "$WORKSPACE/$PREFIX/$LIBDIR_ARCH" -name "*.la" -delete
fi

# Run tests if enabled
if [ "$LIBRSEQ_RUN_TESTS" = "yes" ]; then
    print_header "Run test suite"

    # Run tests, don't fail now, we want to run the archiving steps
    $MAKE --keep-going check || exit_status=1

    # Copy tap logs for the jenkins tap parser before cleaning the build dir
    rsync -a --exclude 'test-suite.log' --include '*/' --include '*.log' --exclude='*' tests/ "$WORKSPACE/tap"

    # Copy the test suites top-level log which includes all tests failures
    rsync -a --include 'test-suite.log' --include '*/' --exclude='*' tests/ "$WORKSPACE/log"
fi

# Clean the build directory
if [ "$LIBRSEQ_MAKE_CLEAN" = "yes" ]; then
    print_header "Clean"
    $MAKE clean
fi

print_header "Librseq build script ended with: $(test $exit_status == 0 && echo SUCCESS || echo FAILURE)"

# Exit with failure if any of the tests failed
exit $exit_status

# EOF
# vim: expandtab tabstop=4 shiftwidth=4
