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

    # End the build with failure
    exit 1
}

os_field() {
    field=$1
    if [ -f /etc/os-release ]; then
        echo $(source /etc/os-release; echo ${!field})
    fi
}

os_id() {
    os_field 'ID'
}

os_version_id() {
    os_field 'VERSION_ID'
}

print_header "Liburcu build script starting"

# Required variables
WORKSPACE=${WORKSPACE:-}

# Axis
platform=${platform:-}
conf=${conf:-}
build=${build:-}
cc=${cc:-}

# Build steps that can be overriden by the environment
USERSPACE_RCU_MAKE_INSTALL="${USERSPACE_RCU_MAKE_INSTALL:-yes}"
USERSPACE_RCU_MAKE_CLEAN="${USERSPACE_RCU_MAKE_CLEAN:-yes}"
USERSPACE_RCU_GEN_COMPILE_COMMANDS="${USERSPACE_RCU_GEN_COMPILE_COMMANDS:-no}"
USERSPACE_RCU_RUN_TESTS="${USERSPACE_RCU_RUN_TESTS:-yes}"
USERSPACE_RCU_CLANG_TIDY="${USERSPACE_RCU_CLANG_TIDY:-no}"

SRCDIR="$WORKSPACE/src/liburcu"
TMPDIR="$WORKSPACE/tmp"
PREFIX="/build"
LIBDIR="lib"
LIBDIR_ARCH="$LIBDIR"

CONF_OPTS=()

# RHEL and SLES both use lib64 but don't bother shipping a default autoconf
# site config that matches this.
if [[ ( -f /etc/redhat-release || -f /etc/products.d/SLES.prod || -f /etc/yocto-release ) ]] || [[ "$(os_id)" == "ci" ]]; then
    # Detect the userspace bitness in a distro agnostic way
    if file -L /bin/bash | grep '64-bit' >/dev/null 2>&1; then
        LIBDIR_ARCH="${LIBDIR}64"
    fi
fi

exit_status=0

# Use bear to generate compile_commands.json when enabled
BEAR=""
if [ "$USERSPACE_RCU_GEN_COMPILE_COMMANDS" = "yes" ]; then
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
    export PATH="/opt/local/bin:/opt/local/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    export CPPFLAGS="-I/opt/local/include"
    export LDFLAGS="-L/opt/local/lib"
    export PYTHON="${PYTHON:-python3}"
    export PYTHON_CONFIG="${PYTHON:-python3}-config"
    ;;

freebsd*)
    export MAKE=gmake
    export TAR=tar
    export NPROC="getconf _NPROCESSORS_ONLN"
    export CPPFLAGS="-I/usr/local/include"
    export LDFLAGS="-L/usr/local/lib"
    export PYTHON="${PYTHON:-python3}"
    export PYTHON_CONFIG="${PYTHON:-python3}-config"
    ;;

cygwin*)
    export MAKE=make
    export TAR=tar
    export NPROC=nproc

    # Work around a bug in GCC's emutls on cygwin which results in a deadlock
    # in test_perthreadlock
    CONF_OPTS+=("--disable-compiler-tls")
    ;;

*)
    export MAKE=make
    export TAR=tar
    export NPROC=nproc
    export PYTHON="${PYTHON:-python3}"
    export PYTHON_CONFIG="${PYTHON:-python3}-config"
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
print_header "Bootstrap autotools"
./bootstrap

# Get source version from configure script
eval "$(grep '^PACKAGE_VERSION=' ./configure)"
PACKAGE_VERSION=${PACKAGE_VERSION//\-pre*/}

# Set configure options and environment variables for each build
# configuration.
CONF_OPTS+=("--prefix=$PREFIX" "--libdir=$PREFIX/$LIBDIR_ARCH" "--disable-maintainer-mode")
case "$conf" in
static)
    print_header "Conf: Static lib only"

    CONF_OPTS+=("--enable-static" "--disable-shared")
    ;;

tls_fallback)
    print_header  "Conf: Use pthread_getspecific() to emulate TLS"

    CONF_OPTS+=("--disable-compiler-tls")
    ;;

debug-rcu)
    print_header "Conf: Enable RCU sanity checks for debugging"

    if vergte "$PACKAGE_VERSION" "0.10"; then
       CONF_OPTS+=("--enable-rcu-debug")
    else
       export CFLAGS="$CFLAGS -DDEBUG_RCU"
    fi

    echo "Enable iterator sanity validator"
    if vergte "$PACKAGE_VERSION" "0.11"; then
       CONF_OPTS+=("--enable-cds-lfht-iter-debug")
    fi
    ;;

atomic-builtins)
    print_header  "Conf: Enable the use of compiler atomic builtins."

    CONF_OPTS+=("--enable-compiler-atomic-builtins")
    ;;

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
oot)
    print_header "Build: Out of tree"

    # Create and enter a temporary build directory
    builddir=$(mktemp_compat -d)
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
    builddir=$(mktemp_compat -d)
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
    builddir=$(mktemp_compat -d)
    cd "$builddir"

    # Run configure out of tree and generate the tar file
    "$SRCDIR/configure" || failed_configure
    $MAKE dist

    dist_srcdir="$(mktemp_compat -d)"
    cd "$dist_srcdir"

    # Extract the distribution tar in the new source directory,
    # ignore the first directory level
    $TAR xvf "$builddir"/*.tar.* --strip 1

    # Create and enter a second temporary build directory
    builddir="$(mktemp_compat -d)"
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
if [ "$USERSPACE_RCU_MAKE_INSTALL" = "yes" ]; then
    print_header "Install"

    $MAKE install V=1 DESTDIR="$WORKSPACE"

    # Cleanup rpath in executables and shared libraries
    #find "$WORKSPACE/$PREFIX/bin" -type f -perm -0500 -exec chrpath --delete {} \;
    find "$WORKSPACE/$PREFIX/$LIBDIR_ARCH" -name "*.so" -exec chrpath --delete {} \;

    # Remove libtool .la files
    find "$WORKSPACE/$PREFIX/$LIBDIR_ARCH" -name "*.la" -delete
fi

# Run clang-tidy on the topmost commit
if [ "$USERSPACE_RCU_CLANG_TIDY" = "yes" ]; then
    print_header "Run clang-tidy"

    # This would be better by linting only the lines touched by a patch but it
    # doesn't seem to work, the lines are always filtered and no error is
    # reported.
    #git diff -U0 HEAD^ | clang-tidy-diff -p1 -j "$($NPROC)" -timeout 60 -fix

    # Instead, run clan-tidy on all the files touched by the patch.
    while read -r filepath; do
        if [[ "$filepath" =~ (\.cpp|\.hpp|\.c|\.h)$ ]]; then
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
if [ "$USERSPACE_RCU_RUN_TESTS" = "yes" ]; then
    print_header "Run test suite"

    # Run tests, don't fail now, we want to run the archiving steps
    $MAKE --keep-going check || exit_status=1

    # Only run regtest for 0.9 and up
    if vergte "$PACKAGE_VERSION" "0.9"; then
       $MAKE --keep-going regtest || exit_status=1
    fi

    # Copy tap logs for the jenkins tap parser before cleaning the build dir
    rsync -a --exclude 'test-suite.log' --include '*/' --include '*.log' --exclude='*' tests/ "$WORKSPACE/tap"

    # Copy the test suites top-level log which includes all tests failures
    rsync -a --include 'test-suite.log' --include '*/' --exclude='*' tests/ "$WORKSPACE/log"

    # The test suite prior to 0.11 did not produce TAP logs
    if verlt "$PACKAGE_VERSION" "0.11"; then
        mkdir -p "$WORKSPACE/tap/no-log"
        echo "1..1" > "$WORKSPACE/tap/no-log/tests.log"
        echo "ok 1 - Test suite doesn't support logging" >> "$WORKSPACE/tap/no-log/tests.log"
    fi
fi

# Clean the build directory
if [ "$USERSPACE_RCU_MAKE_CLEAN" = "yes" ]; then
    print_header "Clean"
    $MAKE clean
fi

print_header "Liburcu build script ended with: $(test $exit_status == 0 && echo SUCCESS || echo FAILURE)"

# Exit with failure if any of the tests failed
exit $exit_status

# EOF
# vim: expandtab tabstop=4 shiftwidth=4
