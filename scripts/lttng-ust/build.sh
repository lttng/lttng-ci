#!/bin/bash
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

failed_configure() {
    # Assume we are in the configured build directory
    echo "#################### BEGIN config.log ####################"
    cat config.log
    echo "#################### END config.log ####################"

    # End the build with failure
    exit 1
}

# Required variables
WORKSPACE=${WORKSPACE:-}

platform=${platform:-}
conf=${conf:-}
build=${build:-}
cc=${cc:-}

# Controls if the tests are run
LTTNG_UST_RUN_TESTS="${LTTNG_UST_RUN_TESTS:=yes}"

SRCDIR="$WORKSPACE/src/lttng-ust"
TMPDIR="$WORKSPACE/tmp"
PREFIX="/build"
LIBDIR="lib"

# RHEL and SLES both use lib64 but don't bother shipping a default autoconf
# site config that matches this.
if [[ ( -f /etc/redhat-release || -f /etc/SuSE-release ) && ( "$(uname -m)" == "x86_64" ) ]]; then
    LIBDIR_ARCH="${LIBDIR}64"
else
    LIBDIR_ARCH="$LIBDIR"
fi

DEPS_INC="$WORKSPACE/deps/build/include"
DEPS_LIB="$WORKSPACE/deps/build/$LIBDIR_ARCH"
DEPS_PKGCONFIG="$DEPS_LIB/pkgconfig"
#DEPS_BIN="$WORKSPACE/deps/build/bin"
#DEPS_JAVA="$WORKSPACE/deps/build/share/java"

export LD_LIBRARY_PATH="$DEPS_LIB:${LD_LIBRARY_PATH:-}"
export PKG_CONFIG_PATH="$DEPS_PKGCONFIG"
export CPPFLAGS="-I$DEPS_INC"
export LDFLAGS="-L$DEPS_LIB"

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

if [ "x${CC:-}" != "x" ]; then
    echo "Selected compiler:"
    "$CC" -v
fi

# Set platform variables
case "$platform" in
freebsd*)
    export MAKE=gmake
    export TAR=tar
    export NPROC="getconf _NPROCESSORS_ONLN"
    export CPPFLAGS="-I/usr/local/include $CPPFLAGS"
    export LDFLAGS="-L/usr/local/lib $LDFLAGS"
    export PYTHON="python3"
    export PYTHON_CONFIG="python3-config"
    export CLASSPATH='/usr/local/share/java/classes/*'
    export JAVA_HOME='/usr/local/openjdk11'
    ;;

*)
    export MAKE=make
    export TAR=tar
    export NPROC=nproc
    export PYTHON="python3"
    export PYTHON_CONFIG="python3-config"
    export CLASSPATH='/usr/share/java/log4j-api.jar:/usr/share/java/log4j-core.jar:/usr/share/java/log4j-1.2.jar'
    ;;
esac

# Print build env details
print_os || true
print_tooling || true

# Enter the source directory
cd "$SRCDIR"

# Run bootstrap in the source directory prior to configure
./bootstrap

# Get source version from configure script
eval "$(grep '^PACKAGE_VERSION=' ./configure)"
PACKAGE_VERSION=${PACKAGE_VERSION//\-pre*/}

# Gerrit will trigger build on FreeBSD regardless of the branch, exit
# successfuly when the version is < 2.13.
if [[ $platform == freebsd* ]] && verlt "$PACKAGE_VERSION" "2.13"; then
    mkdir -p "$WORKSPACE/tap/no-log"
    echo "1..1" > "$WORKSPACE/tap/no-log/tests.log"
    echo "ok 1 - FreeBSD build unsupported in < 2.13" >> "$WORKSPACE/tap/no-log/tests.log"
    exit 0
fi

# Set configure options and environment variables for each build
# configuration.
CONF_OPTS=("--prefix=$PREFIX" "--libdir=$PREFIX/$LIBDIR_ARCH")
case "$conf" in
static)
    echo "Static lib only configuration"

    CONF_OPTS+=("--enable-static" "--disable-shared")

    # Unsupported! liblttng-ust can't pull in it's static (.a) dependencies.
    exit 1
    ;;

agents)
    echo "Java and Python agents configuration"

    CONF_OPTS+=("--enable-java-agent-all" "--enable-jni-interface" "--enable-python-agent")

    # Explicitly add '--enable-java-agent-log4j2', it's not part of '-all' in stable 2.12/2.13
    if verlt "$PACKAGE_VERSION" "2.14"; then
	    CONF_OPTS+=("--enable-java-agent-log4j2")
    fi
    ;;

debug-rcu)
    echo "Enable RCU sanity checks for debugging"
    export CPPFLAGS="${CPPFLAGS} -DDEBUG_RCU"
    ;;

*)
    echo "Standard configuration"

    # Something is broken in docbook-xml on yocto
    if [[ "$platform" = yocto* ]]; then
        CONF_OPTS+=("--disable-man-pages")
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

    "$SRCDIR/configure" "${CONF_OPTS[@]}" || failed_configure
    ;;

dist)
    echo "Distribution in-tree build"

    # Run configure and generate the tar file
    # in the source directory
    ./configure --enable-jni-interface || failed_configure
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
    echo "Distribution out of tree build"

    # Create and enter a temporary build directory
    builddir=$(mktemp -d)
    cd "$builddir"

    # Run configure out of tree and generate the tar file
    "$SRCDIR/configure" --enable-jni-interface || failed_configure
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
    echo "Standard in-tree build"
    ./configure "${CONF_OPTS[@]}" || failed_configure
    ;;
esac

# We are now inside a configured build directory

# BUILD!
$MAKE -j "$($NPROC)" V=1

# Install in the workspace
$MAKE install DESTDIR="$WORKSPACE"

# Run tests, don't fail now, we want to run the archiving steps
failed_tests=0
if [ "$LTTNG_UST_RUN_TESTS" = "yes" ]; then
    $MAKE --keep-going check || failed_tests=1

    # Copy tap logs for the jenkins tap parser before cleaning the build dir
    rsync -a --exclude 'test-suite.log' --include '*/' --include '*.log' --exclude='*' tests/ "$WORKSPACE/tap"

    # The test suite prior to 2.8 did not produce TAP logs
    if verlt "$PACKAGE_VERSION" "2.8"; then
        mkdir -p "$WORKSPACE/tap/no-log"
        echo "1..1" > "$WORKSPACE/tap/no-log/tests.log"
        echo "ok 1 - Test suite doesn't support logging" >> "$WORKSPACE/tap/no-log/tests.log"
    fi
fi

# Clean the build directory
$MAKE clean

# Cleanup rpath in executables and shared libraries
#find "$WORKSPACE/$PREFIX/bin" -type f -perm -0500 -exec chrpath --delete {} \;
find "$WORKSPACE/$PREFIX/$LIBDIR_ARCH" -name "*.so" -exec chrpath --delete {} \;

# Remove libtool .la files
find "$WORKSPACE/$PREFIX/$LIBDIR_ARCH" -name "*.la" -exec rm -f {} \;

# Exit with failure if any of the tests failed
exit $failed_tests

# EOF
