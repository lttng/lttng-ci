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
        print("{}: {}".format(state, testcase_name), file=sys.stderr)
        fail_count += 1
        SubElement(testcase, "failure", {"type": state})
    elif state in ("UNRESOLVED", "DUPLICATE"):
        print("{}: {}".format(state, testcase_name), file=sys.stderr)
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

platform=${platform:-}
conf=${conf:-}
build=${build:-}
target_board=${target_board:-unix}


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
export CC="ccache cc"
export CXX="ccache c++"

# Set platform variables
case "$platform" in
*)
    export MAKE=make
    export TAR=tar
    export NPROC=nproc
    ;;
esac

# Print build env details
print_os || true
print_tooling || true

if use_ccache; then
	ccache -c
fi

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
    CONF_OPTS+=("--disable-binutils" "--disable-ld" "--disable-gold" "--disable-gas" "--disable-sim" "--disable-gprof" "--disable-gprofng")

    # Use system libs
    CONF_OPTS+=("--with-system-readline" "--with-system-zlib")

    # Enable optional features
    CONF_OPTS+=("--enable-targets=all" "--with-expat=yes" "--with-python=python3" "--with-guile" "--enable-libctf")

    CONF_OPTS+=("--enable-build-warnings" "--enable-gdb-build-warnings" "--enable-unit-tests" "--enable-ubsan")

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

case "$target_board" in
unix | native-gdbserver | native-extended-gdbserver)
    RUNTESTFLAGS="--target_board=$target_board"
    ;;

*)
    echo "Unknown \$target_board value: $target_board"
    exit 1
    ;;
esac

# Run tests, don't fail now, we know that "make check" is going to fail,
# since some tests don't pass.
$MAKE -C gdb --keep-going check -j "$($NPROC)" RUNTESTFLAGS="$RUNTESTFLAGS" FORCE_PARALLEL="1" || true

# Copy the dejagnu test results for archiving before cleaning the build dir
mkdir "${WORKSPACE}/results"
cp gdb/testsuite/gdb.log "${WORKSPACE}/results/"
cp gdb/testsuite/gdb.sum "${WORKSPACE}/results/"

# Filter out some known failures.  There is one file per target board.
cat <<'EOF' > known-failures-unix
FAIL: gdb.ada/mi_var_access.exp: Create varobj (unexpected output)
FAIL: gdb.ada/mi_var_access.exp: update at stop 2 (unexpected output)
FAIL: gdb.ada/packed_array_assign.exp: value of pra
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
FAIL: gdb.base/coredump-filter.exp: loading and testing corefile for non-Private-Shared-Anon-File: no binary: disassemble function with corefile and without a binary
FAIL: gdb.base/ending-run.exp: step out of main
FAIL: gdb.base/ending-run.exp: step to end of run
FAIL: gdb.base/gdb-sigterm.exp: pass=16: expect eof (GDB internal error)
FAIL: gdb.base/share-env-with-gdbserver.exp: strange named var: print result of getenv for 'asd ='
FAIL: gdb.base/step-over-syscall.exp: clone: displaced=off: single step over clone
FAIL: gdb.compile/compile-cplus.exp: bt
FAIL: gdb.compile/compile-cplus.exp: compile code extern int globalshadow; globalshadow += 5;
FAIL: gdb.compile/compile-cplus.exp: print 'compile-cplus.c'::globalshadow
FAIL: gdb.compile/compile-cplus-method.exp: compile code a->get_var ()
FAIL: gdb.compile/compile-cplus-method.exp: result of compile code a->get_var ()
FAIL: gdb.compile/compile-cplus-method.exp: compile code a->get_var (static_cast<unsigned long> (1))
FAIL: gdb.compile/compile-cplus-method.exp: result of compile code a->get_var (static_cast<unsigned long> (1))
FAIL: gdb.compile/compile-cplus-method.exp: compile code a->get_var (static_cast<int> (1))
FAIL: gdb.compile/compile-cplus-method.exp: result of compile code a->get_var (static_cast<int> (1))
FAIL: gdb.compile/compile-cplus-method.exp: compile code a->get_var (static_cast<float> (1))
FAIL: gdb.compile/compile-cplus-method.exp: result of compile code a->get_var (static_cast<float> (1))
FAIL: gdb.compile/compile-cplus-method.exp: compile code a->get_var (static_cast<void *> (a))
FAIL: gdb.compile/compile-cplus-method.exp: result of compile code a->get_var (static_cast<void *> (a))
FAIL: gdb.compile/compile-cplus-method.exp: compile code a->get_var (*a)
FAIL: gdb.compile/compile-cplus-method.exp: result of compile code a->get_var (*a)
FAIL: gdb.compile/compile-cplus-method.exp: compile code a->get_var (*ac)
FAIL: gdb.compile/compile-cplus-method.exp: result of compile code a->get_var (*ac)
FAIL: gdb.compile/compile-cplus-method.exp: compile code a->get_var1 (1)
FAIL: gdb.compile/compile-cplus-method.exp: result of compile code a->get_var1 (1)
FAIL: gdb.compile/compile-cplus-method.exp: compile code a->get_var2 (1, 2)
FAIL: gdb.compile/compile-cplus-method.exp: result of compile code a->get_var2 (1, 2)
FAIL: gdb.compile/compile-cplus-method.exp: compile code A::get_1 (a->get_var ())
FAIL: gdb.compile/compile-cplus-method.exp: result of compile code A::get_1 (a->get_var ())
FAIL: gdb.compile/compile-cplus-method.exp: compile code a->get_var1 (a->get_var () - 16)
FAIL: gdb.compile/compile-cplus-method.exp: result of compile code a->get_var1 (a->get_var () - 16)
FAIL: gdb.compile/compile-cplus-method.exp: compile code a->get_var2 (a->get_var (), A::get_1 (2))
FAIL: gdb.compile/compile-cplus-method.exp: result of compile code a->get_var2 (a->get_var (), A::get_1 (2))
FAIL: gdb.compile/compile-cplus-method.exp: compile code get_value (a)
FAIL: gdb.compile/compile-cplus-method.exp: result of compile code get_value (a)
FAIL: gdb.compile/compile-cplus-method.exp: compile code (a->*pmf) (1)
FAIL: gdb.compile/compile-cplus-method.exp: result of compile code (a->*pmf) (1)
FAIL: gdb.compile/compile-cplus-method.exp: compile code pmf = &A::get_var1; var = (a->*pmf) (2); pmf = &A::get_var
FAIL: gdb.compile/compile-cplus-method.exp: result of compile code pmf = &A::get_var1; var = (a->*pmf) (2); pmf = &A::get_var
FAIL: gdb.compile/compile-cplus-method.exp: compile code (a->**pmf_p) (1)
FAIL: gdb.compile/compile-cplus-method.exp: result of compile code (a->**pmf_p) (1)
FAIL: gdb.compile/compile-cplus-virtual.exp: compile code ap->doit ()
FAIL: gdb.compile/compile-cplus-virtual.exp: compile code ap->doit2 ()
FAIL: gdb.cp/no-dmgl-verbose.exp: gdb_breakpoint: set breakpoint at 'f(std::string)'
FAIL: gdb.cp/step-and-next-inline.exp: no_header: next step 1
FAIL: gdb.cp/step-and-next-inline.exp: no_header: next step 2
FAIL: gdb.cp/step-and-next-inline.exp: no_header: next step 3
FAIL: gdb.cp/step-and-next-inline.exp: no_header: next step 4
FAIL: gdb.gdb/python-interrupts.exp: run until breakpoint at captured_command_loop
FAIL: gdb.mi/list-thread-groups-available.exp: list available thread groups with filter (unexpected output)
FAIL: gdb.threads/attach-stopped.exp: threaded: attach2 to stopped bt
FAIL: gdb.threads/clone-attach-detach.exp: bg attach 2: attach (timeout)
FAIL: gdb.threads/process-dies-while-detaching.exp: single-process: continue: detach: continue
FAIL: gdb.threads/process-dies-while-detaching.exp: single-process: continue: killed outside: continue
FAIL: gdb.threads/process-dies-while-detaching.exp: single-process: continue: watchpoint:hw: continue
FAIL: gdb.threads/signal-command-handle-nopass.exp: step-over no: signal SIGUSR1
FAIL: gdb.threads/signal-command-handle-nopass.exp: step-over yes: signal SIGUSR1
FAIL: gdb.threads/signal-sigtrap.exp: sigtrap thread 1: signal SIGTRAP reaches handler
FAIL: gdb.threads/signal-while-stepping-over-bp-other-thread.exp: step (pattern 3)
UNRESOLVED: gdb.ada/arrayptr.exp: scenario=all: gdb_breakpoint: set breakpoint at foo.adb:40
UNRESOLVED: gdb.ada/arrayptr.exp: scenario=all: runto: run to foo.adb:40 (eof)
UNRESOLVED: gdb.ada/arrayptr.exp: scenario=all: gdb_breakpoint: set breakpoint at foo.adb:40 (eof)
UNRESOLVED: gdb.ada/exprs.exp: gdb_breakpoint: set breakpoint at p.adb:40
UNRESOLVED: gdb.ada/exprs.exp: runto: run to p.adb:40 (eof)
UNRESOLVED: gdb.ada/exprs.exp: Long_Long_Integer ** Y
UNRESOLVED: gdb.ada/exprs.exp: long_float'min
UNRESOLVED: gdb.ada/exprs.exp: long_float'max
UNRESOLVED: gdb.ada/exprs.exp: gdb_breakpoint: set breakpoint at p.adb:40 (eof)
UNRESOLVED: gdb.ada/packed_array_assign.exp: gdb_breakpoint: set breakpoint at aggregates.run_test
UNRESOLVED: gdb.ada/packed_array_assign.exp: runto: run to aggregates.run_test (eof)
UNRESOLVED: gdb.ada/packed_array_assign.exp: gdb_breakpoint: set breakpoint at aggregates.run_test (eof)
UNRESOLVED: gdb.ada/packed_array_assign.exp: value of pra
UNRESOLVED: gdb.ada/packed_array_assign.exp: print pra(1) := pr
UNRESOLVED: gdb.ada/packed_array_assign.exp: print pra(1)
UNRESOLVED: gdb.ada/packed_array_assign.exp: value of npr
UNRESOLVED: gdb.base/gdb-sigterm.exp: 50 SIGTERM passes
UNRESOLVED: gdb.base/readline-ask.exp: bell for more message
UNRESOLVED: gdb.python/py-disasm.exp: global_disassembler=GlobalPreInfoDisassembler: disassemble main
EOF

cat <<'EOF' > known-failures-re-unix
FAIL: gdb.base/gdb-sigterm.exp: pass=[0-9]+: expect eof \(GDB internal error\)
FAIL: gdb.threads/step-N-all-progress.exp: non-stop=on: target-non-stop=on: next .*
EOF

cat <<'EOF' > known-failures-native-gdbserver
DUPLICATE: gdb.base/cond-eval-mode.exp: awatch: awatch global
DUPLICATE: gdb.base/cond-eval-mode.exp: awatch: continue
DUPLICATE: gdb.base/cond-eval-mode.exp: break: break foo
DUPLICATE: gdb.base/cond-eval-mode.exp: break: continue
DUPLICATE: gdb.base/cond-eval-mode.exp: hbreak: continue
DUPLICATE: gdb.base/cond-eval-mode.exp: hbreak: hbreak foo
DUPLICATE: gdb.base/cond-eval-mode.exp: rwatch: continue
DUPLICATE: gdb.base/cond-eval-mode.exp: rwatch: rwatch global
DUPLICATE: gdb.base/cond-eval-mode.exp: watch: continue
DUPLICATE: gdb.base/cond-eval-mode.exp: watch: watch global
DUPLICATE: gdb.trace/circ.exp: check whether setting trace buffer size is supported
DUPLICATE: gdb.trace/ftrace-lock.exp: successfully compiled posix threads test case
DUPLICATE: gdb.trace/mi-tsv-changed.exp: create delete modify: tvariable $tvar3 modified
DUPLICATE: gdb.trace/signal.exp: get integer valueof "counter"
DUPLICATE: gdb.trace/status-stop.exp: buffer_full_tstart: tstart
DUPLICATE: gdb.trace/status-stop.exp: tstart_tstop_tstart: tstart
DUPLICATE: gdb.trace/tfind.exp: 8.17: tfind none
DUPLICATE: gdb.trace/trace-buffer-size.exp: set tracepoint at test_function
DUPLICATE: gdb.trace/trace-buffer-size.exp: tstart
DUPLICATE: gdb.trace/trace-mt.exp: successfully compiled posix threads test case
FAIL: gdb.ada/mi_var_access.exp: Create varobj (unexpected output)
FAIL: gdb.ada/mi_var_access.exp: update at stop 2 (unexpected output)
FAIL: gdb.ada/packed_array_assign.exp: value of pra
FAIL: gdb.arch/ftrace-insn-reloc.exp: runto: run to main
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
FAIL: gdb.base/compare-sections.exp: after reload: compare-sections
FAIL: gdb.base/compare-sections.exp: after reload: compare-sections -r
FAIL: gdb.base/compare-sections.exp: after run to main: compare-sections
FAIL: gdb.base/compare-sections.exp: after run to main: compare-sections -r
FAIL: gdb.base/compare-sections.exp: compare-sections .text
FAIL: gdb.base/compare-sections.exp: read-only: compare-sections -r
FAIL: gdb.base/coredump-filter.exp: loading and testing corefile for non-Private-Shared-Anon-File: no binary: disassemble function with corefile and without a binary
FAIL: gdb.base/ending-run.exp: step out of main
FAIL: gdb.base/ending-run.exp: step to end of run
FAIL: gdb.base/interrupt-daemon.exp: bg: continue& (timeout)
FAIL: gdb.base/interrupt-daemon.exp: bg: interrupt cmd stops process (timeout)
FAIL: gdb.base/interrupt-daemon.exp: bg: interrupt (timeout)
FAIL: gdb.base/interrupt-daemon.exp: fg: ctrl-c stops process (timeout)
FAIL: gdb.base/options.exp: test-backtrace: cmd complete "backtrace "
FAIL: gdb.base/options.exp: test-backtrace: tab complete "backtrace " (clearing input line) (timeout)
FAIL: gdb.base/range-stepping.exp: step over func: next: vCont;r=2
FAIL: gdb.compile/compile-cplus.exp: bt
FAIL: gdb.compile/compile-cplus.exp: compile code extern int globalshadow; globalshadow += 5;
FAIL: gdb.compile/compile-cplus.exp: print 'compile-cplus.c'::globalshadow
FAIL: gdb.compile/compile-cplus-method.exp: compile code a->get_var ()
FAIL: gdb.compile/compile-cplus-method.exp: result of compile code a->get_var ()
FAIL: gdb.compile/compile-cplus-method.exp: compile code a->get_var (static_cast<unsigned long> (1))
FAIL: gdb.compile/compile-cplus-method.exp: result of compile code a->get_var (static_cast<unsigned long> (1))
FAIL: gdb.compile/compile-cplus-method.exp: compile code a->get_var (static_cast<int> (1))
FAIL: gdb.compile/compile-cplus-method.exp: result of compile code a->get_var (static_cast<int> (1))
FAIL: gdb.compile/compile-cplus-method.exp: compile code a->get_var (static_cast<float> (1))
FAIL: gdb.compile/compile-cplus-method.exp: result of compile code a->get_var (static_cast<float> (1))
FAIL: gdb.compile/compile-cplus-method.exp: compile code a->get_var (static_cast<void *> (a))
FAIL: gdb.compile/compile-cplus-method.exp: result of compile code a->get_var (static_cast<void *> (a))
FAIL: gdb.compile/compile-cplus-method.exp: compile code a->get_var (*a)
FAIL: gdb.compile/compile-cplus-method.exp: result of compile code a->get_var (*a)
FAIL: gdb.compile/compile-cplus-method.exp: compile code a->get_var (*ac)
FAIL: gdb.compile/compile-cplus-method.exp: result of compile code a->get_var (*ac)
FAIL: gdb.compile/compile-cplus-method.exp: compile code a->get_var1 (1)
FAIL: gdb.compile/compile-cplus-method.exp: result of compile code a->get_var1 (1)
FAIL: gdb.compile/compile-cplus-method.exp: compile code a->get_var2 (1, 2)
FAIL: gdb.compile/compile-cplus-method.exp: result of compile code a->get_var2 (1, 2)
FAIL: gdb.compile/compile-cplus-method.exp: compile code A::get_1 (a->get_var ())
FAIL: gdb.compile/compile-cplus-method.exp: result of compile code A::get_1 (a->get_var ())
FAIL: gdb.compile/compile-cplus-method.exp: compile code a->get_var1 (a->get_var () - 16)
FAIL: gdb.compile/compile-cplus-method.exp: result of compile code a->get_var1 (a->get_var () - 16)
FAIL: gdb.compile/compile-cplus-method.exp: compile code a->get_var2 (a->get_var (), A::get_1 (2))
FAIL: gdb.compile/compile-cplus-method.exp: result of compile code a->get_var2 (a->get_var (), A::get_1 (2))
FAIL: gdb.compile/compile-cplus-method.exp: compile code get_value (a)
FAIL: gdb.compile/compile-cplus-method.exp: result of compile code get_value (a)
FAIL: gdb.compile/compile-cplus-method.exp: compile code (a->*pmf) (1)
FAIL: gdb.compile/compile-cplus-method.exp: result of compile code (a->*pmf) (1)
FAIL: gdb.compile/compile-cplus-method.exp: compile code pmf = &A::get_var1; var = (a->*pmf) (2); pmf = &A::get_var
FAIL: gdb.compile/compile-cplus-method.exp: result of compile code pmf = &A::get_var1; var = (a->*pmf) (2); pmf = &A::get_var
FAIL: gdb.compile/compile-cplus-method.exp: compile code (a->**pmf_p) (1)
FAIL: gdb.compile/compile-cplus-method.exp: result of compile code (a->**pmf_p) (1)
FAIL: gdb.compile/compile-cplus-virtual.exp: compile code ap->doit ()
FAIL: gdb.compile/compile-cplus-virtual.exp: compile code ap->doit2 ()
FAIL: gdb.cp/no-dmgl-verbose.exp: gdb_breakpoint: set breakpoint at 'f(std::string)'
FAIL: gdb.cp/step-and-next-inline.exp: no_header: next step 1
FAIL: gdb.cp/step-and-next-inline.exp: no_header: next step 2
FAIL: gdb.cp/step-and-next-inline.exp: no_header: next step 3
FAIL: gdb.cp/step-and-next-inline.exp: no_header: next step 4
FAIL: gdb.dwarf2/clztest.exp: runto: run to main
FAIL: gdb.threads/multiple-successive-infcall.exp: thread=3: created new thread
FAIL: gdb.threads/multiple-successive-infcall.exp: thread=4: created new thread
FAIL: gdb.threads/multiple-successive-infcall.exp: thread=5: created new thread
FAIL: gdb.threads/process-dies-while-detaching.exp: single-process: continue: killed outside: continue
FAIL: gdb.threads/signal-command-handle-nopass.exp: step-over no: signal SIGUSR1
FAIL: gdb.threads/signal-command-handle-nopass.exp: step-over yes: signal SIGUSR1
FAIL: gdb.threads/signal-sigtrap.exp: sigtrap thread 1: signal SIGTRAP reaches handler
FAIL: gdb.threads/thread-specific-bp.exp: all-stop: continue to end (timeout)
FAIL: gdb.threads/thread-specific-bp.exp: non-stop: continue to end (timeout)
FAIL: gdb.trace/actions.exp: tfile: tracepoint on gdb_asm_test
FAIL: gdb.trace/actions.exp: tfile: tracepoint on gdb_c_test
FAIL: gdb.trace/actions.exp: tfile: tracepoint on gdb_recursion_test 0
FAIL: gdb.trace/change-loc.exp: 1 ftrace: runto: run to main
FAIL: gdb.trace/change-loc.exp: 1 trace: continue to marker 2
FAIL: gdb.trace/change-loc.exp: 1 trace: continue to marker 3
FAIL: gdb.trace/change-loc.exp: 1 trace: tfind frame 0
FAIL: gdb.trace/change-loc.exp: 1 trace: tracepoint with two locations - installed (unload)
FAIL: gdb.trace/change-loc.exp: 1 trace: tracepoint with two locations - pending (unload)
FAIL: gdb.trace/change-loc.exp: 2 ftrace: continue to marker 1 (the program is no longer running)
FAIL: gdb.trace/change-loc.exp: 2 ftrace: continue to marker 2 (the program is no longer running)
FAIL: gdb.trace/change-loc.exp: 2 ftrace: continue to marker 3 (the program is no longer running)
FAIL: gdb.trace/change-loc.exp: 2 ftrace: run to main (the program exited)
FAIL: gdb.trace/change-loc.exp: 2 ftrace: tfind frame 0
FAIL: gdb.trace/change-loc.exp: 2 ftrace: tfind frame 1
FAIL: gdb.trace/change-loc.exp: 2 ftrace: tfind frame 2
FAIL: gdb.trace/change-loc.exp: 2 ftrace: tracepoint with three locations
FAIL: gdb.trace/change-loc.exp: 2 ftrace: tracepoint with two locations - installed (unload)
FAIL: gdb.trace/change-loc.exp: 2 ftrace: tracepoint with two locations - pending (unload)
FAIL: gdb.trace/change-loc.exp: 2 ftrace: tstart
FAIL: gdb.trace/change-loc.exp: 2 ftrace: tstop
FAIL: gdb.trace/change-loc.exp: 2 trace: continue to marker 2
FAIL: gdb.trace/change-loc.exp: 2 trace: continue to marker 3
FAIL: gdb.trace/change-loc.exp: 2 trace: tfind frame 2
FAIL: gdb.trace/change-loc.exp: 2 trace: tracepoint with two locations - installed (unload)
FAIL: gdb.trace/change-loc.exp: 2 trace: tracepoint with two locations - pending (unload)
FAIL: gdb.trace/change-loc.exp: InstallInTrace disabled: ftrace: runto: run to main
FAIL: gdb.trace/collection.exp: collect register locals collectively: collected local char
FAIL: gdb.trace/collection.exp: collect register locals collectively: collected local double
FAIL: gdb.trace/collection.exp: collect register locals collectively: collected local float
FAIL: gdb.trace/collection.exp: collect register locals collectively: collected local int
FAIL: gdb.trace/collection.exp: collect register locals collectively: collected local member char
FAIL: gdb.trace/collection.exp: collect register locals collectively: collected local member double
FAIL: gdb.trace/collection.exp: collect register locals collectively: collected local member float
FAIL: gdb.trace/collection.exp: collect register locals collectively: collected local member int
FAIL: gdb.trace/collection.exp: collect register locals collectively: collected locarray #0
FAIL: gdb.trace/collection.exp: collect register locals collectively: collected locarray #1
FAIL: gdb.trace/collection.exp: collect register locals collectively: collected locarray #2
FAIL: gdb.trace/collection.exp: collect register locals collectively: collected locarray #3
FAIL: gdb.trace/collection.exp: collect register locals collectively: run trace experiment: start trace experiment
FAIL: gdb.trace/collection.exp: collect register locals collectively: run trace experiment: tfind test frame
FAIL: gdb.trace/collection.exp: collect register locals collectively: start trace experiment
FAIL: gdb.trace/collection.exp: collect register locals collectively: tfind test frame
FAIL: gdb.trace/collection.exp: collect register locals individually: collected local char
FAIL: gdb.trace/collection.exp: collect register locals individually: collected local double
FAIL: gdb.trace/collection.exp: collect register locals individually: collected local float
FAIL: gdb.trace/collection.exp: collect register locals individually: collected local int
FAIL: gdb.trace/collection.exp: collect register locals individually: collected local member char
FAIL: gdb.trace/collection.exp: collect register locals individually: collected local member double
FAIL: gdb.trace/collection.exp: collect register locals individually: collected local member float
FAIL: gdb.trace/collection.exp: collect register locals individually: collected local member int
FAIL: gdb.trace/collection.exp: collect register locals individually: collected locarray #0
FAIL: gdb.trace/collection.exp: collect register locals individually: collected locarray #1
FAIL: gdb.trace/collection.exp: collect register locals individually: collected locarray #2
FAIL: gdb.trace/collection.exp: collect register locals individually: collected locarray #3
FAIL: gdb.trace/collection.exp: collect register locals individually: define actions
FAIL: gdb.trace/ftrace.exp: runto: run to main
FAIL: gdb.trace/ftrace-lock.exp: runto: run to main
FAIL: gdb.trace/mi-trace-frame-collected.exp: tfile: -trace-frame-collected (unexpected output)
FAIL: gdb.trace/mi-trace-frame-collected.exp: tfile: -trace-frame-collected --var-print-values 2 --comp-print-values --simple-values --registers-format x --memory-contents (unexpected output)
FAIL: gdb.trace/mi-tsv-changed.exp: create delete modify: tvariable $tvar3 modified (unexpected output)
FAIL: gdb.trace/pending.exp: ftrace action_resolved: runto: run to main
FAIL: gdb.trace/pending.exp: ftrace disconn_resolved: runto: run to main
FAIL: gdb.trace/pending.exp: ftrace disconn: runto: run to main
FAIL: gdb.trace/pending.exp: ftrace installed_in_trace: runto: run to main
FAIL: gdb.trace/pending.exp: ftrace resolved_in_trace: runto: run to main
FAIL: gdb.trace/pending.exp: ftrace resolved: (the program exited)
FAIL: gdb.trace/pending.exp: ftrace works: continue to marker (the program is no longer running)
FAIL: gdb.trace/pending.exp: ftrace works: start trace experiment
FAIL: gdb.trace/pending.exp: ftrace works: tfind test frame 0
FAIL: gdb.trace/pending.exp: ftrace works: tfind test frame 1
FAIL: gdb.trace/pending.exp: ftrace works: tfind test frame 2
FAIL: gdb.trace/pending.exp: ftrace works: (the program exited)
FAIL: gdb.trace/pending.exp: trace installed_in_trace: continue to marker 2
FAIL: gdb.trace/pending.exp: trace installed_in_trace: tfind test frame 0
FAIL: gdb.trace/range-stepping.exp: runto: run to main
FAIL: gdb.trace/trace-break.exp: runto: run to main
FAIL: gdb.trace/trace-condition.exp: runto: run to main
FAIL: gdb.trace/trace-enable-disable.exp: test_tracepoint_enable_disable ftrace: runto: run to main
FAIL: gdb.trace/trace-enable-disable.exp: test_tracepoint_enable_disable trace: runto: run to main
FAIL: gdb.trace/trace-mt.exp: runto: run to main
FAIL: gdb.trace/tspeed.exp: runto: run to main
FAIL: gdb.trace/unavailable.exp: collect globals: print object off: print derived_partial
FAIL: gdb.trace/unavailable.exp: collect globals: print object on: print derived_partial
FAIL: gdb.trace/unavailable.exp: collect globals: tfile: print object off: print derived_partial
FAIL: gdb.trace/unavailable.exp: collect globals: tfile: print object on: print derived_partial
FAIL: gdb.trace/unavailable.exp: collect globals: tfile: <unavailable> is not the same as 0 in array element repetitions
FAIL: gdb.trace/unavailable.exp: collect globals: <unavailable> is not the same as 0 in array element repetitions
FAIL: gdb.trace/unavailable.exp: unavailable locals: auto locals: info locals
FAIL: gdb.trace/unavailable.exp: unavailable locals: auto locals: tfile: info locals
FAIL: gdb.trace/unavailable.exp: unavailable locals: register locals: info locals
FAIL: gdb.trace/unavailable.exp: unavailable locals: register locals: print locd
FAIL: gdb.trace/unavailable.exp: unavailable locals: register locals: print locf
FAIL: gdb.trace/unavailable.exp: unavailable locals: register locals: tfile: info locals
FAIL: gdb.trace/unavailable.exp: unavailable locals: register locals: tfile: print locd
FAIL: gdb.trace/unavailable.exp: unavailable locals: register locals: tfile: print locf
FAIL: gdb.trace/unavailable.exp: unavailable locals: static locals: info locals
FAIL: gdb.trace/unavailable.exp: unavailable locals: static locals: tfile: info locals
KPASS: gdb.threads/process-dies-while-detaching.exp: single-process: continue: watchpoint:sw: continue (PRMS gdb/28375)
UNRESOLVED: gdb.ada/arrayptr.exp: scenario=all: gdb_breakpoint: set breakpoint at foo.adb:40
UNRESOLVED: gdb.ada/arrayptr.exp: scenario=all: runto: run to foo.adb:40 (eof)
UNRESOLVED: gdb.ada/exprs.exp: gdb_breakpoint: set breakpoint at p.adb:40
UNRESOLVED: gdb.ada/exprs.exp: runto: run to p.adb:40 (eof)
UNRESOLVED: gdb.ada/packed_array_assign.exp: gdb_breakpoint: set breakpoint at aggregates.run_test
UNRESOLVED: gdb.ada/packed_array_assign.exp: runto: run to aggregates.run_test (eof)
UNRESOLVED: gdb.ada/exprs.exp: Long_Long_Integer ** Y
UNRESOLVED: gdb.ada/exprs.exp: long_float'min
UNRESOLVED: gdb.ada/exprs.exp: long_float'max
UNRESOLVED: gdb.ada/packed_array_assign.exp: value of pra
UNRESOLVED: gdb.ada/packed_array_assign.exp: print pra(1) := pr
UNRESOLVED: gdb.ada/packed_array_assign.exp: print pra(1)
UNRESOLVED: gdb.ada/packed_array_assign.exp: value of npr
UNRESOLVED: gdb.ada/arrayptr.exp: scenario=all: gdb_breakpoint: set breakpoint at foo.adb:40 (eof)
UNRESOLVED: gdb.ada/array_return.exp: gdb_breakpoint: set breakpoint at main (eof)
UNRESOLVED: gdb.ada/array_subscript_addr.exp: gdb_breakpoint: set breakpoint at p.adb:27 (eof)
UNRESOLVED: gdb.ada/cond_lang.exp: gdb_breakpoint: set breakpoint at c_function (eof)
UNRESOLVED: gdb.ada/dyn_loc.exp: gdb_breakpoint: set breakpoint at pack.adb:25 (eof)
UNRESOLVED: gdb.ada/exprs.exp: gdb_breakpoint: set breakpoint at p.adb:40 (eof)
UNRESOLVED: gdb.ada/packed_array_assign.exp: gdb_breakpoint: set breakpoint at aggregates.run_test (eof)
UNRESOLVED: gdb.ada/ref_tick_size.exp: gdb_breakpoint: set breakpoint at p.adb:26 (eof)
UNRESOLVED: gdb.ada/set_wstr.exp: gdb_breakpoint: set breakpoint at a.adb:23 (eof)
UNRESOLVED: gdb.ada/taft_type.exp: gdb_breakpoint: set breakpoint at p.adb:22 (eof)
UNRESOLVED: gdb.base/libsegfault.exp: gdb emits custom handler warning
EOF

cat <<'EOF' > known-failures-re-native-gdbserver
EOF

cat <<'EOF' > known-failures-native-extended-gdbserver
DUPLICATE: gdb.base/cond-eval-mode.exp: awatch: awatch global
DUPLICATE: gdb.base/cond-eval-mode.exp: awatch: continue
DUPLICATE: gdb.base/cond-eval-mode.exp: break: break foo
DUPLICATE: gdb.base/cond-eval-mode.exp: break: continue
DUPLICATE: gdb.base/cond-eval-mode.exp: hbreak: continue
DUPLICATE: gdb.base/cond-eval-mode.exp: hbreak: hbreak foo
DUPLICATE: gdb.base/cond-eval-mode.exp: rwatch: continue
DUPLICATE: gdb.base/cond-eval-mode.exp: rwatch: rwatch global
DUPLICATE: gdb.base/cond-eval-mode.exp: watch: continue
DUPLICATE: gdb.base/cond-eval-mode.exp: watch: watch global
DUPLICATE: gdb.threads/attach-into-signal.exp: threaded: thread apply 2 print $_siginfo.si_signo
DUPLICATE: gdb.trace/circ.exp: check whether setting trace buffer size is supported
DUPLICATE: gdb.trace/ftrace-lock.exp: successfully compiled posix threads test case
DUPLICATE: gdb.trace/mi-tsv-changed.exp: create delete modify: tvariable $tvar3 modified
DUPLICATE: gdb.trace/signal.exp: get integer valueof "counter"
DUPLICATE: gdb.trace/status-stop.exp: buffer_full_tstart: tstart
DUPLICATE: gdb.trace/status-stop.exp: tstart_tstop_tstart: tstart
DUPLICATE: gdb.trace/tfind.exp: 8.17: tfind none
DUPLICATE: gdb.trace/trace-buffer-size.exp: set tracepoint at test_function
DUPLICATE: gdb.trace/trace-buffer-size.exp: tstart
DUPLICATE: gdb.trace/trace-mt.exp: successfully compiled posix threads test case
DUPLICATE: gdb.trace/tspeed.exp: advance through tracing (the program is no longer running)
DUPLICATE: gdb.trace/tspeed.exp: advance to trace begin (the program is no longer running)
DUPLICATE: gdb.trace/tspeed.exp: check on trace status
DUPLICATE: gdb.trace/tspeed.exp: print iters = init_iters
DUPLICATE: gdb.trace/tspeed.exp: runto: run to main
DUPLICATE: gdb.trace/tspeed.exp: start trace experiment
FAIL: gdb.ada/mi_var_access.exp: Create varobj (unexpected output)
FAIL: gdb.ada/mi_var_access.exp: update at stop 2 (unexpected output)
FAIL: gdb.ada/packed_array_assign.exp: value of pra
FAIL: gdb.arch/ftrace-insn-reloc.exp: runto: run to main
FAIL: gdb.base/a2-run.exp: run "a2-run" with shell (timeout)
FAIL: gdb.base/attach.exp: do_command_attach_tests: gdb_spawn_attach_cmdline: info thread (no thread)
FAIL: gdb.base/attach.exp: do_command_attach_tests: gdb_spawn_attach_cmdline: start gdb with --pid
FAIL: gdb.base/break-interp.exp: ldprelink=NO: ldsepdebug=IN: binprelink=NO: binsepdebug=NO: binpie=NO: INNER: symbol-less: entry point reached (the program is no longer running)
FAIL: gdb.base/break-interp.exp: ldprelink=NO: ldsepdebug=IN: binprelink=NO: binsepdebug=NO: binpie=NO: INNER: symbol-less: reach-(_dl_debug_state|dl_main)-3: reach
FAIL: gdb.base/break-interp.exp: ldprelink=NO: ldsepdebug=IN: binprelink=NO: binsepdebug=NO: binpie=YES: INNER: symbol-less: entry point reached (the program is no longer running)
FAIL: gdb.base/break-interp.exp: ldprelink=NO: ldsepdebug=IN: binprelink=NO: binsepdebug=NO: binpie=YES: INNER: symbol-less: reach-(_dl_debug_state|dl_main)-3: reach
FAIL: gdb.base/break-interp.exp: ldprelink=NO: ldsepdebug=IN: binprelink=NO: binsepdebug=NO: binpie=YES: INNER: symbol-less: reach-(_dl_debug_state|dl_main)-3: seen displacement message as NONZERO
FAIL: gdb.base/break-interp.exp: ldprelink=NO: ldsepdebug=NO: binprelink=NO: binsepdebug=NO: binpie=NO: INNER: symbol-less: entry point reached (the program is no longer running)
FAIL: gdb.base/break-interp.exp: ldprelink=NO: ldsepdebug=NO: binprelink=NO: binsepdebug=NO: binpie=NO: INNER: symbol-less: reach-(_dl_debug_state|dl_main)-3: reach
FAIL: gdb.base/break-interp.exp: ldprelink=NO: ldsepdebug=NO: binprelink=NO: binsepdebug=NO: binpie=YES: INNER: symbol-less: entry point reached (the program is no longer running)
FAIL: gdb.base/break-interp.exp: ldprelink=NO: ldsepdebug=NO: binprelink=NO: binsepdebug=NO: binpie=YES: INNER: symbol-less: reach-(_dl_debug_state|dl_main)-3: reach
FAIL: gdb.base/break-interp.exp: ldprelink=NO: ldsepdebug=NO: binprelink=NO: binsepdebug=NO: binpie=YES: INNER: symbol-less: reach-(_dl_debug_state|dl_main)-3: seen displacement message as NONZERO
FAIL: gdb.base/break-interp.exp: ldprelink=NO: ldsepdebug=NO: symbol-less: ld.so exit
FAIL: gdb.base/break-interp.exp: ldprelink=NO: ldsepdebug=NO: symbol-less: seen displacement message as NONZERO
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
FAIL: gdb.base/compare-sections.exp: after run to main: compare-sections
FAIL: gdb.base/compare-sections.exp: after run to main: compare-sections -r
FAIL: gdb.base/compare-sections.exp: read-only: compare-sections -r
FAIL: gdb.base/coredump-filter.exp: loading and testing corefile for non-Private-Shared-Anon-File: no binary: disassemble function with corefile and without a binary
FAIL: gdb.base/ending-run.exp: step out of main
FAIL: gdb.base/ending-run.exp: step to end of run
FAIL: gdb.base/gdbinit-history.exp: GDBHISTFILE is empty: show commands
FAIL: gdb.base/gdbinit-history.exp: load default history file: show commands
FAIL: gdb.base/gdbinit-history.exp: load GDBHISTFILE history file: show commands
FAIL: gdb.base/interrupt-daemon.exp: bg: continue& (timeout)
FAIL: gdb.base/interrupt-daemon.exp: bg: interrupt cmd stops process (timeout)
FAIL: gdb.base/interrupt-daemon.exp: bg: interrupt (timeout)
FAIL: gdb.base/interrupt-daemon.exp: fg: ctrl-c stops process (timeout)
FAIL: gdb.base/range-stepping.exp: step over func: next: vCont;r=2
FAIL: gdb.base/share-env-with-gdbserver.exp: strange named var: print result of getenv for 'asd ='
FAIL: gdb.base/startup-with-shell.exp: startup_with_shell = off; run_args = *.unique-extension: first argument not expanded
FAIL: gdb.base/startup-with-shell.exp: startup_with_shell = on; run_args = $TEST: testing first argument
FAIL: gdb.base/startup-with-shell.exp: startup_with_shell = on; run_args = *.unique-extension: first argument expanded
FAIL: gdb.base/with.exp: repeat: reinvoke with no previous command to relaunch
FAIL: gdb.compile/compile-cplus.exp: bt
FAIL: gdb.compile/compile-cplus.exp: compile code extern int globalshadow; globalshadow += 5;
FAIL: gdb.compile/compile-cplus.exp: print 'compile-cplus.c'::globalshadow
FAIL: gdb.compile/compile-cplus-method.exp: compile code a->get_var ()
FAIL: gdb.compile/compile-cplus-method.exp: result of compile code a->get_var ()
FAIL: gdb.compile/compile-cplus-method.exp: compile code a->get_var (static_cast<unsigned long> (1))
FAIL: gdb.compile/compile-cplus-method.exp: result of compile code a->get_var (static_cast<unsigned long> (1))
FAIL: gdb.compile/compile-cplus-method.exp: compile code a->get_var (static_cast<int> (1))
FAIL: gdb.compile/compile-cplus-method.exp: result of compile code a->get_var (static_cast<int> (1))
FAIL: gdb.compile/compile-cplus-method.exp: compile code a->get_var (static_cast<float> (1))
FAIL: gdb.compile/compile-cplus-method.exp: result of compile code a->get_var (static_cast<float> (1))
FAIL: gdb.compile/compile-cplus-method.exp: compile code a->get_var (static_cast<void *> (a))
FAIL: gdb.compile/compile-cplus-method.exp: result of compile code a->get_var (static_cast<void *> (a))
FAIL: gdb.compile/compile-cplus-method.exp: compile code a->get_var (*a)
FAIL: gdb.compile/compile-cplus-method.exp: result of compile code a->get_var (*a)
FAIL: gdb.compile/compile-cplus-method.exp: compile code a->get_var (*ac)
FAIL: gdb.compile/compile-cplus-method.exp: result of compile code a->get_var (*ac)
FAIL: gdb.compile/compile-cplus-method.exp: compile code a->get_var1 (1)
FAIL: gdb.compile/compile-cplus-method.exp: result of compile code a->get_var1 (1)
FAIL: gdb.compile/compile-cplus-method.exp: compile code a->get_var2 (1, 2)
FAIL: gdb.compile/compile-cplus-method.exp: result of compile code a->get_var2 (1, 2)
FAIL: gdb.compile/compile-cplus-method.exp: compile code A::get_1 (a->get_var ())
FAIL: gdb.compile/compile-cplus-method.exp: result of compile code A::get_1 (a->get_var ())
FAIL: gdb.compile/compile-cplus-method.exp: compile code a->get_var1 (a->get_var () - 16)
FAIL: gdb.compile/compile-cplus-method.exp: result of compile code a->get_var1 (a->get_var () - 16)
FAIL: gdb.compile/compile-cplus-method.exp: compile code a->get_var2 (a->get_var (), A::get_1 (2))
FAIL: gdb.compile/compile-cplus-method.exp: result of compile code a->get_var2 (a->get_var (), A::get_1 (2))
FAIL: gdb.compile/compile-cplus-method.exp: compile code get_value (a)
FAIL: gdb.compile/compile-cplus-method.exp: result of compile code get_value (a)
FAIL: gdb.compile/compile-cplus-method.exp: compile code (a->*pmf) (1)
FAIL: gdb.compile/compile-cplus-method.exp: result of compile code (a->*pmf) (1)
FAIL: gdb.compile/compile-cplus-method.exp: compile code pmf = &A::get_var1; var = (a->*pmf) (2); pmf = &A::get_var
FAIL: gdb.compile/compile-cplus-method.exp: result of compile code pmf = &A::get_var1; var = (a->*pmf) (2); pmf = &A::get_var
FAIL: gdb.compile/compile-cplus-method.exp: compile code (a->**pmf_p) (1)
FAIL: gdb.compile/compile-cplus-method.exp: result of compile code (a->**pmf_p) (1)
FAIL: gdb.compile/compile-cplus-virtual.exp: compile code ap->doit ()
FAIL: gdb.compile/compile-cplus-virtual.exp: compile code ap->doit2 ()
FAIL: gdb.cp/annota2.exp: annotate-quit
FAIL: gdb.cp/annota2.exp: break at main (got interactive prompt)
FAIL: gdb.cp/annota2.exp: continue until exit (timeout)
FAIL: gdb.cp/annota2.exp: delete bps
FAIL: gdb.cp/annota2.exp: set watch on a.x (timeout)
FAIL: gdb.cp/annota2.exp: watch triggered on a.x (timeout)
FAIL: gdb.cp/annota3.exp: continue to exit (pattern 4)
FAIL: gdb.cp/no-dmgl-verbose.exp: gdb_breakpoint: set breakpoint at 'f(std::string)'
FAIL: gdb.cp/step-and-next-inline.exp: no_header: next step 1
FAIL: gdb.cp/step-and-next-inline.exp: no_header: next step 2
FAIL: gdb.cp/step-and-next-inline.exp: no_header: next step 3
FAIL: gdb.cp/step-and-next-inline.exp: no_header: next step 4
FAIL: gdb.gdb/unittest.exp: executable loaded: maintenance selftest, failed none
FAIL: gdb.gdb/unittest.exp: no executable loaded: maintenance selftest, failed none
FAIL: gdb.gdb/unittest.exp: reversed initialization: maintenance selftest, failed none
FAIL: gdb.guile/scm-ports.exp: buffered: test byte at sp, before flush
FAIL: gdb.mi/list-thread-groups-available.exp: list available thread groups with filter (unexpected output)
FAIL: gdb.mi/mi-exec-run.exp: inferior-tty=separate: mi=separate: force-fail=0: breakpoint hit reported on console (timeout)
FAIL: gdb.mi/mi-pending.exp: MI pending breakpoint on mi-pendshr.c:pendfunc2 if x==4 (unexpected output)
FAIL: gdb.multi/remove-inferiors.exp: runto: run to main
FAIL: gdb.server/connect-with-no-symbol-file.exp: sysroot=: action=delete: connection to GDBserver succeeded
FAIL: gdb.server/connect-with-no-symbol-file.exp: sysroot=: action=permission: connection to GDBserver succeeded
FAIL: gdb.server/connect-with-no-symbol-file.exp: sysroot=target:: action=delete: connection to GDBserver succeeded
FAIL: gdb.server/connect-with-no-symbol-file.exp: sysroot=target:: action=permission: connection to GDBserver succeeded
FAIL: gdb.threads/access-mem-running-thread-exit.exp: non-stop: access mem (print global_var after writing again, inf=2, iter=1)
FAIL: gdb.threads/attach-into-signal.exp: threaded: thread apply 2 print $_siginfo.si_signo
FAIL: gdb.threads/attach-non-stop.exp: target-non-stop=off: non-stop=off: cmd=attach&: all threads running
FAIL: gdb.threads/attach-non-stop.exp: target-non-stop=off: non-stop=off: cmd=attach&: detach
FAIL: gdb.threads/attach-stopped.exp: threaded: attach2 to stopped bt
FAIL: gdb.threads/break-while-running.exp: w/ithr: always-inserted off: non-stop: runto: run to main
FAIL: gdb.threads/break-while-running.exp: w/ithr: always-inserted on: non-stop: runto: run to main
FAIL: gdb.threads/break-while-running.exp: wo/ithr: always-inserted off: non-stop: runto: run to main
FAIL: gdb.threads/break-while-running.exp: wo/ithr: always-inserted on: non-stop: runto: run to main
FAIL: gdb.threads/gcore-stale-thread.exp: runto: run to main
FAIL: gdb.threads/multi-create-ns-info-thr.exp: runto: run to main
FAIL: gdb.threads/multiple-successive-infcall.exp: thread=3: created new thread
FAIL: gdb.threads/multiple-successive-infcall.exp: thread=4: created new thread
FAIL: gdb.threads/multiple-successive-infcall.exp: thread=5: created new thread
FAIL: gdb.threads/non-stop-fair-events.exp: runto: run to main
FAIL: gdb.threads/process-dies-while-detaching.exp: single-process: continue: killed outside: continue
FAIL: gdb.threads/signal-command-handle-nopass.exp: step-over yes: signal SIGUSR1
FAIL: gdb.threads/signal-command-handle-nopass.exp: step-over no: signal SIGUSR1
FAIL: gdb.threads/signal-sigtrap.exp: sigtrap thread 1: signal SIGTRAP reaches handler
FAIL: gdb.threads/thread-execl.exp: non-stop: runto: run to main
FAIL: gdb.threads/thread-specific-bp.exp: all-stop: continue to end (timeout)
FAIL: gdb.threads/thread-specific-bp.exp: non-stop: runto: run to main
FAIL: gdb.threads/tls.exp: print a_thread_local
FAIL: gdb.trace/actions.exp: tfile: tracepoint on gdb_asm_test
FAIL: gdb.trace/actions.exp: tfile: tracepoint on gdb_c_test
FAIL: gdb.trace/actions.exp: tfile: tracepoint on gdb_recursion_test 0
FAIL: gdb.trace/change-loc.exp: 1 ftrace: runto: run to main
FAIL: gdb.trace/change-loc.exp: 1 trace: continue to marker 2
FAIL: gdb.trace/change-loc.exp: 1 trace: continue to marker 3
FAIL: gdb.trace/change-loc.exp: 1 trace: tfind frame 0
FAIL: gdb.trace/change-loc.exp: 1 trace: tracepoint with two locations - installed (unload)
FAIL: gdb.trace/change-loc.exp: 1 trace: tracepoint with two locations - pending (unload)
FAIL: gdb.trace/change-loc.exp: 2 ftrace: continue to marker 1 (the program is no longer running)
FAIL: gdb.trace/change-loc.exp: 2 ftrace: continue to marker 2 (the program is no longer running)
FAIL: gdb.trace/change-loc.exp: 2 ftrace: continue to marker 3 (the program is no longer running)
FAIL: gdb.trace/change-loc.exp: 2 ftrace: run to main (the program exited)
FAIL: gdb.trace/change-loc.exp: 2 ftrace: tfind frame 0
FAIL: gdb.trace/change-loc.exp: 2 ftrace: tfind frame 1
FAIL: gdb.trace/change-loc.exp: 2 ftrace: tfind frame 2
FAIL: gdb.trace/change-loc.exp: 2 ftrace: tracepoint with three locations
FAIL: gdb.trace/change-loc.exp: 2 ftrace: tracepoint with two locations - installed (unload)
FAIL: gdb.trace/change-loc.exp: 2 ftrace: tracepoint with two locations - pending (unload)
FAIL: gdb.trace/change-loc.exp: 2 ftrace: tstart
FAIL: gdb.trace/change-loc.exp: 2 ftrace: tstop
FAIL: gdb.trace/change-loc.exp: 2 trace: continue to marker 2
FAIL: gdb.trace/change-loc.exp: 2 trace: continue to marker 3
FAIL: gdb.trace/change-loc.exp: 2 trace: tfind frame 2
FAIL: gdb.trace/change-loc.exp: 2 trace: tracepoint with two locations - installed (unload)
FAIL: gdb.trace/change-loc.exp: 2 trace: tracepoint with two locations - pending (unload)
FAIL: gdb.trace/change-loc.exp: InstallInTrace disabled: ftrace: runto: run to main
FAIL: gdb.trace/collection.exp: collect register locals collectively: collected local char
FAIL: gdb.trace/collection.exp: collect register locals collectively: collected local double
FAIL: gdb.trace/collection.exp: collect register locals collectively: collected local float
FAIL: gdb.trace/collection.exp: collect register locals collectively: collected local int
FAIL: gdb.trace/collection.exp: collect register locals collectively: collected local member char
FAIL: gdb.trace/collection.exp: collect register locals collectively: collected local member double
FAIL: gdb.trace/collection.exp: collect register locals collectively: collected local member float
FAIL: gdb.trace/collection.exp: collect register locals collectively: collected local member int
FAIL: gdb.trace/collection.exp: collect register locals collectively: collected locarray #0
FAIL: gdb.trace/collection.exp: collect register locals collectively: collected locarray #1
FAIL: gdb.trace/collection.exp: collect register locals collectively: collected locarray #2
FAIL: gdb.trace/collection.exp: collect register locals collectively: collected locarray #3
FAIL: gdb.trace/collection.exp: collect register locals collectively: run trace experiment: start trace experiment
FAIL: gdb.trace/collection.exp: collect register locals collectively: run trace experiment: tfind test frame
FAIL: gdb.trace/collection.exp: collect register locals collectively: start trace experiment
FAIL: gdb.trace/collection.exp: collect register locals collectively: tfind test frame
FAIL: gdb.trace/collection.exp: collect register locals individually: collected local char
FAIL: gdb.trace/collection.exp: collect register locals individually: collected local double
FAIL: gdb.trace/collection.exp: collect register locals individually: collected local float
FAIL: gdb.trace/collection.exp: collect register locals individually: collected local int
FAIL: gdb.trace/collection.exp: collect register locals individually: collected local member char
FAIL: gdb.trace/collection.exp: collect register locals individually: collected local member double
FAIL: gdb.trace/collection.exp: collect register locals individually: collected local member float
FAIL: gdb.trace/collection.exp: collect register locals individually: collected local member int
FAIL: gdb.trace/collection.exp: collect register locals individually: collected locarray #0
FAIL: gdb.trace/collection.exp: collect register locals individually: collected locarray #1
FAIL: gdb.trace/collection.exp: collect register locals individually: collected locarray #2
FAIL: gdb.trace/collection.exp: collect register locals individually: collected locarray #3
FAIL: gdb.trace/collection.exp: collect register locals individually: define actions
FAIL: gdb.trace/ftrace.exp: runto: run to main
FAIL: gdb.trace/ftrace-lock.exp: runto: run to main
FAIL: gdb.trace/mi-trace-frame-collected.exp: tfile: -trace-frame-collected (unexpected output)
FAIL: gdb.trace/mi-trace-frame-collected.exp: tfile: -trace-frame-collected --var-print-values 2 --comp-print-values --simple-values --registers-format x --memory-contents (unexpected output)
FAIL: gdb.trace/mi-tsv-changed.exp: create delete modify: tvariable $tvar3 modified (unexpected output)
FAIL: gdb.trace/pending.exp: ftrace action_resolved: runto: run to main
FAIL: gdb.trace/pending.exp: ftrace disconn_resolved: runto: run to main
FAIL: gdb.trace/pending.exp: ftrace disconn: runto: run to main
FAIL: gdb.trace/pending.exp: ftrace installed_in_trace: runto: run to main
FAIL: gdb.trace/pending.exp: ftrace resolved_in_trace: runto: run to main
FAIL: gdb.trace/pending.exp: ftrace resolved: (the program exited)
FAIL: gdb.trace/pending.exp: ftrace works: continue to marker (the program is no longer running)
FAIL: gdb.trace/pending.exp: ftrace works: start trace experiment
FAIL: gdb.trace/pending.exp: ftrace works: tfind test frame 0
FAIL: gdb.trace/pending.exp: ftrace works: tfind test frame 1
FAIL: gdb.trace/pending.exp: ftrace works: tfind test frame 2
FAIL: gdb.trace/pending.exp: ftrace works: (the program exited)
FAIL: gdb.trace/pending.exp: trace installed_in_trace: continue to marker 2
FAIL: gdb.trace/pending.exp: trace installed_in_trace: tfind test frame 0
FAIL: gdb.trace/range-stepping.exp: runto: run to main
FAIL: gdb.trace/trace-break.exp: runto: run to main
FAIL: gdb.trace/trace-condition.exp: runto: run to main
FAIL: gdb.trace/trace-enable-disable.exp: test_tracepoint_enable_disable ftrace: runto: run to main
FAIL: gdb.trace/trace-enable-disable.exp: test_tracepoint_enable_disable trace: runto: run to main
FAIL: gdb.trace/trace-mt.exp: runto: run to main
FAIL: gdb.trace/tspeed.exp: gdb_fast_trace_speed_test: advance through tracing (the program is no longer running)
FAIL: gdb.trace/tspeed.exp: gdb_fast_trace_speed_test: advance to trace begin (the program is no longer running)
FAIL: gdb.trace/tspeed.exp: gdb_fast_trace_speed_test: start trace experiment
FAIL: gdb.trace/tspeed.exp: gdb_slow_trace_speed_test: advance through tracing (the program is no longer running)
FAIL: gdb.trace/tspeed.exp: gdb_slow_trace_speed_test: advance to trace begin (the program is no longer running)
FAIL: gdb.trace/tspeed.exp: gdb_slow_trace_speed_test: start trace experiment
FAIL: gdb.trace/tspeed.exp: runto: run to main
FAIL: gdb.trace/tspeed.exp: runto: run to main
FAIL: gdb.trace/unavailable.exp: collect globals: print object off: print derived_partial
FAIL: gdb.trace/unavailable.exp: collect globals: print object on: print derived_partial
FAIL: gdb.trace/unavailable.exp: collect globals: tfile: print object off: print derived_partial
FAIL: gdb.trace/unavailable.exp: collect globals: tfile: print object on: print derived_partial
FAIL: gdb.trace/unavailable.exp: collect globals: tfile: <unavailable> is not the same as 0 in array element repetitions
FAIL: gdb.trace/unavailable.exp: collect globals: <unavailable> is not the same as 0 in array element repetitions
FAIL: gdb.trace/unavailable.exp: unavailable locals: auto locals: info locals
FAIL: gdb.trace/unavailable.exp: unavailable locals: auto locals: tfile: info locals
FAIL: gdb.trace/unavailable.exp: unavailable locals: register locals: info locals
FAIL: gdb.trace/unavailable.exp: unavailable locals: register locals: print locd
FAIL: gdb.trace/unavailable.exp: unavailable locals: register locals: print locf
FAIL: gdb.trace/unavailable.exp: unavailable locals: register locals: tfile: info locals
FAIL: gdb.trace/unavailable.exp: unavailable locals: register locals: tfile: print locd
FAIL: gdb.trace/unavailable.exp: unavailable locals: register locals: tfile: print locf
FAIL: gdb.trace/unavailable.exp: unavailable locals: static locals: info locals
FAIL: gdb.trace/unavailable.exp: unavailable locals: static locals: tfile: info locals
KPASS: gdb.threads/process-dies-while-detaching.exp: single-process: continue: watchpoint:sw: continue (PRMS gdb/28375)
UNRESOLVED: gdb.ada/arrayptr.exp: scenario=all: gdb_breakpoint: set breakpoint at foo.adb:40
UNRESOLVED: gdb.ada/arrayptr.exp: scenario=all: runto: run to foo.adb:40 (eof)
UNRESOLVED: gdb.ada/exprs.exp: gdb_breakpoint: set breakpoint at p.adb:40
UNRESOLVED: gdb.ada/exprs.exp: runto: run to p.adb:40 (eof)
UNRESOLVED: gdb.ada/packed_array_assign.exp: gdb_breakpoint: set breakpoint at aggregates.run_test
UNRESOLVED: gdb.ada/packed_array_assign.exp: runto: run to aggregates.run_test (eof)
UNRESOLVED: gdb.ada/exprs.exp: Long_Long_Integer ** Y
UNRESOLVED: gdb.ada/exprs.exp: long_float'min
UNRESOLVED: gdb.ada/exprs.exp: long_float'max
UNRESOLVED: gdb.ada/packed_array_assign.exp: value of pra
UNRESOLVED: gdb.ada/packed_array_assign.exp: print pra(1) := pr
UNRESOLVED: gdb.ada/packed_array_assign.exp: print pra(1)
UNRESOLVED: gdb.ada/packed_array_assign.exp: value of npr
UNRESOLVED: gdb.ada/arrayptr.exp: scenario=all: gdb_breakpoint: set breakpoint at foo.adb:40 (eof)
UNRESOLVED: gdb.ada/array_return.exp: gdb_breakpoint: set breakpoint at main (eof)
UNRESOLVED: gdb.ada/array_subscript_addr.exp: gdb_breakpoint: set breakpoint at p.adb:27 (eof)
UNRESOLVED: gdb.ada/cond_lang.exp: gdb_breakpoint: set breakpoint at c_function (eof)
UNRESOLVED: gdb.ada/dyn_loc.exp: gdb_breakpoint: set breakpoint at pack.adb:25 (eof)
UNRESOLVED: gdb.ada/exprs.exp: gdb_breakpoint: set breakpoint at p.adb:40 (eof)
UNRESOLVED: gdb.ada/packed_array_assign.exp: gdb_breakpoint: set breakpoint at aggregates.run_test (eof)
UNRESOLVED: gdb.ada/ref_tick_size.exp: gdb_breakpoint: set breakpoint at p.adb:26 (eof)
UNRESOLVED: gdb.ada/set_wstr.exp: gdb_breakpoint: set breakpoint at a.adb:23 (eof)
UNRESOLVED: gdb.ada/taft_type.exp: gdb_breakpoint: set breakpoint at p.adb:22 (eof)
UNRESOLVED: gdb.base/readline-ask.exp: bell for more message
UNRESOLVED: gdb.threads/attach-into-signal.exp: threaded: attach (pass 2), pending signal catch
EOF

cat <<'EOF' > known-failures-re-native-extended-gdbserver
FAIL: gdb.threads/attach-many-short-lived-threads.exp: .*
EOF

known_failures_file="known-failures-${target_board}"
known_failures_re_file="known-failures-re-${target_board}"
grep --invert-match --fixed-strings --file="$known_failures_file" "${WORKSPACE}/results/gdb.sum" | \
    grep --invert-match --extended-regexp --file="$known_failures_re_file" > "${WORKSPACE}/results/gdb.filtered.sum"
grep --extended-regexp --regexp="^(FAIL|XPASS|UNRESOLVED|DUPLICATE):" "${WORKSPACE}/results/gdb.filtered.sum" > "${WORKSPACE}/results/gdb.fail.sum" || true

# For informational purposes: check if some known failure lines did not appear
# in the gdb.sum.
echo "Known failures that don't appear in gdb.sum:"
while read line; do
    if ! grep --silent --fixed-strings "$line" "${WORKSPACE}/results/gdb.sum"; then
        echo "$line"
    fi
done < "$known_failures_file" > "${WORKSPACE}/results/known-failures-not-found.sum"

# Convert results to JUnit format.
failed_tests=0
sum2junit "${WORKSPACE}/results/gdb.filtered.sum" "${WORKSPACE}/results/gdb.xml" || failed_tests=1

# Clean the build directory
$MAKE clean

# Exit with failure if any of the tests failed
exit $failed_tests

# EOF
