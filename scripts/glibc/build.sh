#!/bin/bash
#
# SPDX-FileCopyrightText: 2015 Jonathan Rajotte-Julien <jonathan.rajotte-julien@efficios.com>
# SPDX-FileCopyrightText: 2016-2023 Michael Jeanson <mjeanson@efficios.com>
# SPDX-License-Identifier: GPL-2.0-or-later

set -exu

mktemp_compat() {
    case "$platform" in
        macos*)
            # On MacOSX, mktemp doesn't respect TMPDIR in the same way as many
            # other systems. Use the final positional argument to force the
            # tempfile or tempdir to be created inside $TMPDIR, which must
            # already exist.
            if [ -n "${TMPDIR}" ] ; then
                mktemp "${@}" "${TMPDIR}/tmp.XXXXXXXXXX"
            else
                mktemp "${@}"
            fi
        ;;
        *)
            mktemp "${@}"
        ;;
    esac
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

print_header "Glibc build script starting"

# Required variables
WORKSPACE=${WORKSPACE:-}

# Axis
platform=${platform:-}
conf=${conf:-}
build=${build:-}
cc=${cc:-}

# Build steps that can be overriden by the environment
GLIBC_MAKE_INSTALL="${GLIBC_MAKE_INSTALL:-no}"
GLIBC_MAKE_CLEAN="${GLIBC_MAKE_CLEAN:-no}"
GLIBC_GEN_COMPILE_COMMANDS="${GLIBC_GEN_COMPILE_COMMANDS:-no}"
GLIBC_GIT_UNTRACKED="${GLIBC_GIT_UNTRACKED:-no}"
GLIBC_RUN_TESTS="${GLIBC_RUN_TESTS:-yes}"

SRCDIR="$WORKSPACE/src/glibc"
TMPDIR="$WORKSPACE/tmp"
PREFIX="/usr"
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
if [ "$GLIBC_GEN_COMPILE_COMMANDS" = "yes" ]; then
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
print_hardware || true
print_os || true
print_tooling || true

# Enter the source directory
cd "$SRCDIR"

# Run bootstrap in the source directory prior to configure
#print_header "Bootstrap autotools"
#./bootstrap

# Set configure options and environment variables for each build
# configuration.
CONF_OPTS=("--prefix=$PREFIX" "--libdir=$PREFIX/$LIBDIR_ARCH" "--disable-maintainer-mode")

case "$conf" in
*)
    print_header "Conf: Standard"
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
*)
    print_header "Build: Out of tree"

    # Create and enter a temporary build directory
    builddir=$(mktemp_compat -d)
    cd "$builddir"

    "$SRCDIR/configure" "${CONF_OPTS[@]}" || failed_configure
    ;;
esac

# We are now inside a configured build directory

# BUILD!
print_header "BUILD!"
$BEAR ${BEAR:+--} $MAKE -j "$($NPROC)" V=1

# Install in the workspace if enabled
if [ "$GLIBC_MAKE_INSTALL" = "yes" ]; then
    print_header "Install"

    $MAKE install V=1 DESTDIR="$WORKSPACE"
fi

# Run tests if enabled
if [ "$GLIBC_RUN_TESTS" = "yes" ]; then
    print_header "Run test suite"

    # Run tests, don't fail now, we want to run the archiving steps
    $MAKE --keep-going check || exit_status=1

    # Copy tap logs for the jenkins tap parser before cleaning the build dir
    rsync -a --exclude 'test-suite.log' --include '*/' --include '*.log' --exclude='*' tests/ "$WORKSPACE/tap"

    # Copy the test suites top-level log which includes all tests failures
    rsync -a --include 'test-suite.log' --include '*/' --exclude='*' tests/ "$WORKSPACE/log"
fi

if [ "$GLIBC_GIT_UNTRACKED" = "yes" ]; then
    # Check that the git repository has no untracked files, meaning that
    # .gitignore is not missing anything.
    pushd "$SRCDIR"

    git_status_output=$(git status --short)
    if [ -n "$git_status_output" ]; then
        echo "Error: There are untracked or modified files in the repository:"
        echo "$git_status_output"
        exit_status=1
    else
        echo "No untracked or modified files."
    fi

    popd
fi

# Clean the build directory
if [ "$GLIBC_MAKE_CLEAN" = "yes" ]; then
    print_header "Clean"
    $MAKE clean
fi

print_header "Glibc build script ended with: $(test $exit_status == 0 && echo SUCCESS || echo FAILURE)"

# Exit with failure if any of the tests failed
exit $exit_status

# EOF
# vim: expandtab tabstop=4 shiftwidth=4
