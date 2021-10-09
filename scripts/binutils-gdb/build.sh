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

cat <<EOF > sum2junit.py
import sys
from datetime import datetime
import re
from xml.etree.ElementTree import ElementTree, Element, SubElement

line_re = re.compile(
    r"^(PASS|XPASS|FAIL|XFAIL|KFAIL|DUPLICATE|UNTESTED|UNSUPPORTED|UNRESOLVED): (.*?\.exp): (.*)"
)

pass_count = 0
fail_count = 0
skip_count = 0
error_count = 0
now = datetime.now().isoformat(timespec="seconds")

testsuites = Element(
    "testsuites",
    {
        "xmlns": "https://raw.githubusercontent.com/windyroad/JUnit-Schema/master/JUnit.xsd"
    },
)
testsuite = SubElement(
    testsuites,
    "testsuite",
    {
        "name": "GDB",
        "package": "package",
        "id": "0",
        "time": "1",
        "timestamp": now,
        "hostname": "hostname",
    },
)
SubElement(testsuite, "properties")

for line in sys.stdin:
    m = line_re.match(line)
    if not m:
        continue

    state, exp_filename, test_name = m.groups()

    testcase_name = "{} - {}".format(exp_filename, test_name)

    testcase = SubElement(
        testsuite,
        "testcase",
        {"name": testcase_name, "classname": "classname", "time": "0"},
    )

    if state in ("PASS", "XFAIL", "KFAIL"):
        pass_count += 1
    elif state in ("FAIL", "XPASS"):
        fail_count += 1
        SubElement(testcase, "failure", {"type": state})
    elif state in ("UNRESOLVED", "DUPLICATE"):
        error_count += 1
        SubElement(testcase, "error", {"type": state})
    elif state in ("UNTESTED", "UNSUPPORTED"):
        skip_count += 1
        SubElement(testcase, "skipped")
    else:
        assert False

testsuite.attrib["tests"] = str(pass_count + fail_count + skip_count)
testsuite.attrib["failures"] = str(fail_count)
testsuite.attrib["skipped"] = str(skip_count)
testsuite.attrib["errors"] = str(error_count)

SubElement(testsuite, "system-out")
SubElement(testsuite, "system-err")

et = ElementTree(testsuites)
et.write(sys.stdout, encoding="unicode")

sys.exit(1 if fail_count > 0 or error_count > 0 else 0)
EOF

    python3 sum2junit.py < "$infile" > "$outfile"
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

# Run tests, don't fail now, we know that "make check" is going to fail,
# since some tests don't pass.
#
# Disable ASan leaks reporting, it might break some tests since it adds
# unexpected output when GDB exits.
ASAN_OPTIONS=detect_leaks=0 $MAKE -C gdb --keep-going check -j "$($NPROC)" || true

# Copy the dejagnu test results for archiving before cleaning the build dir
mkdir "${WORKSPACE}/results"
cp gdb/testsuite/gdb.log "${WORKSPACE}/results/"
cp gdb/testsuite/gdb.sum "${WORKSPACE}/results/"

# Convert results to JUnit format.
failed_tests=0
sum2junit gdb/testsuite/gdb.sum "${WORKSPACE}/results/gdb.xml" || failed_tests=1

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
