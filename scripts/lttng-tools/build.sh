#!/bin/bash -exu
#
# Copyright (C) 2016 - Jonathan Rajotte-Julien <jonathan.rajotte-julien@efficios.com>
#                      Michael Jeanson <mjeanson@efficios.com>
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
test_type=${test_type:-}

SRCDIR="$WORKSPACE/src/lttng-tools"
#TMPDIR="$WORKSPACE/tmp"
PREFIX="$WORKSPACE/build"
TAPDIR="$WORKSPACE/tap"


# Create build and tmp directories
rm -rf "$PREFIX" "$TAPDIR"
mkdir -p "$PREFIX" "$TAPDIR"

#export TMPDIR
CFLAGS="-g -O2"

# liburcu
URCU_INCS="$WORKSPACE/deps/liburcu/build/include/"
URCU_LIBS="$WORKSPACE/deps/liburcu/build/lib/"

# lttng-ust
UST_INCS="$WORKSPACE/deps/lttng-ust/build/include/"
UST_LIBS="$WORKSPACE/deps/lttng-ust/build/lib/"
UST_JAVA="$WORKSPACE/deps/lttng-ust/build/share/java/"

# babeltrace
#BABEL_INCS="$WORKSPACE/deps/babeltrace/build/include/"
BABEL_LIBS="$WORKSPACE/deps/babeltrace/build/lib/"
BABEL_BINS="$WORKSPACE/deps/babeltrace/build/bin/"

# pgrep
PGREP=pgrep

# Set platform variables
case "$arch" in
sol10-i386)
    MAKE=gmake
    TAR=gtar
    NPROC=gnproc
    BISON="bison"
    YACC="$BISON -y"
    CFLAGS="${CFLAGS:-} -D_XOPEN_SOURCE=500"
    RUN_TESTS="no"

    export PATH="/opt/csw/bin:/usr/ccs/bin:$PATH"
    ;;

sol11-i386)
    MAKE=gmake
    TAR=gtar
    NPROC=nproc
    BISON="bison"
    YACC="$BISON -y"
    CFLAGS="${CFLAGS:-} -D_XOPEN_SOURCE=500"
    RUN_TESTS="no"

    export PATH="$PATH:/usr/perl5/bin"
    CPPFLAGS="-I/opt/csw/include"
    LDFLAGS="-L/opt/csw/lib"
    ;;

macosx)
    MAKE=make
    TAR=tar
    NPROC="getconf _NPROCESSORS_ONLN"
    BISON="bison"
    YACC="$BISON -y"
    RUN_TESTS="no"

    export PATH="/opt/local/bin:/opt/local/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    CPPFLAGS="-I/opt/local/include"
    LDFLAGS="-L/opt/local/lib"
    ;;

cygwin|cygwin64|msys32|msys64)
    MAKE=make
    TAR=tar
    NPROC=nproc
    BISON="bison"
    YACC="$BISON -y"
    #CFLAGS=""
    RUN_TESTS="no"
    ;;

*)
    MAKE=make
    TAR=tar
    NPROC=nproc
    BISON="bison"
    YACC="$BISON -y"
    #CFLAGS=""
    RUN_TESTS="yes"

    PYTHON2=python2
    PYTHON3=python3

    P2_VERSION=$($PYTHON2 -c "import sys;print(sys.version[:3])")
    P3_VERSION=$($PYTHON3 -c "import sys;print(sys.version[:3])")

    UST_PYTHON2="$WORKSPACE/deps/lttng-ust/build/lib/python$P2_VERSION/site-packages"
    UST_PYTHON3="$WORKSPACE/deps/lttng-ust/build/lib/python$P3_VERSION/site-packages"
    ;;
esac

case "$test_type" in
base)
	RUN_TESTS_LONG_REGRESSION="no"
	;;
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
PACKAGE_VERSION=$(echo "$PACKAGE_VERSION"| sed 's/\-pre$//')


# Export build flags
case "$conf" in
no-ust)
    CPPFLAGS="${CPPFLAGS:-} -I$URCU_INCS"
    LDFLAGS="${LDFLAGS:-} -L$URCU_LIBS"
    export LD_LIBRARY_PATH="$URCU_LIBS:$BABEL_LIBS:${LD_LIBRARY_PATH:-}"
    ;;

*)
    CPPFLAGS="${CPPFLAGS:-} -I$URCU_INCS -I$UST_INCS"
    LDFLAGS="${LDFLAGS:-} -L$URCU_LIBS -L$UST_LIBS"
    export LD_LIBRARY_PATH="$URCU_LIBS:$UST_LIBS:$BABEL_LIBS:${LD_LIBRARY_PATH:-}"
    ;;
esac

# The switch to build without UST changed in 2.8
if vergte "$PACKAGE_VERSION" "2.8"; then
    NO_UST="--without-lttng-ust"
else
    NO_UST="--disable-lttng-ust"
fi

# Most build configs require the python bindings
CONF_OPTS="--enable-python-bindings"
export PYTHON="python3"
export PYTHON_CONFIG="/usr/bin/python3-config"

# Set configure options for each build configuration
case "$conf" in
static)
    echo "Static build"
    CONF_OPTS+=" --enable-static --disable-shared"
    ;;

no-ust)
    echo "Build without UST support"
    CONF_OPTS+=" $NO_UST"
    ;;

agents)
    echo "Enable Java Agents"
    export JAVA_HOME="/usr/lib/jvm/default-java"
    export CLASSPATH="$UST_JAVA/*:/usr/share/java/*"
    CONF_OPTS+=" --enable-test-java-agent-all"

    echo "Enable Python agents"
    export PYTHONPATH="$UST_PYTHON2:$UST_PYTHON3"
    CONF_OPTS+=" --enable-test-python-agent-all"
    ;;

relayd-only)
    echo "Build relayd only"
    CONF_OPTS="--disable-bin-lttng --disable-bin-lttng-consumerd --disable-bin-lttng-crash --disable-bin-lttng-sessiond --disable-extras --disable-man-pages $NO_UST"
    ;;

debug-rcu)
    echo "Enable RCU sanity checks for debugging"
    CPPFLAGS="${CPPFLAGS:-} -DDEBUG_RCU"
    ;;

*)
    echo "Standard build"
    ;;
esac


# Build type
# oot     : out-of-tree build
# dist    : build via make dist
# oot-dist: build via make dist out-of-tree
# *       : normal tree build
#
# Make sure to move to the build_path and run configure
# before continuing
BUILD_PATH=$SRCDIR
case "$build" in
    oot)
        echo "Out of tree build"
        BUILD_PATH=$WORKSPACE/oot
        mkdir -p "$BUILD_PATH"
        cd "$BUILD_PATH"
        MAKE=$MAKE BISON="$BISON" YACC="$YACC" CFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS" CPPFLAGS="$CPPFLAGS" "$SRCDIR/configure" --prefix="$PREFIX" $CONF_OPTS
        ;;

    dist)
        echo "Distribution tarball in-tree build"

        # Initial configure and generate tarball
        MAKE=$MAKE BISON="$BISON" YACC="$YACC" CFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS" CPPFLAGS="$CPPFLAGS" "$SRCDIR/configure" $CONF_OPTS --enable-build-man-pages
        $MAKE dist

        BUILD_PATH="$(mktemp -d)"
        cp ./*.tar.* "$BUILD_PATH/"
        cd "$BUILD_PATH"

        # Ignore level 1 of tar
        $TAR xvf ./*.tar.* --strip 1

        # Build in extracted source tree
        MAKE=$MAKE BISON="$BISON" YACC="$YACC" CFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS" CPPFLAGS="$CPPFLAGS" "$BUILD_PATH/configure" --prefix="$PREFIX" $CONF_OPTS
        ;;

    oot-dist)
        echo "Distribution tarball out of tree build"
        BUILD_PATH="$(mktemp -d)"
        cd "$BUILD_PATH"

        # Initial configure and generate tarball
        MAKE=$MAKE BISON="$BISON" YACC="$YACC" CFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS" CPPFLAGS="$CPPFLAGS" "$SRCDIR/configure" $CONF_OPTS --enable-build-man-pages
        $MAKE dist

        NEWSRC_PATH="$(mktemp -d)"
        cp ./*.tar.* "$NEWSRC_PATH/"
        cd "$NEWSRC_PATH"

        # Ignore level 1 of tar
        $TAR xvf ./*.tar.* --strip 1

        BUILD_PATH="$(mktemp -d)"
        cd "$BUILD_PATH"

        # Build oot from extracted sources
        MAKE=$MAKE BISON="$BISON" YACC="$YACC" CFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS" CPPFLAGS="$CPPFLAGS" "$NEWSRC_PATH/configure" --prefix="$PREFIX" $CONF_OPTS
        ;;

    *)
        echo "Standard tree build"
        MAKE=$MAKE BISON="$BISON" YACC="$YACC" CFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS" CPPFLAGS="$CPPFLAGS" "$BUILD_PATH/configure" --prefix="$PREFIX" $CONF_OPTS
        ;;
esac

# BUILD!
$MAKE -j "$($NPROC)" V=1
$MAKE install

# Run tests
if [ "$RUN_TESTS" = "yes" ]; then
    cd tests || exit 1

    # Allow core dumps
    ulimit -c unlimited

    # Kill any LTTng-related process
    lttng_processes="$("$PGREP" -l 'lttng|gen-ust-.+')"
    if [ $? -eq 0 ]; then
        echo "The following LTTng processes were detected running on the system and will be killed:"
        echo "$lttng_processes"

        pids="$(cut -d ' ' -f 1 <<< "$lttng_processes" | tr '\n' ' ')"
        kill -SIGKILL $pids
    fi

    # Add 'babeltrace' binary to PATH
    chmod +x "$BABEL_BINS/babeltrace"
    export PATH="$PATH:$BABEL_BINS"

    # Prepare tap output dirs
    rm -rf "$TAPDIR"
    mkdir -p "$TAPDIR"
    mkdir -p "$TAPDIR/unit"
    mkdir -p "$TAPDIR/fast_regression"
    mkdir -p "$TAPDIR/with_bindings_regression"
    if [ "$RUN_TESTS_LONG_REGRESSION" = "yes" ]; then
        mkdir -p "$TAPDIR/long_regression"
    fi

    # Force the lttng-sessiond path to /bin/true to prevent the spawing of a
    # lttng-sessiond --daemonize on "lttng create"
    export LTTNG_SESSIOND_PATH="/bin/true"

    # Run 'unit_tests' and 'fast_regression' test suites for all configs except 'no-ust'
    if [ "$conf" != "no-ust" ]; then
        # Run 'unit_tests', 2.8 and up has a new test suite
        if vergte "$PACKAGE_VERSION" "2.8"; then
            make --keep-going check
            rsync -a --exclude 'test-suite.log' --include '*/' --include '*.log' --exclude='*'" $BUILD_PATH/tests/" "$TAPDIR"
        else
            prove --merge -v --exec '' - < "$BUILD_PATH/tests/unit_tests" --archive "$TAPDIR/unit/" || true
            prove --merge -v --exec '' - < "$BUILD_PATH/tests/fast_regression" --archive "$TAPDIR/fast_regression/" || true
            prove --merge -v --exec '' - < "$BUILD_PATH/tests/with_bindings_regression" --archive "$TAPDIR/with_bindings_regression/" || true
        fi
        if [ "$RUN_TESTS_LONG_REGRESSION" = "yes" ]; then
            prove --merge -v --exec '' - < "$BUILD_PATH/tests/long_regression" --archive "$TAPDIR/long_regression/" || true
        fi
    else
        # Regression is disabled for now, we need to adjust the testsuite for no ust builds.
        echo "Tests disabled for 'no-ust'."
    fi

    # TAP plugin is having a hard time with .yml files.
    find "$TAPDIR" -name "meta.yml" -exec rm -f {} \;

    # And also with files without extension, so rename all result to *.tap
    find "$TAPDIR/" -type f -exec mv {} {}.tap \;

    cd -
fi

# Cleanup
$MAKE clean

# Cleanup rpath in executables and shared libraries
find "$PREFIX/bin" -type f -perm -0500 -exec chrpath --delete {} \;
find "$PREFIX/lib" -name "*.so" -exec chrpath --delete {} \;

# Remove libtool .la files
find "$PREFIX/lib" -name "*.la" -exec rm -f {} \;

# Clean temp dir for dist build
if [ "$build" = "dist" ]; then
    cd "$SRCDIR"
    rm -rf "$BUILD_PATH"
fi

# EOF
