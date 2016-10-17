#!/bin/bash -exu
#
# Copyright (C) 2015, Jonathan Rajotte-Julien <jonathan.rajotte-julien@efficios.com>
#               2016, Michael Jeanson <mjeanson@efficios.com>
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

# Required parameters
arch=${arch:-}
conf=${conf:-}
build=${build:-}


# liburcu
URCU_INCS="$WORKSPACE/deps/liburcu/build/include/"
URCU_LIBS="$WORKSPACE/deps/liburcu/build/lib/"

SRCDIR="$WORKSPACE/src/lttng-ust"
TMPDIR="$WORKSPACE/tmp"
PREFIX="$WORKSPACE/build"

# Create build and tmp directories
rm -rf "$PREFIX" "$TMPDIR"
mkdir -p "$PREFIX" "$TMPDIR"

export TMPDIR

# Set platform variables
case "$arch" in
*)
     MAKE=make
     TAR=tar
     NPROC=nproc
     #BISON="bison"
     #YACC="$BISON -y"
     #CFLAGS=""
     ;;
esac

# Export build flags
export CPPFLAGS="-I$URCU_INCS"
export LDFLAGS="-L$URCU_LIBS"
export LD_LIBRARY_PATH="$URCU_LIBS:${LD_LIBRARY_PATH:-}"


# Set configure options for each build configuration
CONF_OPTS=""
case "$conf" in
static)
    # Unsupported! liblttng-ust can't pull in it's static (.a) dependencies.
    echo "Static build"
    CONF_OPTS="--enable-static --disable-shared"
    ;;

java-agent)
    echo "Java agent build"
    export CLASSPATH="/usr/share/java/log4j-1.2.jar"
    CONF_OPTS="--enable-java-agent-all"
    ;;

python-agent)
    echo "Python agent build"
    CONF_OPTS="--enable-python-agent"
    ;;

*)
    echo "Standard build"
    CONF_OPTS=""
    ;;
esac

# Enter the source directory
cd "$SRCDIR"

# Run bootstrap in the source directory prior to configure
./bootstrap


# Build type
# oot : out-of-tree build
# dist: build via make dist
# *   : normal tree build
#
# Make sure to move to the build_path and configure
# before continuing
BUILD_PATH=$SRCDIR
case "$build" in
oot)
    echo "Out of tree build"
    BUILD_PATH=$WORKSPACE/oot
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
    "$BUILD_PATH/configure" --prefix="$PREFIX" $CONF_OPTS
    ;;
esac

# BUILD!
$MAKE -j "$($NPROC)" V=1
$MAKE install

# Run tests
$MAKE check

# Copy tap logs for the jenkins tap parser
rsync -a --exclude 'test-suite.log' --include '*/' --include '*.log' --exclude='*' tests/ "$WORKSPACE/tap"

# Clean the build directory
$MAKE clean

# Cleanup rpath in executables and shared libraries
find "$PREFIX/lib" -name "*.so" -exec chrpath --delete {} \;

# Remove libtool .la files
find "$PREFIX/lib" -name "*.la" -exec rm -f {} \;

# Clean temp dir for dist build
if [ "$build" = "dist" ]; then
    cd "$SRCDIR"
    rm -rf "$BUILD_PATH"
fi

# EOF
