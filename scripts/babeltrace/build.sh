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

# Shellcheck flags the following functions that are unused as "unreachable",
# ignore that.

# shellcheck disable=SC2317
verlte() {
    vercomp "$1" "$2"
    local res="$?"
    [ "$res" -eq "0" ] || [ "$res" -eq "2" ]
}

# shellcheck disable=SC2317
verlt() {
    vercomp "$1" "$2"; local res="$?"
    [ "$res" -eq "2" ]
}

# shellcheck disable=SC2317
vergte() {
    vercomp "$1" "$2"; local res="$?"
    [ "$res" -eq "0" ] || [ "$res" -eq "1" ]
}

# shellcheck disable=SC2317
vergt() {
    vercomp "$1" "$2"; local res="$?"
    [ "$res" -eq "1" ]
}

# shellcheck disable=SC2317
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
    exit 1
}

print_header "Babeltrace build script starting"

# Required variables
WORKSPACE=${WORKSPACE:-}

# Axis
platform=${platform:-}
conf=${conf:-}
build=${build:-}
cc=${cc:-}

# Build steps that can be overriden by the environment
BABELTRACE_MAKE_INSTALL="${BABELTRACE_MAKE_INSTALL:-yes}"
BABELTRACE_MAKE_CLEAN="${BABELTRACE_MAKE_CLEAN:-yes}"
BABELTRACE_GEN_COMPILE_COMMANDS="${BABELTRACE_GEN_COMPILE_COMMANDS:-no}"
BABELTRACE_RUN_TESTS="${BABELTRACE_RUN_TESTS:-yes}"
BABELTRACE_CLANG_TIDY="${BABELTRACE_CLANG_TIDY:-no}"

SRCDIR="$WORKSPACE/src/babeltrace"
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
if [ "$BABELTRACE_GEN_COMPILE_COMMANDS" = "yes" ]; then
	BEAR="bear"
fi

# Create tmp directory
rm -rf "$TMPDIR"
mkdir -p "$TMPDIR"

export TMPDIR
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
        echo ""
        exit 1
    fi
    ;;
esac

# Set platform variables
case "$platform" in
macos*)
    export MAKE=make
    export TAR=tar
    export NPROC="getconf _NPROCESSORS_ONLN"
    export PATH="/opt/local/bin:/opt/local/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    export CFLAGS="$CFLAGS -Wno-\#pragma-messages" # Fix warnings with clang14
    export CPPFLAGS="-I/opt/local/include"
    export LDFLAGS="-L/opt/local/lib"
    export PYTHON="python3"
    export PYTHON_CONFIG="python3-config"
    ;;

freebsd*)
    export MAKE=gmake
    export TAR=tar
    export NPROC="getconf _NPROCESSORS_ONLN"
    export CPPFLAGS="-I/usr/local/include"
    export LDFLAGS="-L/usr/local/lib"
    export PYTHON="python3"
    export PYTHON_CONFIG="python3-config"

    # For bt 1.5
    export YACC="bison -y"
    ;;

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

# Enable dev mode by default for BT 2.0 builds
export BABELTRACE_DEBUG_MODE=1
export BABELTRACE_DEV_MODE=1
export BABELTRACE_MINIMAL_LOG_LEVEL=TRACE

# Set configure options and environment variables for each build
# configuration.
CONF_OPTS=("--prefix=$PREFIX" "--libdir=$PREFIX/$LIBDIR_ARCH" "--disable-maintainer-mode")

# -Werror is enabled by default in stable-2.0 but won't be in 2.1
# Explicitly disable it for consistency.
if vergte "$PACKAGE_VERSION" "2.0"; then
    CONF_OPTS+=("--disable-Werror")
fi

case "$conf" in
static)
    print_header "Conf: Static lib only"

    CONF_OPTS+=("--enable-static" "--disable-shared")

    if vergte "$PACKAGE_VERSION" "2.0"; then
        CONF_OPTS+=("--enable-built-in-plugins")
    fi
    ;;

python-bindings)
    print_header "Conf: Python bindings"

    CONF_OPTS+=("--enable-python-bindings")

    if vergte "$PACKAGE_VERSION" "2.0"; then
        CONF_OPTS+=("--enable-python-bindings-doc" "--enable-python-plugins")
    fi
    ;;

prod)
    print_header "Conf: Production"

    # Unset the developper variables
    unset BABELTRACE_DEBUG_MODE
    unset BABELTRACE_DEV_MODE
    unset BABELTRACE_MINIMAL_LOG_LEVEL

    # Enable the python bindings
    CONF_OPTS+=("--enable-python-bindings" "--enable-python-plugins")
    ;;

doc)
    print_header "Conf: Documentation"

    CONF_OPTS+=("--enable-python-bindings" "--enable-python-bindings-doc" "--enable-python-plugins" "--enable-api-doc")
    ;;

asan)
    print_header "Conf: Address Sanitizer"

    # --enable-asan was introduced after 2.0 but don't check the version, we
    # want this configuration to fail if ASAN is unavailable.
    CONF_OPTS+=("--enable-asan" "--enable-python-bindings" "--enable-python-plugins")
    ;;

min)
    print_header "Conf: Minimal"
    ;;

*)
    print_header "Conf: Standard"

    # Enable the python bindings / plugins by default with babeltrace2,
    # the test suite is mostly useless without it.
    if vergte "$PACKAGE_VERSION" "2.0"; then
        CONF_OPTS+=("--enable-python-bindings" "--enable-python-plugins")
    fi

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
if [ "$BABELTRACE_MAKE_INSTALL" = "yes" ]; then
    print_header "Install"

    $MAKE install V=1 DESTDIR="$WORKSPACE"

    # Cleanup rpath in executables and shared libraries
    find "$WORKSPACE/$PREFIX/bin" -type f -perm -0500 -exec chrpath --delete {} \;
    find "$WORKSPACE/$PREFIX/$LIBDIR_ARCH" -name "*.so" -exec chrpath --delete {} \;

    # Remove libtool .la files
    find "$WORKSPACE/$PREFIX/$LIBDIR_ARCH" -name "*.la" -delete
fi

# Run clang-tidy on the topmost commit
if [ "$BABELTRACE_CLANG_TIDY" = "yes" ]; then
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

# Run tests if enabled
if [ "$BABELTRACE_RUN_TESTS" = "yes" ]; then
    print_header "Run test suite"

    # Run tests, don't fail now, we want to run the archiving steps
    $MAKE --keep-going check || exit_status=1

    # Copy tap logs for the jenkins tap parser before cleaning the build dir
    rsync -a --exclude 'test-suite.log' --include '*/' --include '*.log' --exclude='*' tests/ "$WORKSPACE/tap"

    # Copy the test suites top-level log which includes all tests failures
    rsync -a --include 'test-suite.log' --include '*/' --exclude='*' tests/ "$WORKSPACE/log"
fi

# Clean the build directory
if [ "$BABELTRACE_MAKE_CLEAN" = "yes" ]; then
    print_header "Clean"
    $MAKE clean
fi

print_header "Babeltrace build script ended with: $(test $exit_status == 0 && echo SUCCESS || echo FAILURE)"

# Exit with failure if any of the tests failed
exit $exit_status

# EOF
# vim: expandtab tabstop=4 shiftwidth=4
