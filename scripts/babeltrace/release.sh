#!/bin/bash
#
# Copyright (C) 2015 Jonathan Rajotte-Julien <jonathan.rajotte-julien@efficios.com>
# Copyright (C) 2023 Michael Jeanson <mjeanson@efficios.com>
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

# Required variables
WORKSPACE=${WORKSPACE:-}


SRCDIR="$WORKSPACE/src/babeltrace"
TMPDIR="$WORKSPACE/tmp"
OUTDIR="$WORKSPACE/out"
TAPDIR="$WORKSPACE/tap"

failed_tests=0

# Create build and tmp directories
rm -rf "$OUTDIR" "$TMPDIR" "$TAPDIR"
mkdir -p "$OUTDIR" "$TMPDIR" "$TAPDIR"

export TMPDIR


# Enter the source directory
cd "$SRCDIR"

# Run bootstrap in the source directory prior to configure
./bootstrap

# Get source version from configure script
eval "$(grep '^PACKAGE_VERSION=' ./configure)"
PACKAGE_VERSION=${PACKAGE_VERSION//\-pre*/}

# Version specific configurations
if vergte "$PACKAGE_VERSION" "2.0"; then
  BASENAME="babeltrace2"
  CONF_OPTS=("--enable-python-bindings" "--enable-python-bindings-doc" "--enable-python-plugins" "--disable-Werror")

  # Enable dev mode by default for BT 2.0 builds
  #export BABELTRACE_DEBUG_MODE=1
  #export BABELTRACE_DEV_MODE=1
  #export BABELTRACE_MINIMAL_LOG_LEVEL=TRACE
else
  BASENAME="babeltrace"
  CONF_OPTS=("--enable-python-bindings")
fi


TARBALL_FILE="$BASENAME-$PACKAGE_VERSION.tar.bz2"


# Make sure the reported version matches the current git tag
GIT_TAG="$(git describe --exact-match --tags "$(git log -n1 --pretty='%h')" || echo 'undefined')"

if [ "v$PACKAGE_VERSION" != "$GIT_TAG" ]; then
  echo "Git checkout is not tagged or doesn't match the reported version."
  exit 1
fi

# Generate release tarball
./configure
make dist
cp "./$TARBALL_FILE" "$OUTDIR/"

## Do an in-tree test build
mkdir "$WORKSPACE/intree"
cd "$WORKSPACE/intree" || exit 1

tar xvf "$OUTDIR/$TARBALL_FILE" --strip 1
./configure --prefix="$(mktemp -d)" "${CONF_OPTS[@]}"

# BUILD!
make -j "$(nproc)" V=1

make install

# Run tests, don't fail now, we want to run the archiving steps
make --keep-going check || failed_tests=1

# Copy tap logs for the jenkins tap parser before cleaning the build dir
rsync -a --exclude 'test-suite.log' --include '*/' --include '*.log' --exclude='*' tests/ "$TAPDIR/intree"

# Clean the build directory
make clean


## Do an out-of-tree test build
mkdir "$WORKSPACE/oot"
mkdir "$WORKSPACE/oot/src"
mkdir "$WORKSPACE/oot/build"
cd "$WORKSPACE/oot/src" || exit 1

tar xvf "$OUTDIR/$TARBALL_FILE" --strip 1
cd "$WORKSPACE/oot/build" || exit 1
"$WORKSPACE/oot/src/configure" --prefix="$(mktemp -d)" "${CONF_OPTS[@]}"

# BUILD!
make -j "$(nproc)" V=1

make install

# Run tests, don't fail now, we want to run the archiving steps
make --keep-going check || failed_tests=1

# Copy tap logs for the jenkins tap parser before cleaning the build dir
rsync -a --exclude 'test-suite.log' --include '*/' --include '*.log' --exclude='*' tests/ "$TAPDIR/oot"

# Clean the build directory
make clean


# Exit with failure if any of the tests failed
exit $failed_tests

# EOF
