#!/bin/bash -exu
#
# Copyright (C) 2015 Jonathan Rajotte-Julien <jonathan.rajotte-julien@efficios.com>
#               2016-2019 Michael Jeanson <mjeanson@efficios.com>
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

# Version compare functions
vercomp () {
    set +u
    if [[ "$1" == "$2" ]]; then
        return 0
    fi
    local IFS=.
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

# Required variables
WORKSPACE=${WORKSPACE:-}

arch=${arch:-}
conf=${conf:-}
build=${build:-}
cc=${cc:-}


SRCDIR="$WORKSPACE/src/babeltrace"
TMPDIR="$WORKSPACE/tmp"
PREFIX="/build"

# Create tmp directory
rm -rf "$TMPDIR"
mkdir -p "$TMPDIR"

export TMPDIR
export CFLAGS="-g -O2"

# Set compiler variables
case "$cc" in
gcc)
    export CC=gcc
    export CXX=g++
    ;;
gcc-4.8)
    export CC=gcc-4.8
    export CXX=g++-4.8
    ;;
gcc-5)
    export CC=gcc-5
    export CXX=g++-5
    ;;
gcc-6)
    export CC=gcc-6
    export CXX=g++-6
    ;;
gcc-7)
    export CC=gcc-7
    export CXX=g++-7
    ;;
gcc-8)
    export CC=gcc-8
    export CXX=g++-8
    ;;
clang)
    export CC=clang
    export CXX=clang++
    ;;
clang-3.9)
    export CC=clang-3.9
    export CXX=clang++-3.9
    ;;
clang-4.0)
    export CC=clang-4.0
    export CXX=clang++-4.0
    ;;
clang-5.0)
    export CC=clang-5.0
    export CXX=clang++-5.0
    ;;
clang-6.0)
    export CC=clang-6.0
    export CXX=clang++-6.0
    ;;
clang-7)
    export CC=clang-7
    export CXX=clang++-7
    ;;
*)
    if [ "x$cc" != "x" ]; then
	    export CC="$cc"
    fi
    ;;
esac

if [ "x${CC:-}" != "x" ]; then
    echo "Selected compiler:"
    "$CC" -v
fi

# Set platform variables
case "$arch" in
sol10-i386)
    export MAKE=gmake
    export TAR=gtar
    export NPROC=gnproc
    export PATH="/opt/csw/bin:/usr/ccs/bin:$PATH"
    export CPPFLAGS="-I/opt/csw/include"
    export LDFLAGS="-L/opt/csw/lib -R/opt/csw/lib"
    export PKG_CONFIG_PATH="/opt/csw/lib/pkgconfig"
    export PYTHON="python3"
    export PYTHON_CONFIG="python3-config"
    ;;

sol11-i386)
    export MAKE=gmake
    export TAR=gtar
    export NPROC=nproc
    export PATH="$PATH:/usr/perl5/bin"
    export CPPFLAGS="-I/opt/csw/include"
    export LDFLAGS="-L/opt/csw/lib -R/opt/csw/lib"
    export LD_ALTEXEC=/usr/bin/gld
    export LD=/usr/bin/gld
    export PYTHON="python3"
    export PYTHON_CONFIG="python3-config"
    ;;

macosx)
    export MAKE=make
    export TAR=tar
    export NPROC="getconf _NPROCESSORS_ONLN"
    export PATH="/opt/local/bin:/opt/local/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    export CPPFLAGS="-I/opt/local/include"
    export LDFLAGS="-L/opt/local/lib"
    export PYTHON="python3"
    export PYTHON_CONFIG="python3-config"
    ;;

*)
    export MAKE=make
    export TAR=tar
    export NPROC=nproc
    export PYTHON="python3"
    export PYTHON_CONFIG="python3-config"
    ;;
esac

# Enter the source directory
cd "$SRCDIR"

# Run bootstrap in the source directory prior to configure
./bootstrap

# Get source version from configure script
eval "$(grep '^PACKAGE_VERSION=' ./configure)"
PACKAGE_VERSION=${PACKAGE_VERSION//\-pre*/}

# Enable dev mode by default for BT 2.0 builds
export BABELTRACE_DEBUG_MODE=1
export BABELTRACE_DEV_MODE=1
export BABELTRACE_MINIMAL_LOG_LEVEL=TRACE

# Set configure options and environment variables for each build
# configuration.
CONF_OPTS=("--prefix=$PREFIX")
case "$conf" in
static)
    echo "Static lib only configuration"

    CONF_OPTS+=("--enable-static" "--disable-shared")

    if vergte "$PACKAGE_VERSION" "2.0"; then
        CONF_OPTS+=("--enable-built-in-plugins")
    fi
    ;;

python-bindings)
    echo "Python bindings configuration"

    CONF_OPTS+=("--enable-python-bindings")

    if vergte "$PACKAGE_VERSION" "2.0"; then
        CONF_OPTS+=("--enable-python-bindings-doc" "--enable-python-plugins")
    fi
    ;;

prod)
    echo "Production configuration"

    # Unset the developper variables
    unset BABELTRACE_DEBUG_MODE
    unset BABELTRACE_DEV_MODE
    unset BABELTRACE_MINIMAL_LOG_LEVEL

    # Enable the python bindings
    CONF_OPTS+=("--enable-python-bindings" "--enable-python-bindings-doc" "--enable-python-plugins")
    ;;

min)
    echo "Minimal configuration"
    ;;

*)
    echo "Standard configuration"

    # Enable the python bindings / plugins by default with babeltrace2,
    # the test suite is mostly useless without it.
    if vergte "$PACKAGE_VERSION" "2.0"; then
        CONF_OPTS+=("--enable-python-bindings" "--enable-python-plugins")
    fi
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
    echo "Out of tree build"

    # Create and enter a temporary build directory
    builddir=$(mktemp -d)
    cd "$builddir"

    "$SRCDIR/configure" "${CONF_OPTS[@]}"
    ;;

dist)
    echo "Distribution in-tree build"

    # Run configure and generate the tar file
    # in the source directory
    ./configure
    $MAKE dist

    # Create and enter a temporary build directory
    builddir=$(mktemp -d)
    cd "$builddir"

    # Extract the distribution tar in the build directory,
    # ignore the first directory level
    $TAR xvf "$SRCDIR"/*.tar.* --strip 1

    # Build in extracted source tree
    ./configure "${CONF_OPTS[@]}"
    ;;

oot-dist)
    echo "Distribution out of tree build"

    # Create and enter a temporary build directory
    builddir=$(mktemp -d)
    cd "$builddir"

    # Run configure out of tree and generate the tar file
    "$SRCDIR/configure"
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
    "$dist_srcdir/configure" "${CONF_OPTS[@]}"
    ;;

*)
    echo "Standard in-tree build"
    ./configure "${CONF_OPTS[@]}"
    ;;
esac

# We are now inside a configured build directory

# BUILD!
$MAKE -j "$($NPROC)" V=1

# Install in the workspace
$MAKE install DESTDIR="$WORKSPACE"

# Run tests, don't fail now, we want to run the archiving steps
failed_tests=0
$MAKE --keep-going check || failed_tests=1

# Copy tap logs for the jenkins tap parser before cleaning the build dir
rsync -a --exclude 'test-suite.log' --include '*/' --include '*.log' --exclude='*' tests/ "$WORKSPACE/tap"

# The test suite prior to 1.5 did not produce TAP logs
if verlt "$PACKAGE_VERSION" "1.5"; then
    mkdir -p "$WORKSPACE/tap/no-log"
    echo "1..1" > "$WORKSPACE/tap/no-log/tests.log"
    echo "ok 1 - Test suite doesn't support logging" >> "$WORKSPACE/tap/no-log/tests.log"
fi

# Clean the build directory
$MAKE clean

# Cleanup rpath in executables and shared libraries
find "$WORKSPACE/$PREFIX/bin" -type f -perm -0500 -exec chrpath --delete {} \;
find "$WORKSPACE/$PREFIX/lib" -name "*.so" -exec chrpath --delete {} \;

# Remove libtool .la files
find "$WORKSPACE/$PREFIX/lib" -name "*.la" -exec rm -f {} \;

# Exit with failure if any of the tests failed
exit $failed_tests

# EOF
