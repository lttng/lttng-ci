#!/bin/bash
#
# SPDX-FileCopyrightText: 2016 Jonathan Rajotte-Julien <jonathan.rajotte-julien@efficios.com>
# SPDX-FileCopyrightText: 2016-2023 Michael Jeanson <mjeanson@efficios.com>
# SPDX-License-Identifier: GPL-2.0-or-later
#
# shellcheck disable=SC2103

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

print_header "LTTng-tools build script starting"

# Required variables
WORKSPACE=${WORKSPACE:-}

# Axis
platform=${platform:-}
conf=${conf:-}
build=${build:-}
cc=${cc:-}

# Build steps that can be overriden by the environment
LTTNG_TOOLS_MAKE_INSTALL="${LTTNG_TOOLS_MAKE_INSTALL:-yes}"
LTTNG_TOOLS_MAKE_CLEAN="${LTTNG_TOOLS_MAKE_CLEAN:-yes}"
LTTNG_TOOLS_GEN_COMPILE_COMMANDS="${LTTNG_TOOLS_GEN_COMPILE_COMMANDS:-no}"
LTTNG_TOOLS_RUN_TESTS="${LTTNG_TOOLS_RUN_TESTS:-yes}"
LTTNG_TOOLS_RUN_TESTS_LONG_REGRESSION="${LTTNG_TOOLS_RUN_TESTS_LONG_REGRESSION:-no}"
LTTNG_TOOLS_RUN_UST_JAVA_TESTS="${LTTNG_TOOLS_RUN_UST_JAVA_TESTS:-yes}"
LTTNG_TOOLS_CLANG_TIDY="${LTTNG_TOOLS_CLANG_TIDY:-no}"

SRCDIR="$WORKSPACE/src/lttng-tools"
TAPDIR="$WORKSPACE/tap"
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

DEPS_INC="$WORKSPACE/deps/build/include"
DEPS_LIB="$WORKSPACE/deps/build/$LIBDIR_ARCH"
DEPS_PKGCONFIG="$DEPS_LIB/pkgconfig"
DEPS_BIN="$WORKSPACE/deps/build/bin"
DEPS_JAVA="$WORKSPACE/deps/build/share/java"

export PATH="$DEPS_BIN:$PATH"
export LD_LIBRARY_PATH="$DEPS_LIB:${LD_LIBRARY_PATH:-}"
export PKG_CONFIG_PATH="$DEPS_PKGCONFIG"
export CPPFLAGS="-I$DEPS_INC"
export LDFLAGS="-L$DEPS_LIB"

exit_status=0

# Use bear to generate compile_commands.json when enabled
BEAR=""
if [ "$LTTNG_TOOLS_GEN_COMPILE_COMMANDS" = "yes" ]; then
	BEAR="bear"
fi

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
macos*)
    export MAKE=make
    export TAR=tar
    export NPROC="getconf _NPROCESSORS_ONLN"
    export PATH="/opt/local/bin:/opt/local/sbin:$PATH"
    export CPPFLAGS="-I/opt/local/include $CPPFLAGS"
    export LDFLAGS="-L/opt/local/lib $LDFLAGS"
    export PYTHON="python3"
    export PYTHON_CONFIG="python3-config"
    ;;

cygwin|cygwin64|msys32|msys64)
    export MAKE=make
    export TAR=tar
    export NPROC=nproc
    ;;

*)
    export MAKE=make
    export TAR=tar
    export NPROC=nproc

    PYTHON2=python2
    PYTHON3=python3

    if command -v $PYTHON2 >/dev/null 2>&1; then
        P2_VERSION=$($PYTHON2 -c 'import sys;v = sys.version.split()[0].split("."); print("{}.{}".format(v[0], v[1]))')
        DEPS_PYTHON2="$WORKSPACE/deps/build/$LIBDIR/python$P2_VERSION/site-packages"
	if [ "$LIBDIR" != "$LIBDIR_ARCH" ]; then
            DEPS_PYTHON2="$DEPS_PYTHON2:$WORKSPACE/deps/build/$LIBDIR_ARCH/python$P2_VERSION/site-packages"
	fi
    fi

    P3_VERSION=$($PYTHON3 -c 'import sys;v = sys.version.split()[0].split("."); print("{}.{}".format(v[0], v[1]))')

    # Temporary fix for an issue on debian python >= 3.10, add the 'local' prefix
    DEPS_PYTHON3="$WORKSPACE/deps/build/$LIBDIR/python$P3_VERSION/site-packages:$WORKSPACE/deps/build/local/$LIBDIR/python$P3_VERSION/dist-packages"
    if [ "$LIBDIR" != "$LIBDIR_ARCH" ]; then
        DEPS_PYTHON3="$DEPS_PYTHON3:$WORKSPACE/deps/build/$LIBDIR_ARCH/python$P3_VERSION/site-packages"
    fi

    # Most build configs require access to the babeltrace 2 python bindings.
    # This also makes the lttngust python agent available for `agents` builds.
    export PYTHONPATH="${DEPS_PYTHON2:-}${DEPS_PYTHON2:+:}$DEPS_PYTHON3"
    ;;
esac

# Some warning flags are very dumb in GCC 4.8 on SLES12 / EL7, disable them
# even if they are available.
if [[ $platform = sles12sp5* ]] || [[  $platform = el7* ]]; then
    CFLAGS="$CFLAGS -Wno-missing-field-initializers -Wno-shadow"
    CXXFLAGS="$CXXFLAGS -Wno-missing-field-initializers -Wno-shadow"
fi

# If we have modules, build them
if [ -d "$WORKSPACE/src/lttng-modules" ]; then
    print_header "Build and install LTTng-modules"
    cd "$WORKSPACE/src/lttng-modules"
    $MAKE -j"$($NPROC)" V=1
    $MAKE modules_install V=1
    depmod
fi

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

CONF_OPTS=("--prefix=$PREFIX" "--libdir=$PREFIX/$LIBDIR_ARCH" "--disable-maintainer-mode")
DIST_CONF_OPTS=("--disable-maintainer-mode")

# Set configure options and environment variables for each build
# configuration.
case "$conf" in
static)
    print_header "Conf: Static lib only"

    CONF_OPTS+=("--enable-static" "--disable-shared" "--enable-python-bindings")
    ;;

no-ust)
    print_header "Conf: Without UST support"

    CONF_OPTS+=("--without-lttng-ust")
    DIST_CONF_OPTS+=("--without-lttng-ust")
    ;;

agents)
    print_header "Conf: Java and Python agents"

    if [[ -z "${JAVA_HOME:-}" ]] ; then
        export JAVA_HOME="/usr/lib/jvm/default-java"
    fi
    export CLASSPATH="$DEPS_JAVA/lttng-ust-agent-all.jar:/usr/share/java/log4j-api.jar:/usr/share/java/log4j-core.jar:/usr/share/java/log4j-1.2.jar"

    CONF_OPTS+=("--enable-python-bindings" "--enable-test-java-agent-all")

    # Explicitly add '--enable-test-java-agent-log4j2', it's not part of '-all' in stable 2.12/2.13
    if verlt "$PACKAGE_VERSION" "2.14"; then
        CONF_OPTS+=("--enable-test-java-agent-log4j2")
    fi

    # Some distros don't ship python2 anymore
    if command -v $PYTHON2 >/dev/null 2>&1; then
        CONF_OPTS+=("--enable-test-python-agent-all")
    else
        CONF_OPTS+=("--enable-test-python3-agent")
    fi
    ;;

relayd-only)
    print_header "Conf: Relayd only"

    CONF_OPTS+=("--disable-bin-lttng" "--disable-bin-lttng-consumerd" "--disable-bin-lttng-crash" "--disable-bin-lttng-sessiond" "--disable-extras" "--disable-man-pages" "--without-lttng-ust")
    ;;

debug-rcu)
    print_header "Conf: RCU sanity checks for debugging"

    CONF_OPTS+=("--enable-python-bindings")

    export CPPFLAGS="$CPPFLAGS -DDEBUG_RCU"
    ;;

*)
    print_header "Conf: Standard"

    CONF_OPTS+=("--enable-python-bindings")

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
    print_header "Build: Out of tree"

    # Create and enter a temporary build directory
    builddir=$(mktemp -d)
    cd "$builddir"

    "$SRCDIR/configure" "${CONF_OPTS[@]}" || failed_configure
    ;;

dist)
    print_header "Build: Distribution in-tree"

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
    print_header "Build: Distribution Out of tree"

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
    print_header "Build: Standard In-tree"
    ./configure "${CONF_OPTS[@]}" || failed_configure
    ;;
esac

# We are now inside a configured build directory

# BUILD!
print_header "BUILD!"
$BEAR ${BEAR:+--} $MAKE -j "$($NPROC)" V=1

# Install in the workspace if enabled
if [ "$LTTNG_TOOLS_MAKE_INSTALL" = "yes" ]; then
    print_header "Install"

    $MAKE install V=1 DESTDIR="$WORKSPACE"

    # Cleanup rpath in executables
    find "$WORKSPACE/$PREFIX/bin" -type f -perm -0500 -exec chrpath --delete {} \;

    # Some configs don't build liblttng-ctl
    if [ -d "$WORKSPACE/$PREFIX/$LIBDIR_ARCH" ]; then
        # Cleanup rpath in shared libraries
        find "$WORKSPACE/$PREFIX/$LIBDIR_ARCH" -name "*.so" -exec chrpath --delete {} \;
        # Remove libtool .la files
        find "$WORKSPACE/$PREFIX/$LIBDIR_ARCH" -name "*.la" -delete
    fi
fi

# Run clang-tidy on the topmost commit
if [ "$LTTNG_TOOLS_CLANG_TIDY" = "yes" ]; then
    print_header "Run clang-tidy"

    # This would be better by linting only the lines touched by a patch but it
    # doesn't seem to work, the lines are always filtered and no error is
    # reported.
    #git diff -U0 HEAD^ | clang-tidy-diff -p1 -j "$($NPROC)" -timeout 60 -fix

    # Instead, run clan-tidy on all the files touched by the patch.
    while read -r filepath; do
        if [[ "$filepath" =~ (\.cpp|\.hhp|\.c|\.h)$ ]]; then
            clang-tidy --fix-errors "$(realpath "$filepath")"
        fi
    done < <(git diff-tree --no-commit-id --diff-filter=d --name-only -r HEAD)

    # If the tree has local changes, the formatting was incorrect
    GIT_DIFF_OUTPUT=$(git diff)
    if [ -n "$GIT_DIFF_OUTPUT" ]; then
        echo "Saving clang-tidy proposed fixes in clang-tidy-fixes.diff"
        git diff > "$WORKSPACE/clang-tidy-fixes.diff"

        # Restore the unfixed files so they can be viewed in the warnings web
        # interface
        git checkout .
        exit_status=1
    fi
fi

# Run tests for all configs except 'no-ust' / 'relayd-only'
if [ "$LTTNG_TOOLS_RUN_TESTS" = "yes" ] && [[ ! "$conf" =~ (no-ust|relayd-only) ]]; then
    print_header "Run test suite"

    # Allow core dumps
    ulimit -c unlimited

    # Force the lttng-sessiond path to /bin/true to prevent the spawing of a
    # lttng-sessiond --daemonize on "lttng create"
    export LTTNG_SESSIOND_PATH="/bin/true"

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

    make --keep-going check || exit_status=1

        # Copy tap logs for the jenkins tap parser before cleaning the build dir
    rsync -a --exclude 'test-suite.log' --include '*/' --include '*.log' --exclude='*' tests/ "$TAPDIR"

    # Copy the test suites top-level log which includes all tests failures
    rsync -a --include 'test-suite.log' --include '*/' --exclude='*' tests/ "$WORKSPACE/log"

    if [ "$LTTNG_TOOLS_RUN_TESTS_LONG_REGRESSION" = "yes" ]; then
        print_header "Run long regression tests"
        cd tests
        mkdir -p "$TAPDIR/long_regression"
        prove --merge -v --exec '' - < long_regression --archive "$TAPDIR/long_regression/" || exit_status=1
        cd ..
    fi

    if [ "$LTTNG_TOOLS_RUN_UST_JAVA_TESTS" = "yes" ] && [ "$LTTNG_TOOLS_MAKE_INSTALL" = "yes" ] && [ "$conf" = "agents" ] ; then
        print_header "Run lttng-ust-java-tests"
        # Git Source
        LTTNG_UST_JAVA_TESTS_GIT_SOURCE="${LTTNG_UST_JAVA_TESTS_GIT_SOURCE:-https://github.com/lttng/lttng-ust-java-tests.git}"
        LTTNG_UST_JAVA_TESTS_GIT_BRANCH="${LTTNG_UST_JAVA_TESTS_GIT_BRANCH:-master}"

        OWD="$(pwd)"
        cd ..
        git clone -b "${LTTNG_UST_JAVA_TESTS_GIT_BRANCH}" "${LTTNG_UST_JAVA_TESTS_GIT_SOURCE}" lttng-ust-java-tests
        cd lttng-ust-java-tests

        LTTNG_UST_JAVA_TESTS_ENV=(
            # Some ci nodes (eg. SLES12) don't have maven distributed by their
            # package manager. As a result, the maven binary is deployed in
            # '/opt/apache/maven/bin'.
            PATH="${WORKSPACE}/build/bin/:$PATH:/opt/apache/maven/bin/"
            LD_LIBRARY_PATH="${WORKSPACE}/build/${LIBDIR}/:${WORKSPACE}/build/${LIBDIR_ARCH}:$LD_LIBRARY_PATH"
            LTTNG_UST_DEBUG=1
            LTTNG_CONSUMERD32_BIN="${WORKSPACE}/build/${LIBDIR_ARCH}/lttng/libexec/lttng-consumerd"
            LTTNG_CONSUMERD64_BIN="${WORKSPACE}/build/${LIBDIR_ARCH}/lttng/libexec/lttng-consumerd"
            LTTNG_SESSION_CONFIG_XSD_PATH="${WORKSPACE}/build/share/xml/lttng"
            BABELTRACE_PLUGIN_PATH="${WORKSPACE}/deps/build/${LIBDIR_ARCH}/babeltrace2/plugins"
            LIBBABELTRACE2_PLUGIN_PROVIDER_DIR="${WORKSPACE}/deps/build/${LIBDIR_ARCH}/babeltrace2/plugin-providers"
        )
        LTTNG_UST_JAVA_TESTS_MAVEN_OPTS=(
            "-Dmaven.test.failure.ignore=true"
            "-Dcommon-jar-location=${WORKSPACE}/deps/build/share/java/lttng-ust-agent-common.jar"
            "-Djul-jar-location=${WORKSPACE}/deps/build/share/java/lttng-ust-agent-jul.jar"
            "-Dlog4j-jar-location=${WORKSPACE}/deps/build/share/java/lttng-ust-agent-log4j.jar"
            "-Dlog4j2-jar-location=${WORKSPACE}/deps/build/share/java/lttng-ust-agent-log4j2.jar"
            "-DargLine=-Djava.library.path=${WORKSPACE}/deps/build/${LIBDIR_ARCH}"
            '-Dgroups=!domain:log4j2'
        )
        env "${LTTNG_UST_JAVA_TESTS_ENV[@]}" mvn -version
        mkdir -p "${WORKSPACE}/log"
        env "${LTTNG_UST_JAVA_TESTS_ENV[@]}" lttng-sessiond -b -vvv 1>"${WORKSPACE}/log/lttng-ust-java-tests-lttng-sessiond.log" 2>&1
        env "${LTTNG_UST_JAVA_TESTS_ENV[@]}" mvn "${LTTNG_UST_JAVA_TESTS_MAVEN_OPTS[@]}" clean verify || exit_status=1
        killall lttng-sessiond

        cd "${OWD}"
    fi
fi

if [ "$LTTNG_TOOLS_RUN_TESTS" = "yes" ] && [[ "$conf" =~ (no-ust|relayd-only) ]]; then
    # The TAP plugin will fail the job if no test logs are present
    mkdir -p "$TAPDIR/no-tests"
    echo "1..1" > "$TAPDIR/no-tests/tests.log"
    echo "ok 1 - Test suite disabled" >> "$TAPDIR/no-tests/tests.log"
fi

# Clean the build directory
if [ "$LTTNG_TOOLS_MAKE_CLEAN" = "yes" ]; then
    print_header "Clean"
    $MAKE clean
fi

print_header "LTTng-tools build script ended with: $(test $exit_status == 0 && echo SUCCESS || echo FAILURE)"

# Exit with failure if any of the tests failed
exit $exit_status

# EOF
# vim: expandtab tabstop=4 shiftwidth=4
