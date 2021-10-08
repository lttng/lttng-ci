#!/bin/bash
#
# Copyright (C) 2021 Michael Jeanson <mjeanson@efficios.com>
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

failed_configure() {
    # Assume we are in the configured build directory
    echo "#################### BEGIN config.log ####################"
    cat config.log
    echo "#################### END config.log ####################"
    exit 1
}

sum2junit() {
    local infile="$1"
    local outfile="$2"

    local tool
    local skipped
    local passes
    local failures
    local total
    local s2jtmpfile

    local result
    local name
    local message

    set +x

    tool=$(grep "tests ===" "$infile" | tr -s ' ' | cut -d ' ' -f 2)

    # Get the counts for tests that didn't work properly
    skipped=$(grep -E -c '^UNRESOLVED|^UNTESTED|^UNSUPPORTED' "$infile" || true)
    if test x"${skipped}" = x; then
        skipped=0
    fi

    # The total of successful results are PASS and XFAIL
    passes=$(grep -E -c '^PASS|XFAIL' "$infile" || true)
    if test x"${passes}" = x; then
        passes=0
    fi

    # The total of failed results are FAIL and XPASS
    failures=$(grep -E -c '^FAIL|XPASS' "$infile" || true)
    if test x"${failures}" = x; then
        failures=0
    fi

    # Calculate the total number of test cases
    total=$((passes + failures))
    total=$((total + skipped))

    cat <<EOF > "$outfile"
<?xml version="1.0"?>

<testsuites>
<testsuite name="DejaGnu" tests="${total}" failures="${failures}" skipped="${skipped}">

EOF

    s2jtmpfile="$(mktemp)"
    grep -E 'PASS|XPASS|FAIL|UNTESTED|UNSUPPORTED|UNRESOLVED' "$infile" > "$s2jtmpfile" || true

    while read -r line
    do
        echo -n "."
        result=$(echo "$line" | cut -d ' ' -f 1 | tr -d ':')
        name=$(echo "$line" | cut -d ' ' -f 2 | tr -d '\"><;:\[\]^\\&?@')
        message=$(echo "$line" | cut -d ' ' -f 3-50 | tr -d '\"><;:\[\]^\\&?@')

        echo "    <testcase name=\"${name}\" classname=\"${tool}-${result}\">" >> "$outfile"
        case "${result}" in
        PASS|XFAIL|KFAIL)
            # No message for successful tests in junit
            ;;
        UNSUPPORTED|UNTESTED)
    	    if test x"${message}" != x; then
    		echo -n "        <skipped message=\"${message}\"/>" >> "$outfile"
    	    else
    		echo -n "        <skipped type=\"$result\"/>" >> "$outfile"
    	    fi
    	    ;;
    	XPASS|UNRESOLVED|DUPLICATE)
    	    echo -n "        <failure message=\"$message\"/>" >> "$outfile"
    	    ;;
    	*)
    	    echo -n "        <failure message=\"$message\"/>" >> "$outfile"
        esac

        echo "    </testcase>" >> "$outfile"
    done < "$s2jtmpfile"

    rm -f "$s2jtmpfile"

    # Write the closing tag for the test results
    echo "</testsuite>" >> "$outfile"
    echo "</testsuites>" >> "$outfile"

    set -x
}

# Required variables
WORKSPACE=${WORKSPACE:-}

arch=${arch:-}
conf=${conf:-}
build=${build:-}
cc=${cc:-}


SRCDIR="$WORKSPACE/src/binutils-gdb"
TMPDIR="$WORKSPACE/tmp"
PREFIX="/build"

# Create tmp directory
rm -rf "$TMPDIR"
mkdir -p "$TMPDIR"

export TMPDIR
export CFLAGS="-O2 -fsanitize=address"
export CXXFLAGS="-O2 -fsanitize=address -D_GLIBCXX_DEBUG=1"
export LDFLAGS="-fsanitize=address"

# Set platform variables
case "$arch" in
*)
    export MAKE=make
    export TAR=tar
    export NPROC=nproc
    ;;
esac

# Print build env details
print_os || true
print_tooling || true

# Enter the source directory
cd "$SRCDIR"

# Run bootstrap in the source directory prior to configure
#./bootstrap

# Get source version from configure script
#eval "$(grep '^PACKAGE_VERSION=' ./configure)"
#PACKAGE_VERSION=${PACKAGE_VERSION//\-pre*/}

# Set configure options and environment variables for each build
# configuration.
CONF_OPTS=("--prefix=$PREFIX")

case "$conf" in
*)
    echo "Standard configuration"

    # Use system tools
    CONF_OPTS+=("--disable-binutils" "--disable-ld" "--disable-gold" "--disable-gas" "--disable-sim" "--disable-gprof")

    # Use system libs
    CONF_OPTS+=("--with-system-readline" "--with-system-zlib")

    # Enable optional features
    CONF_OPTS+=("--enable-targets=all" "--with-expat=yes" "--with-python=python3" "--with-guile=guile-2.2" "--enable-libctf")

    CONF_OPTS+=("--enable-build-warnings" "--enable-gdb-build-warnings" "--enable-unit-tests")

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
    echo "Out of tree build"

    # Create and enter a temporary build directory
    builddir=$(mktemp -d)
    cd "$builddir"

    "$SRCDIR/configure" "${CONF_OPTS[@]}" || failed_configure
    ;;
esac

# We are now inside a configured build directory

# BUILD!
$MAKE -j "$($NPROC)" V=1 MAKEINFO=/bin/true

# Install in the workspace
$MAKE install DESTDIR="$WORKSPACE"

# Run tests, don't fail now, we want to run the archiving steps
failed_tests=0
$MAKE -C gdb --keep-going check -j "$($NPROC)" || failed_tests=1

# Copy the dejagnu test results for archiving before cleaning the build dir
mkdir "${WORKSPACE}/results"
cp gdb/testsuite/gdb.log "${WORKSPACE}/results/"
cp gdb/testsuite/gdb.sum "${WORKSPACE}/results/"
sum2junit gdb/testsuite/gdb.sum "${WORKSPACE}/results/gdb.xml"

# Clean the build directory
$MAKE clean

# Cleanup rpath in executables and shared libraries
#find "$WORKSPACE/$PREFIX/bin" -type f -perm -0500 -exec chrpath --delete {} \;
#find "$WORKSPACE/$PREFIX/lib" -name "*.so" -exec chrpath --delete {} \;

# Remove libtool .la files
find "$WORKSPACE/$PREFIX/lib" -name "*.la" -exec rm -f {} \;

# Exit with failure if any of the tests failed
exit $failed_tests

# EOF
