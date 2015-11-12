#!/bin/bash -exu
#
# Copyright (C) 2015 - Jonathan Rajotte-Julien <jonathan.rajotte-julien@efficios.com>
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


# Create build directory
rm -rf $WORKSPACE/build
mkdir -p $WORKSPACE/build

# liburcu
URCU_INCS="$WORKSPACE/deps/liburcu/build/include/"
URCU_LIBS="$WORKSPACE/deps/liburcu/build/lib/"


PREFIX="$WORKSPACE/build"

# Set platform variables
case "$arch" in
*)
     MAKE=make
     TAR=tar
     NPROC=nproc
     BISON="bison"
     YACC="$BISON -y"
     CFLAGS=""
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


# Run bootstrap prior to configure
./bootstrap


# Build type
# oot : out-of-tree build
# dist: build via make dist
# *   : normal tree build
#
# Make sure to move to the build_path and configure
# before continuing
BUILD_PATH=$WORKSPACE
case "$build" in
oot)
    echo "Out of tree build"
    BUILD_PATH=$WORKSPACE/oot
    mkdir -p $BUILD_PATH
    cd $BUILD_PATH
    $WORKSPACE/configure --prefix=$PREFIX $CONF_OPTS
    ;;

dist)
    echo "Distribution out of tree build"
    BUILD_PATH=`mktemp -d`

    # Initial configure and generate tarball
    ./configure
    $MAKE dist

    mkdir -p $BUILD_PATH
    cp *.tar.* $BUILD_PATH/
    cd $BUILD_PATH

    # Ignore level 1 of tar
    $TAR xvf *.tar.* --strip 1

    $BUILD_PATH/configure --prefix=$PREFIX $CONF_OPTS
    ;;

*)
    BUILD_PATH=$WORKSPACE
    echo "Standard tree build"
    $WORKSPACE/configure --prefix=$PREFIX $CONF_OPTS
    ;;
esac

# BUILD!
$MAKE -j `$NPROC`
$MAKE install

# Run tests
rm -rf $WORKSPACE/tap
mkdir -p $WORKSPACE/tap/unit

cd $BUILD_PATH/tests

prove --merge --exec '' - < $BUILD_PATH/tests/unit_tests --archive $WORKSPACE/tap/unit/ || true

# TAP plugin is having a hard time with .yml files.
rm -f $WORKSPACE/tap/unit/meta.yml

# And also with files without extension, so rename all result to *.tap
find $WORKSPACE/tap/unit/ -type f -exec mv {} {}.tap \;

# Cleanup
$MAKE clean

# Cleanup rpath in executables and shared libraries
find $WORKSPACE/build/lib -name "*.so" -exec chrpath --delete {} \;

# Remove libtool .la files
find $WORKSPACE/build/lib -name "*.la" -exec rm -f {} \;

# Clean temp dir for dist build
if [ "$build" = "dist" ]; then
    cd $WORKSPACE
    rm -rf $BUILD_PATH
fi

# EOF
