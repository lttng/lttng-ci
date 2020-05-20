#!/bin/bash -exu
#
# Copyright (C) 2015 Jonathan Rajotte-Julien <jonathan.rajotte-julien@efficios.com>
# Copyright (C) 2020 Michael Jeanson <mjeanson@efficios.com>
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

export TERM="xterm-256color"

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

export JAVA_HOME="/usr/lib/jvm/default-java"
export CLASSPATH="$DEPS_JAVA/*:/usr/share/java/*"

SRCDIR="$WORKSPACE/src/lttng-tools"
TAPDIR="$WORKSPACE/tap"
PREFIX="$WORKSPACE/out"

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

PYTHON2=python2
PYTHON3=python3

# Set default python to python3 for the bindings
export PYTHON="$PYTHON3"
export PYTHON_CONFIG="/usr/bin/$PYTHON3-config"

P2_VERSION=$($PYTHON2 -c "import sys;print(sys.version[:3])")
P3_VERSION=$($PYTHON3 -c "import sys;print(sys.version[:3])")

UST_PYTHON2="$WORKSPACE/deps/build/lib/python$P2_VERSION/site-packages"
UST_PYTHON3="$WORKSPACE/deps/build/lib/python$P3_VERSION/site-packages"

export PYTHONPATH="$UST_PYTHON2:$UST_PYTHON3"



# Create build and tmp directories
rm -rf "$PREFIX"
mkdir -p "$PREFIX"




# Enter the source directory
cd "$SRCDIR"

# Run bootstrap in the source directory prior to configure
./bootstrap

# Get source version from configure script
eval "$(grep '^PACKAGE_VERSION=' ./configure)"

TARBALL_FILE="lttng-tools-$PACKAGE_VERSION.tar.bz2"

# Make sure the reported version matches the current git tag
GIT_TAG="$(git describe --exact-match --tags $(git log -n1 --pretty='%h')|| echo 'undefined')"

if [ "v$PACKAGE_VERSION" != "$GIT_TAG" ]; then
  echo "Git checkout is not tagged or doesn't match the reported version."
  exit 1
fi

# Generate release tarball
./configure
make dist
cp "./$TARBALL_FILE" "$PREFIX/"


# Allow core dumps
ulimit -c unlimited

# Force the lttng-sessiond path to /bin/true to prevent the spawing of a
# lttng-sessiond --daemonize on "lttng create"
export LTTNG_SESSIOND_PATH="/bin/true"


# Do an in-tree test build
mkdir "$WORKSPACE/intree"
cd "$WORKSPACE/intree" || exit 1
tar xvf "$PREFIX/$TARBALL_FILE" --strip 1
./configure --prefix="$(mktemp -d)" --enable-python-bindings --enable-test-java-agent-all --enable-test-python-agent-all
make -j "$(nproc)" V=1
make check
make install
make clean

# do an out-of-tree test build
mkdir "$WORKSPACE/oot"
mkdir "$WORKSPACE/oot/src"
mkdir "$WORKSPACE/oot/build"
cd "$WORKSPACE/oot/src" || exit 1
tar xvf "$PREFIX/$TARBALL_FILE" --strip 1
cd "$WORKSPACE/oot/build" || exit 1
"$WORKSPACE/oot/src/configure" --prefix="$(mktemp -d)" --enable-python-bindings --enable-test-java-agent-all --enable-test-python-agent-all
make -j "$(nproc)" V=1
make check
make install
make clean

# EOF
