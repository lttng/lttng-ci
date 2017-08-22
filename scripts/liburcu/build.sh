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


SRCDIR="$WORKSPACE/src/liburcu"
TMPDIR="$WORKSPACE/tmp"
PREFIX="$WORKSPACE/build"

# Create build and tmp directories
rm -rf "$PREFIX" "$TMPDIR"
mkdir -p "$PREFIX" "$TMPDIR"

export TMPDIR
export CFLAGS="-g -O2"

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
    export BISON="/opt/csw/bin/bison"
    export YACC="$BISON -y"
    export PATH="$PATH:/usr/perl5/bin"
    #export LD_ALTEXEC=/usr/sfw/bin/gld
    #export LD=/usr/sfw/bin/gld
    ;;
macosx)
    export MAKE=make
    export TAR=tar
    export NPROC="getconf _NPROCESSORS_ONLN"
    export BISON="bison"
    export YACC="$BISON -y"
    export LDFLAGS="-L/opt/local/lib"
    export CFLAGS="$CFLAGS -I/opt/local/include"
    export PATH="/opt/local/bin:/opt/local/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
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

# Set configure options and environment variables for each build
# configuration.
CONF_OPTS=""
case "$conf" in
static)
    echo "Static build"
    CONF_OPTS="--enable-static --disable-shared"
    ;;

tls_fallback)
    echo  "Using pthread_getspecific() to emulate TLS"
    CONF_OPTS="--disable-compiler-tls"
    ;;

debug-rcu)
    echo "Enable RCU sanity checks for debugging"
    if vergte "$PACKAGE_VERSION" "0.10"; then
       CONF_OPTS="--enable-rcu-debug"
    else
       export CFLAGS="$CFLAGS -DDEBUG_RCU"
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
    BUILD_PATH=$(mktemp -d)

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
# Only run regtest for 0.9 and up
if vergte "$PACKAGE_VERSION" "0.9"; then
   $MAKE regtest
fi

# Cleanup
$MAKE clean

# Cleanup rpath in executables and shared libraries
#find $WORKSPACE/build/bin -type f -perm -0500 -exec chrpath --delete {} \;
find "$PREFIX/lib" -name "*.so" -exec chrpath --delete {} \;

# Remove libtool .la files
find "$PREFIX/lib" -name "*.la" -exec rm -f {} \;

# Cleanup temp directory of dist build
if [ "$build" = "dist" ]; then
    cd "$SRCDIR"
    rm -rf "$BUILD_PATH"
fi

# EOF
