#!/bin/bash
# shellcheck disable=SC2103
#
# Copyright (C) 2016 Jonathan Rajotte-Julien <jonathan.rajotte-julien@efficios.com>
# Copyright (C) 2016-2020 Michael Jeanson <mjeanson@efficios.com>
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

set_execute_traversal_bit()
{
    path=$1

    level="$path"
    if [ ! -d "$path" ]; then
        fail "Path is not a directory"
    fi
    while level="$(dirname "$level")"
    do
        if [ "$level" = / ]; then
            break
        fi
        chmod a+x "$level"
    done
    chmod a+x "$path"
}

# Required variables
WORKSPACE=${WORKSPACE:-}

platform=${platform:-}
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
export CXXFLAGS="-g -O2"

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
case "$platform" in
macos*)
    export MAKE=make
    export TAR=tar
    export NPROC="getconf _NPROCESSORS_ONLN"
    export PATH="/opt/local/bin:/opt/local/sbin:$PATH"
    export CPPFLAGS="-I/opt/local/include $CPPFLAGS"
    export LDFLAGS="-L/opt/local/lib $LDFLAGS"
    export PYTHON="python3"
    export PYTHON_CONFIG="python3-config"

    LTTNG_TOOLS_RUN_TESTS="no"
    ;;

cygwin|cygwin64|msys32|msys64)
    export MAKE=make
    export TAR=tar
    export NPROC=nproc

    LTTNG_TOOLS_RUN_TESTS="no"
    ;;

*)
    export MAKE=make
    export TAR=tar
    export NPROC=nproc

    LTTNG_TOOLS_RUN_TESTS="yes"

    PYTHON2=python2
    PYTHON3=python3

    if command -v $PYTHON2 >/dev/null 2>&1; then
        P2_VERSION=$($PYTHON2 -c 'import sys;v = sys.version.split()[0].split("."); print("{}.{}".format(v[0], v[1]))')
        DEPS_PYTHON2="$WORKSPACE/deps/build/lib/python$P2_VERSION/site-packages"
    fi

    P3_VERSION=$($PYTHON3 -c 'import sys;v = sys.version.split()[0].split("."); print("{}.{}".format(v[0], v[1]))')
    DEPS_PYTHON3="$WORKSPACE/deps/build/lib/python$P3_VERSION/site-packages"

    # Most build configs require access to the babeltrace 2 python bindings.
    # This also makes the lttngust python agent available for `agents` builds.
    export PYTHONPATH="${DEPS_PYTHON2:-}${DEPS_PYTHON2:+:}$DEPS_PYTHON3"
    ;;
esac

# The missing-field-initializers warning code is very dumb in GCC 4.8 on
# SLES12, disable it even if it's available.
if [[ $platform = sles12sp5* ]]; then
    CFLAGS="$CFLAGS -Wno-missing-field-initializers"
    CXXFLAGS="$CXXFLAGS -Wno-missing-field-initializers"
fi

case "$test_type" in
full)
    LTTNG_TOOLS_RUN_TESTS_LONG_REGRESSION="yes"
    ;;
*)
    LTTNG_TOOLS_RUN_TESTS_LONG_REGRESSION="no"
    ;;
esac

# If we have modules, build them
if [ -d "$WORKSPACE/src/lttng-modules" ]; then
    cd "$WORKSPACE/src/lttng-modules"
    $MAKE -j"$($NPROC)" V=1
    $MAKE modules_install V=1
    depmod
fi

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


# The switch to build without UST changed in 2.8
if vergte "$PACKAGE_VERSION" "2.8"; then
    NO_UST="--without-lttng-ust"
else
    NO_UST="--disable-lttng-ust"
fi

# Most build configs require the python bindings
CONF_OPTS=("--prefix=$PREFIX" "--enable-python-bindings")

DIST_CONF_OPTS=()

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
    DIST_CONF_OPTS+=("$NO_UST")
    ;;

agents)
    echo "Java and Python agents configuration"

    export JAVA_HOME="/usr/lib/jvm/default-java"
    export CLASSPATH="$DEPS_JAVA/lttng-ust-agent-all.jar:/usr/share/java/log4j-api.jar:/usr/share/java/log4j-core.jar:/usr/share/java/log4j-1.2.jar"

    CONF_OPTS+=("--enable-test-java-agent-all" "--enable-test-python-agent-all")

    # Explicitly add '--enable-test-java-agent-log4j2', it's not part of '-all' in stable 2.12/2.13
    if verlt "$PACKAGE_VERSION" "2.14"; then
        CONF_OPTS+=("--enable-test-java-agent-log4j2")
    fi
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

    "$SRCDIR/configure" "${CONF_OPTS[@]}" || failed_configure
    ;;

dist)
    echo "Distribution in-tree build"

    # Run configure and generate the tar file
    # in the source directory
    ./configure "${DIST_CONF_OPTS[@]}" || failed_configure
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
    "$SRCDIR/configure" "${DIST_CONF_OPTS[@]}" || failed_configure
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

# Run tests for all configs except 'no-ust'
failed_tests=0
if [ "$LTTNG_TOOLS_RUN_TESTS" = "yes" ] && [ "$conf" != "no-ust" ]; then
    # Allow core dumps
    ulimit -c unlimited

    # Force the lttng-sessiond path to /bin/true to prevent the spawing of a
    # lttng-sessiond --daemonize on "lttng create"
    export LTTNG_SESSIOND_PATH="/bin/true"

    # Run 'unit_tests', 2.8 and up has a new test suite
    if vergte "$PACKAGE_VERSION" "2.8"; then
        # It is implied that tests depending on LTTNG_ENABLE_DESTRUCTIVE_TESTS
        # only run for the root user. Note that here `destructive` means that
        # operations are performed at the host level (add user etc.) that
        # effectively modify the host. Running those tests are acceptable on our
        # CI and root jobs since we always run root tests against a `snapshot`
        # of the host.
        if [ "$(id -u)" == "0" ]; then
            # Allow the traversal of all directories leading to the
            # DEPS_LIBS directory to enable test app run by temp users to
            # access lttng-ust.
            set_execute_traversal_bit "$DEPS_LIB"
            # Allow `all` to interact with all deps libs.
            chmod a+rwx -R "$DEPS_LIB"

            export LTTNG_ENABLE_DESTRUCTIVE_TESTS="will-break-my-system"

            # Some destructive tests play with the system clock, disable timesyncd
            systemctl stop systemd-timesyncd.service || true
        fi

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

    if [ "$LTTNG_TOOLS_RUN_TESTS_LONG_REGRESSION" = "yes" ]; then
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

# Cleanup rpath in executables
find "$WORKSPACE/$PREFIX/bin" -type f -perm -0500 -exec chrpath --delete {} \;

# Some configs don't build liblttng-ctl
if [ -d "$WORKSPACE/$PREFIX/lib" ]; then
    # Cleanup rpath in shared libraries
    find "$WORKSPACE/$PREFIX/lib" -name "*.so" -exec chrpath --delete {} \;
    # Remove libtool .la files
    find "$WORKSPACE/$PREFIX/lib" -name "*.la" -exec rm -f {} \;
fi

# Exit with failure if any of the tests failed
exit $failed_tests

# EOF
