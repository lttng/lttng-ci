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

# Filter out some known failures.
cat <<'EOF' > known-failures
DUPLICATE: gdb.base/attach-pie-misread.exp: copy ld-2.27.so to ld-linux-x86-64.so.2
DUPLICATE: gdb.base/attach-pie-misread.exp: copy libc-2.27.so to libc.so.6
DUPLICATE: gdb.base/attach-pie-misread.exp: ldd attach-pie-misread
DUPLICATE: gdb.base/attach-pie-misread.exp: ldd attach-pie-misread output contains libs
DUPLICATE: gdb.base/call-signal-resume.exp: dummy stack frame number
DUPLICATE: gdb.base/call-signal-resume.exp: return
DUPLICATE: gdb.base/call-signal-resume.exp: set confirm off
DUPLICATE: gdb.base/catch-signal.exp: 1: continue
DUPLICATE: gdb.base/catch-signal.exp: SIGHUP: continue
DUPLICATE: gdb.base/catch-signal.exp: SIGHUP SIGUSR2: continue
DUPLICATE: gdb.base/checkpoint.exp: restart 0 one
DUPLICATE: gdb.base/checkpoint.exp: verify lines 5 two
DUPLICATE: gdb.base/checkpoint-ns.exp: restart 0 one
DUPLICATE: gdb.base/checkpoint-ns.exp: verify lines 5 two
DUPLICATE: gdb.base/complete-empty.exp: empty-input-line: cmd complete ""
DUPLICATE: gdb.base/corefile-buildid.exp: could not generate core file
DUPLICATE: gdb.base/decl-before-def.exp: p a
DUPLICATE: gdb.base/define-prefix.exp: define user command: ghi-prefix-cmd
DUPLICATE: gdb.base/del.exp: info break after removing break on main
DUPLICATE: gdb.base/dfp-exprs.exp: p 1.2dl < 1.3df
DUPLICATE: gdb.base/dfp-test.exp: 1.23E45A is an invalid number
DUPLICATE: gdb.base/dfp-test.exp: 1.23E is an invalid number
DUPLICATE: gdb.base/exprs.exp: \$[0-9]* = red (setup)
DUPLICATE: gdb.base/funcargs.exp: run to call2a
DUPLICATE: gdb.base/interp.exp: interpreter-exec mi "-var-update *"
DUPLICATE: gdb.base/miscexprs.exp: print value of !ibig.i[100]
DUPLICATE: gdb.base/nested-subp2.exp: continue to the STOP marker
DUPLICATE: gdb.base/nested-subp2.exp: print c
DUPLICATE: gdb.base/nested-subp2.exp: print count
DUPLICATE: gdb.base/pending.exp: disable other breakpoints
DUPLICATE: gdb.base/pie-fork.exp: test_no_detach_on_fork: continue
DUPLICATE: gdb.base/pointers.exp: pointer assignment
DUPLICATE: gdb.base/pretty-array.exp: print nums
DUPLICATE: gdb.base/ptype.exp: list charfoo
DUPLICATE: gdb.base/ptype.exp: list intfoo
DUPLICATE: gdb.base/ptype.exp: ptype the_highest
DUPLICATE: gdb.base/readline.exp: Simple operate-and-get-next - final prompt
DUPLICATE: gdb.base/realname-expand.exp: set basenames-may-differ on
DUPLICATE: gdb.base/set-cwd.exp: test_cwd_reset: continue to breakpoint: break-here
DUPLICATE: gdb.base/shlib-call.exp: continue until exit
DUPLICATE: gdb.base/shlib-call.exp: print g
DUPLICATE: gdb.base/shlib-call.exp: set print address off
DUPLICATE: gdb.base/shlib-call.exp: set print sevenbit-strings
DUPLICATE: gdb.base/shlib-call.exp: set width 0
DUPLICATE: gdb.base/solib-display.exp: IN: break 25
DUPLICATE: gdb.base/solib-display.exp: IN: continue
DUPLICATE: gdb.base/solib-display.exp: NO: break 25
DUPLICATE: gdb.base/solib-display.exp: NO: continue
DUPLICATE: gdb.base/solib-display.exp: SEP: break 25
DUPLICATE: gdb.base/solib-display.exp: SEP: continue
DUPLICATE: gdb.base/stack-checking.exp: bt
DUPLICATE: gdb.base/subst.exp: unset substitute-path from, no rule entered yet
DUPLICATE: gdb.base/ui-redirect.exp: redirect while already logging: set logging redirect off
DUPLICATE: gdb.base/unload.exp: continuing to unloaded libfile
DUPLICATE: gdb.base/watchpoints.exp: watchpoint hit, first time
DUPLICATE: gdb.mi/mi2-amd64-entry-value.exp: breakpoint at main
DUPLICATE: gdb.mi/mi2-amd64-entry-value.exp: mi runto main
DUPLICATE: gdb.mi/mi2-var-child.exp: get children of psnp->char_ptr.*psnp->char_ptr.**psnp->char_ptr.***psnp->char_ptr
DUPLICATE: gdb.mi/mi2-var-child.exp: get children of psnp->ptrs.0.next.char_ptr.*char_ptr.**char_ptr
DUPLICATE: gdb.mi/mi2-var-child.exp: get children of psnp->ptrs.0.next.char_ptr.*char_ptr.**char_ptr.***char_ptr
DUPLICATE: gdb.mi/mi2-var-child.exp: get number of children of psnp->ptrs.0.next.char_ptr.*char_ptr.**char_ptr.***char_ptr
DUPLICATE: gdb.mi/mi-catch-cpp-exceptions.exp: breakpoint at main
DUPLICATE: gdb.mi/mi-catch-cpp-exceptions.exp: mi runto main
DUPLICATE: gdb.mi/mi-catch-load.exp: breakpoint at main
DUPLICATE: gdb.mi/mi-catch-load.exp: mi runto main
DUPLICATE: gdb.mi/mi-language.exp: set lang ada
DUPLICATE: gdb.mi/mi-nonstop-exit.exp: breakpoint at main
DUPLICATE: gdb.mi/mi-nonstop-exit.exp: mi runto main
DUPLICATE: gdb.mi/mi-nonstop.exp: check varobj, w1, 1
DUPLICATE: gdb.mi/mi-nonstop.exp: stacktrace of stopped thread
DUPLICATE: gdb.mi/mi-nsthrexec.exp: breakpoint at main
DUPLICATE: gdb.mi/mi-syn-frame.exp: finished exec continue
DUPLICATE: gdb.mi/mi-syn-frame.exp: list stack frames
DUPLICATE: gdb.mi/mi-var-child.exp: get children of psnp->char_ptr.*psnp->char_ptr.**psnp->char_ptr.***psnp->char_ptr
DUPLICATE: gdb.mi/mi-var-child.exp: get children of psnp->ptrs.0.next.char_ptr.*char_ptr.**char_ptr
DUPLICATE: gdb.mi/mi-var-child.exp: get children of psnp->ptrs.0.next.char_ptr.*char_ptr.**char_ptr.***char_ptr
DUPLICATE: gdb.mi/mi-var-child.exp: get number of children of psnp->ptrs.0.next.char_ptr.*char_ptr.**char_ptr.***char_ptr
DUPLICATE: gdb.mi/mi-var-cp.exp: create varobj for s
DUPLICATE: gdb.mi/mi-var-rtti.exp: list children of ptr.Base.public (with RTTI) in use_rtti_with_multiple_inheritence
DUPLICATE: gdb.mi/mi-var-rtti.exp: list children of ptr.public (without RTTI) in skip_type_update_when_not_use_rtti
DUPLICATE: gdb.mi/mi-var-rtti.exp: list children of ptr (without RTTI) in skip_type_update_when_not_use_rtti
DUPLICATE: gdb.mi/mi-var-rtti.exp: list children of s.ptr.public (without RTTI) in skip_type_update_when_not_use_rtti
DUPLICATE: gdb.mi/mi-var-rtti.exp: list children of s.ptr (without RTTI) in skip_type_update_when_not_use_rtti
DUPLICATE: gdb.mi/mi-watch.exp: mi-mode=main: wp-type=hw: watchpoint trigger
DUPLICATE: gdb.mi/mi-watch.exp: mi-mode=main: wp-type=sw: watchpoint trigger
DUPLICATE: gdb.mi/mi-watch.exp: mi-mode=separate: wp-type=hw: watchpoint trigger
DUPLICATE: gdb.mi/mi-watch.exp: mi-mode=separate: wp-type=sw: watchpoint trigger
FAIL: gdb.ada/interface.exp: print s
FAIL: gdb.ada/iwide.exp: print d_access.all
FAIL: gdb.ada/iwide.exp: print dp_access.all
FAIL: gdb.ada/iwide.exp: print My_Drawable
FAIL: gdb.ada/iwide.exp: print s_access.all
FAIL: gdb.ada/iwide.exp: print sp_access.all
FAIL: gdb.ada/mi_interface.exp: create ggg1 varobj (unexpected output)
FAIL: gdb.ada/mi_interface.exp: list ggg1's children (unexpected output)
FAIL: gdb.ada/tagged_access.exp: ptype c.all
FAIL: gdb.ada/tagged_access.exp: ptype c.menu_name
FAIL: gdb.ada/tagged.exp: print obj
FAIL: gdb.ada/tagged.exp: ptype obj
FAIL: gdb.base/bt-on-fatal-signal.exp: BUS: $saw_bt_end
FAIL: gdb.base/bt-on-fatal-signal.exp: BUS: $saw_bt_start
FAIL: gdb.base/bt-on-fatal-signal.exp: BUS: $saw_fatal_msg
FAIL: gdb.base/bt-on-fatal-signal.exp: BUS: [expr $internal_error_msg_count == 2]
FAIL: gdb.base/bt-on-fatal-signal.exp: FPE: $saw_bt_end
FAIL: gdb.base/bt-on-fatal-signal.exp: FPE: $saw_bt_start
FAIL: gdb.base/bt-on-fatal-signal.exp: FPE: $saw_fatal_msg
FAIL: gdb.base/bt-on-fatal-signal.exp: FPE: [expr $internal_error_msg_count == 2]
FAIL: gdb.base/bt-on-fatal-signal.exp: SEGV: $saw_bt_end
FAIL: gdb.base/bt-on-fatal-signal.exp: SEGV: $saw_bt_start
FAIL: gdb.base/bt-on-fatal-signal.exp: SEGV: $saw_fatal_msg
FAIL: gdb.base/bt-on-fatal-signal.exp: SEGV: [expr $internal_error_msg_count == 2]
FAIL: gdb.base/share-env-with-gdbserver.exp: strange named var: print result of getenv for 'asd ='
FAIL: gdb.base/step-over-syscall.exp: clone: displaced=off: single step over clone
FAIL: gdb.cp/no-dmgl-verbose.exp: setting breakpoint at 'f(std::string)'
FAIL: gdb.dwarf2/dw2-inline-param.exp: running to *0x608 in runto
FAIL: gdb.gdb/python-interrupts.exp: run until breakpoint at captured_command_loop
FAIL: gdb.mi/mi-break.exp: mi-mode=main: test_explicit_breakpoints: -break-insert -c "foo == 3" --source basics.c --function main --label label (unexpected output)
FAIL: gdb.mi/mi-break.exp: mi-mode=main: test_explicit_breakpoints: -break-insert --source basics.c --function foobar (unexpected output)
FAIL: gdb.mi/mi-break.exp: mi-mode=main: test_explicit_breakpoints: -break-insert --source basics.c --function main --label foobar (unexpected output)
FAIL: gdb.mi/mi-break.exp: mi-mode=main: test_explicit_breakpoints: -break-insert --source basics.c (unexpected output)
FAIL: gdb.mi/mi-break.exp: mi-mode=separate: test_explicit_breakpoints: -break-insert -c "foo == 3" --source basics.c --function main --label label (unexpected output)
FAIL: gdb.mi/mi-break.exp: mi-mode=separate: test_explicit_breakpoints: -break-insert --source basics.c --function foobar (unexpected output)
FAIL: gdb.mi/mi-break.exp: mi-mode=separate: test_explicit_breakpoints: -break-insert --source basics.c --function main --label foobar (unexpected output)
FAIL: gdb.mi/mi-break.exp: mi-mode=separate: test_explicit_breakpoints: -break-insert --source basics.c (unexpected output)
FAIL: gdb.mi/mi-breakpoint-changed.exp: test_auto_disable: -break-enable count 1 2 (unexpected output)
FAIL: gdb.mi/mi-breakpoint-changed.exp: test_auto_disable: -break-insert -f pendfunc1 (unexpected output)
FAIL: gdb.threads/detach-step-over.exp: breakpoint-condition-evaluation=host: target-non-stop=on: non-stop=on: displaced=off: iter 3: attach (GDB internal error)
UNRESOLVED: gdb.base/libsegfault.exp: gdb emits custom handler warning
UNRESOLVED: gdb.base/readline-ask.exp: bell for more message
UNRESOLVED: gdb.base/symbol-without-target_section.exp: list -q main
UNRESOLVED: gdb.dwarf2/dw2-icc-opaque.exp: ptype p_struct
UNRESOLVED: gdb.opencl/vec_comps.exp: OpenCL support not detected
UNRESOLVED: gdb.threads/attach-many-short-lived-threads.exp: iter 8: detach
EOF

grep --invert-match --fixed-strings --file=known-failures  "${WORKSPACE}/results/gdb.sum" > "${WORKSPACE}/results/gdb.filtered.sum"

# Convert results to JUnit format.
failed_tests=0
sum2junit "${WORKSPACE}/results/gdb.filtered.sum" "${WORKSPACE}/results/gdb.xml" || failed_tests=1

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
