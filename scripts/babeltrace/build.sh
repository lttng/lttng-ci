#!/bin/bash -exu
#
# Copyright (C) 2015 - Jonathan Rajotte-Julien <jonathan.rajotte-julien@efficios.com>
#               2016 - Michael Jeanson <mjeanson@efficios.com>
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

# Required parameters
arch=${arch:-}
conf=${conf:-}
build=${build:-}
cc=${cc:-}


SRCDIR="$WORKSPACE/src/babeltrace"
TMPDIR="$WORKSPACE/tmp"
PREFIX="$WORKSPACE/build"

# Create build and tmp directories
rm -rf "$PREFIX" "$TMPDIR"
mkdir -p "$PREFIX" "$TMPDIR"

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

if [ "x$CC" != "x" ]; then
    echo "Selected compiler:"
    "$CC" -v
fi

# Set platform variables
case "$arch" in
sol10-i386)
    export MAKE=gmake
    export TAR=gtar
    export NPROC=gnproc
    export BISON=bison
    export YACC="$BISON -y"
    export PATH="/opt/csw/bin:/usr/ccs/bin:$PATH"
    export CPPFLAGS="-I/opt/csw/include"
    export LDFLAGS="-L/opt/csw/lib -R/opt/csw/lib"
    export PKG_CONFIG_PATH="/opt/csw/lib/pkgconfig"
    ;;
sol11-i386)
    export MAKE=gmake
    export TAR=gtar
    export NPROC=nproc
    export PATH="$PATH:/usr/perl5/bin"
    export LD_ALTEXEC=/usr/bin/gld
    export LD=/usr/bin/gld
    ;;
macosx)
    export MAKE=make
    export TAR=tar
    export NPROC="getconf _NPROCESSORS_ONLN"
    export BISON="bison"
    export YACC="$BISON -y"
    export PATH="/opt/local/bin:/opt/local/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    export CFLAGS="$CFLAGS -I/opt/local/include"
    export LDFLAGS="-L/opt/local/lib"
    ;;
*)
    export MAKE=make
    export TAR=tar
    export NPROC=nproc
    ;;
esac

# Enter the source directory
cd "$SRCDIR"

# Run bootstrap in the source directory prior to configure
./bootstrap

# Get source version from configure script
eval "$(grep '^PACKAGE_VERSION=' ./configure)"

# Set configure options for each build configuration
CONF_OPTS=""
case "$conf" in
static)
    echo "Static build"
    CONF_OPTS="--enable-static --disable-shared"
    if vergte "$PACKAGE_VERSION" "2.0"; then
        CONF_OPTS="${CONF_OPTS} --enable-built-in-plugins"
    fi
    ;;
python-bindings)
    echo "Build with python bindings"
    # We only support bindings built with Python 3
    export PYTHON="python3"
    export PYTHON_CONFIG="/usr/bin/python3-config"
    CONF_OPTS="--enable-python-bindings"

    if vergte "$PACKAGE_VERSION" "2.0"; then
        CONF_OPTS="${CONF_OPTS} --enable-python-bindings-doc --enable-python-plugins"
    fi
    ;;
*)
    echo "Standard build"
    CONF_OPTS=""
    ;;
esac

# Build type
# oot : out-of-tree build
# dist: build via make dist
# *   : normal tree build
#
# Make sure to move to the build_path and configure
# before continuing
BUILD_PATH="$SRCDIR"
case "$build" in
    oot)
        echo "Out of tree build"
        BUILD_PATH="$WORKSPACE/oot"
        mkdir -p "$BUILD_PATH"
        cd "$BUILD_PATH"
        "$SRCDIR/configure" --prefix="$PREFIX" $CONF_OPTS
        ;;

    dist)
        echo "Distribution out of tree build"
        BUILD_PATH="$(mktemp -d)"

        # Initial configure and generate tarball
        "$SRCDIR/configure"
        $MAKE dist

        mkdir -p "$BUILD_PATH"
        cp ./*.tar.* "$BUILD_PATH/"
        cd "$BUILD_PATH"

        # Ignore level 1 of tar
        $TAR xvf ./*.tar.* --strip 1

        "$BUILD_PATH/configure" --prefix="$PREFIX" $CONF_OPTS
        ;;

    *)
        echo "Standard in-tree build"
        "$SRCDIR/configure" --prefix="$PREFIX" $CONF_OPTS
        ;;
esac

# BUILD!
$MAKE -j "$($NPROC)" V=1
$MAKE install

# Run tests
$MAKE --keep-going check

# Copy tap logs for the jenkins tap parser
rsync -a --exclude 'test-suite.log' --include '*/' --include '*.log' --exclude='*' tests/ "$WORKSPACE/tap"

# Clean the build directory
$MAKE clean

# Cleanup rpath in executables and shared libraries
find "$PREFIX/bin" -type f -perm -0500 -exec chrpath --delete {} \;
find "$PREFIX/lib" -name "*.so" -exec chrpath --delete {} \;

# Remove libtool .la files
find "$PREFIX/lib" -name "*.la" -exec rm -f {} \;

# Clean temp dir for dist build
if [ "$build" = "dist" ]; then
    cd "$SRCDIR"
    rm -rf "$BUILD_PATH"
fi

# EOF
