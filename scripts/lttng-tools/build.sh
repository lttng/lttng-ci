#!/bin/bash -exu
# shellcheck disable=SC2103
#
# Copyright (C) 2016 Jonathan Rajotte-Julien <jonathan.rajotte-julien@efficios.com>
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
test_type=${test_type:-}

DEPS_INC="$WORKSPACE/deps/build/include"
DEPS_LIB="$WORKSPACE/deps/build/lib"
DEPS_PKGCONFIG="$DEPS_LIB/pkgconfig"
DEPS_BIN="$WORKSPACE/deps/build/bin"
DEPS_JAVA="$WORKSPACE/deps/build/share/java"

export PATH="$DEPS_BIN:$PATH"
export LD_LIBRARY_PATH="$DEPS_LIB:${LD_LIBRARY_PATH:-}"
export PKG_CONFIG_PATH="$DEPS_PKGCONFIG"
export CPPFLAGS="-I$DEPS_INC"
export LDFLAGS="-L$DEPS_LIB"

SRCDIR="$WORKSPACE/src/lttng-tools"
TAPDIR="$WORKSPACE/tap"
PREFIX="/build"


# Create tmp directory
TMPDIR="$WORKSPACE/tmp"
mkdir -p "$TMPDIR"

# Use a symlink in /tmp to point to the the tmp directory
# inside the workspace, this is to work around the path length
# limit of unix sockets which are created by the test suite.
tmpdir="$(mktemp)"
ln -sf "$TMPDIR" "$tmpdir"
export TMPDIR="$tmpdir"

# Create a symlink to "babeltrace" when the "babeltrace2" executable is found.
# This is a temporary workaround until lttng-tools either allows the override of
# the trace reader in its test suite or that we move to only supporting
# babeltrace2
if [ -x "$DEPS_BIN/babeltrace2" ]; then
	ln -s "$DEPS_BIN/babeltrace2" "$DEPS_BIN/babeltrace"
fi

# When using babeltrace2 make sure that it finds its plugins and
# plugin-providers.
export BABELTRACE_PLUGIN_PATH="$DEPS_LIB/babeltrace2/plugins/"
export LIBBABELTRACE2_PLUGIN_PROVIDER_DIR="$DEPS_LIB/babeltrace2/plugin-providers/"

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
    export CPPFLAGS="-I/opt/csw/include -D_XOPEN_SOURCE=500 $CPPFLAGS"
    export LDFLAGS="-L/opt/csw/lib -R/opt/csw/lib $LDFLAGS"
    export PKG_CONFIG_PATH="$PKG_CONFIG_PATH:/opt/csw/lib/pkgconfig"
    export PYTHON="python3"
    export PYTHON_CONFIG="python3-config"

    RUN_TESTS="no"
    ;;

sol11-i386)
    export MAKE=gmake
    export TAR=gtar
    export NPROC=nproc
    export PATH="/opt/csw/bin:$PATH:/usr/perl5/bin"
    export CPPFLAGS="-D_XOPEN_SOURCE=500 $CPPFLAGS"
    export PYTHON="python3"
    export PYTHON_CONFIG="python3-config"
    export PKG_CONFIG_PATH="$PKG_CONFIG_PATH:/usr/lib/pkgconfig"

    RUN_TESTS="no"
    ;;

macosx)
    export MAKE=make
    export TAR=tar
    export NPROC="getconf _NPROCESSORS_ONLN"
    export PATH="/opt/local/bin:/opt/local/sbin:$PATH"
    export CPPFLAGS="-I/opt/local/include $CPPFLAGS"
    export LDFLAGS="-L/opt/local/lib $LDFLAGS"
    export PYTHON="python3"
    export PYTHON_CONFIG="python3-config"

    RUN_TESTS="no"
    ;;

cygwin|cygwin64|msys32|msys64)
    export MAKE=make
    export TAR=tar
    export NPROC=nproc

    RUN_TESTS="no"
    ;;

*)
    export MAKE=make
    export TAR=tar
    export NPROC=nproc

    RUN_TESTS="yes"

    PYTHON2=python2
    PYTHON3=python3

    P2_VERSION=$($PYTHON2 -c "import sys;print(sys.version[:3])")
    P3_VERSION=$($PYTHON3 -c "import sys;print(sys.version[:3])")

    DEPS_PYTHON2="$WORKSPACE/deps/build/lib/python$P2_VERSION/site-packages"
    DEPS_PYTHON3="$WORKSPACE/deps/build/lib/python$P3_VERSION/site-packages"
    ;;
esac

case "$test_type" in
full)
    RUN_TESTS_LONG_REGRESSION="yes"
    ;;
*)
    RUN_TESTS_LONG_REGRESSION="no"
    ;;
esac

# Enter the source directory
cd "$SRCDIR"

# Run bootstrap in the source directory prior to configure
./bootstrap

# Get source version from configure script
eval "$(grep '^PACKAGE_VERSION=' ./configure)"
PACKAGE_VERSION=${PACKAGE_VERSION//\-pre*/}


# The switch to build without UST changed in 2.8
if vergte "$PACKAGE_VERSION" "2.8"; then
    NO_UST="--without-lttng-ust"
else
    NO_UST="--disable-lttng-ust"
fi

# Most build configs require the python bindings
CONF_OPTS=("--prefix=$PREFIX" "--enable-python-bindings")

# Turn on SDT userspace-probe testing
if vergte "$PACKAGE_VERSION" "2.11"; then
    CONF_OPTS+=("--enable-test-sdt-uprobe")
fi

# Set configure options and environment variables for each build
# configuration.
case "$conf" in
static)
    echo "Static lib only configuration"

    CONF_OPTS+=("--enable-static" "--disable-shared")
    ;;

no-ust)
    echo "Build without UST support"
    CONF_OPTS+=("$NO_UST")
    ;;

agents)
    echo "Java and Python agents configuration"

    export JAVA_HOME="/usr/lib/jvm/default-java"
    export CLASSPATH="$DEPS_JAVA/*:/usr/share/java/*"
    export PYTHONPATH="$DEPS_PYTHON2:$DEPS_PYTHON3"

    CONF_OPTS+=("--enable-test-java-agent-all" "--enable-test-python-agent-all")
    ;;

relayd-only)
    echo "Relayd only configuration"

    CONF_OPTS=("--prefix=$PREFIX" "--disable-bin-lttng" "--disable-bin-lttng-consumerd" "--disable-bin-lttng-crash" "--disable-bin-lttng-sessiond" "--disable-extras" "--disable-man-pages" "$NO_UST")
    ;;

debug-rcu)
    echo "Enable RCU sanity checks for debugging"

    export CPPFLAGS="$CPPFLAGS -DDEBUG_RCU"
    ;;

*)
    echo "Standard configuration"
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

# Run tests for all configs except 'no-ust'
failed_tests=0
if [ "$RUN_TESTS" = "yes" ] && [ "$conf" != "no-ust" ]; then
    # Allow core dumps
    ulimit -c unlimited

    # Force the lttng-sessiond path to /bin/true to prevent the spawing of a
    # lttng-sessiond --daemonize on "lttng create"
    export LTTNG_SESSIOND_PATH="/bin/true"

    # Run 'unit_tests', 2.8 and up has a new test suite
    if vergte "$PACKAGE_VERSION" "2.8"; then
        make --keep-going check || failed_tests=1
        rsync -a --exclude 'test-suite.log' --include '*/' --include '*.log' --exclude='*' tests/ "$TAPDIR"
    else
        cd tests
        mkdir -p "$TAPDIR/unit"
        mkdir -p "$TAPDIR/fast_regression"
        mkdir -p "$TAPDIR/with_bindings_regression"
        prove --merge -v --exec '' - < unit_tests --archive "$TAPDIR/unit/" || failed_tests=1
        prove --merge -v --exec '' - < fast_regression --archive "$TAPDIR/fast_regression/" || failed_tests=1
        prove --merge -v --exec '' - < with_bindings_regression --archive "$TAPDIR/with_bindings_regression/" || failed_tests=1
	cd ..
    fi

    if [ "$RUN_TESTS_LONG_REGRESSION" = "yes" ]; then
        cd tests
        mkdir -p "$TAPDIR/long_regression"
        prove --merge -v --exec '' - < long_regression --archive "$TAPDIR/long_regression/" || failed_tests=1
	cd ..
    fi

    # TAP plugin is having a hard time with .yml files.
    find "$TAPDIR" -name "meta.yml" -exec rm -f {} \;
else
    # The TAP plugin will fail the job if no test logs are present
    mkdir -p "$TAPDIR/no-tests"
    echo "1..1" > "$TAPDIR/no-tests/tests.log"
    echo "ok 1 - Test suite disabled" >> "$TAPDIR/no-tests/tests.log"
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
