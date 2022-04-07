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

arch=${arch:-}
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
    CONF_OPTS+=("--disable-binutils" "--disable-ld" "--disable-gold" "--disable-gas" "--disable-sim" "--disable-gprof" "--disable-gprofng")

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
FAIL: gdb.ada/task_switch_in_core.exp: save a corefile (timeout)
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
FAIL: gdb.base/interrupt-daemon.exp: bg: continue& (timeout)
FAIL: gdb.base/interrupt-daemon.exp: bg: interrupt cmd stops process (timeout)
FAIL: gdb.base/interrupt-daemon.exp: bg: interrupt (timeout)
FAIL: gdb.base/interrupt-daemon.exp: fg: ctrl-c stops process (timeout)
FAIL: gdb.cp/no-dmgl-verbose.exp: setting breakpoint at 'f(std::string)'
FAIL: gdb.threads/forking-threads-plus-breakpoint.exp: cond_bp_target=0: detach_on_fork=on: displaced=off: inferior 1 exited (timeout)
FAIL: gdb.threads/interrupted-hand-call.exp: continue until exit
FAIL: gdb.threads/multiple-successive-infcall.exp: thread=3: created new thread
FAIL: gdb.threads/multiple-successive-infcall.exp: thread=4: created new thread
FAIL: gdb.threads/multiple-successive-infcall.exp: thread=5: created new thread
FAIL: gdb.threads/non-ldr-exit.exp: program exits normally (timeout)
FAIL: gdb.threads/process-dies-while-detaching.exp: single-process: continue: killed outside: continue
FAIL: gdb.threads/process-dies-while-detaching.exp: single-process: continue: watchpoint:hw: continue (timeout)
FAIL: gdb.threads/thread-specific-bp.exp: all-stop: continue to end (timeout)
FAIL: gdb.threads/thread-specific-bp.exp: non-stop: continue to end (timeout)
FAIL: gdb.trace/actions.exp: tfile: tracepoint on gdb_asm_test
FAIL: gdb.trace/actions.exp: tfile: tracepoint on gdb_c_test
FAIL: gdb.trace/actions.exp: tfile: tracepoint on gdb_recursion_test 0
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
FAIL: gdb.trace/mi-trace-frame-collected.exp: tfile: -trace-frame-collected (unexpected output)
FAIL: gdb.trace/mi-trace-frame-collected.exp: tfile: -trace-frame-collected --var-print-values 2 --comp-print-values --simple-values --registers-format x --memory-contents (unexpected output)
FAIL: gdb.trace/pending.exp: ftrace resolved: (the program exited)
FAIL: gdb.trace/pending.exp: ftrace works: continue to marker (the program is no longer running)
FAIL: gdb.trace/pending.exp: ftrace works: start trace experiment
FAIL: gdb.trace/pending.exp: ftrace works: tfind test frame 0
FAIL: gdb.trace/pending.exp: ftrace works: tfind test frame 1
FAIL: gdb.trace/pending.exp: ftrace works: tfind test frame 2
FAIL: gdb.trace/pending.exp: ftrace works: (the program exited)
FAIL: gdb.trace/pending.exp: trace installed_in_trace: continue to marker 2
FAIL: gdb.trace/pending.exp: trace installed_in_trace: tfind test frame 0
FAIL: gdb.trace/unavailable.exp: collect globals: print object off: print derived_partial
FAIL: gdb.trace/unavailable.exp: collect globals: print object on: print derived_partial
FAIL: gdb.trace/unavailable.exp: collect globals: tfile: print object off: print derived_partial
FAIL: gdb.trace/unavailable.exp: collect globals: tfile: print object on: print derived_partial
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
UNRESOLVED: gdb.base/libsegfault.exp: gdb emits custom handler warning
UNRESOLVED: gdb.base/readline-ask.exp: bell for more message
UNRESOLVED: gdb.base/symbol-without-target_section.exp: list -q main
UNRESOLVED: gdb.dwarf2/dw2-icc-opaque.exp: ptype p_struct
FAIL: gdb.arch/ftrace-insn-reloc.exp: running to main in runto
FAIL: gdb.dwarf2/clztest.exp: running to main in runto
FAIL: gdb.dwarf2/dw2-inline-param.exp: running to *0x608 in runto
FAIL: gdb.multi/multi-re-run.exp: re_run_inf=1: iter=1: running to all_started in runto
FAIL: gdb.multi/multi-re-run.exp: re_run_inf=2: iter=1: running to all_started in runto
KPASS: gdb.threads/process-dies-while-detaching.exp: single-process: continue: watchpoint:sw: continue (PRMS gdb/28375)
FAIL: gdb.trace/change-loc.exp: 1 ftrace: running to main in runto
FAIL: gdb.trace/change-loc.exp: InstallInTrace disabled: ftrace: running to main in runto
FAIL: gdb.trace/ftrace-lock.exp: running to main in runto
FAIL: gdb.trace/ftrace.exp: running to main in runto
FAIL: gdb.trace/pending.exp: ftrace action_resolved: running to main in runto
FAIL: gdb.trace/pending.exp: ftrace disconn: running to main in runto
FAIL: gdb.trace/pending.exp: ftrace disconn_resolved: running to main in runto
FAIL: gdb.trace/pending.exp: ftrace installed_in_trace: running to main in runto
FAIL: gdb.trace/pending.exp: ftrace resolved_in_trace: running to main in runto
FAIL: gdb.trace/range-stepping.exp: running to main in runto
FAIL: gdb.trace/trace-break.exp: running to main in runto
FAIL: gdb.trace/trace-condition.exp: running to main in runto
FAIL: gdb.trace/trace-enable-disable.exp: test_tracepoint_enable_disable ftrace: running to main in runto
FAIL: gdb.trace/trace-enable-disable.exp: test_tracepoint_enable_disable trace: running to main in runto
FAIL: gdb.trace/trace-mt.exp: running to main in runto
FAIL: gdb.trace/tspeed.exp: running to main in runto
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
FAIL: gdb.multi/multi-re-run.exp: re_run_inf=1: iter=2: continue until exit
FAIL: gdb.multi/multi-re-run.exp: re_run_inf=1: iter=2: print re_run_var_1
FAIL: gdb.multi/multi-re-run.exp: re_run_inf=2: iter=2: continue until exit
FAIL: gdb.multi/multi-re-run.exp: re_run_inf=2: iter=2: print re_run_var_2
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
DUPLICATE: gdb.trace/tspeed.exp: start trace experiment
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
FAIL: gdb.base/a2-run.exp: run "a2-run" with shell (timeout)
FAIL: gdb.base/attach.exp: do_command_attach_tests: starting with --pid
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
FAIL: gdb.base/gdbinit-history.exp: GDBHISTFILE is empty: show commands
FAIL: gdb.base/gdbinit-history.exp: load default history file: show commands
FAIL: gdb.base/gdbinit-history.exp: load GDBHISTFILE history file: show commands
FAIL: gdb.base/interrupt-daemon.exp: bg: continue& (timeout)
FAIL: gdb.base/interrupt-daemon.exp: bg: interrupt cmd stops process (timeout)
FAIL: gdb.base/interrupt-daemon.exp: bg: interrupt (timeout)
FAIL: gdb.base/interrupt-daemon.exp: fg: ctrl-c stops process (timeout)
FAIL: gdb.base/share-env-with-gdbserver.exp: strange named var: print result of getenv for 'asd ='
FAIL: gdb.base/startup-with-shell.exp: startup_with_shell = on; run_args = $TEST: testing first argument
FAIL: gdb.base/startup-with-shell.exp: startup_with_shell = on; run_args = *.unique-extension: first argument expanded
FAIL: gdb.base/with.exp: repeat: reinvoke with no previous command to relaunch
FAIL: gdb.cp/annota2.exp: annotate-quit
FAIL: gdb.cp/annota2.exp: break at main (got interactive prompt)
FAIL: gdb.cp/annota2.exp: continue until exit (timeout)
FAIL: gdb.cp/annota2.exp: delete bps
FAIL: gdb.cp/annota2.exp: set watch on a.x (timeout)
FAIL: gdb.cp/annota2.exp: watch triggered on a.x (timeout)
FAIL: gdb.cp/annota3.exp: continue to exit (pattern 4)
FAIL: gdb.cp/no-dmgl-verbose.exp: setting breakpoint at 'f(std::string)'
FAIL: gdb.gdb/unittest.exp: executable loaded: maintenance selftest, failed none
FAIL: gdb.gdb/unittest.exp: no executable loaded: maintenance selftest, failed none
FAIL: gdb.mi/mi-exec-run.exp: inferior-tty=separate: mi=separate: force-fail=0: breakpoint hit reported on console (timeout)
FAIL: gdb.mi/mi-pending.exp: MI pending breakpoint on mi-pendshr.c:pendfunc2 if x==4 (unexpected output)
FAIL: gdb.multi/multi-re-run.exp: re_run_inf=1: iter=2: continue until exit
FAIL: gdb.multi/multi-re-run.exp: re_run_inf=1: iter=2: print re_run_var_1
FAIL: gdb.python/py-events.exp: get current thread
FAIL: gdb.server/connect-with-no-symbol-file.exp: sysroot=: action=delete: connection to GDBserver succeeded
FAIL: gdb.server/connect-with-no-symbol-file.exp: sysroot=: action=permission: connection to GDBserver succeeded
FAIL: gdb.server/connect-with-no-symbol-file.exp: sysroot=target:: action=delete: connection to GDBserver succeeded
FAIL: gdb.server/connect-with-no-symbol-file.exp: sysroot=target:: action=permission: connection to GDBserver succeeded
FAIL: gdb.threads/attach-into-signal.exp: threaded: thread apply 2 print $_siginfo.si_signo
FAIL: gdb.threads/detach-step-over.exp: breakpoint-condition-evaluation=host: target-non-stop=off: non-stop=off: displaced=off: iter 1: all threads running (GDB internal error)
FAIL: gdb.threads/detach-step-over.exp: breakpoint-condition-evaluation=target: target-non-stop=on: non-stop=off: displaced=off: iter 1: stop with SIGUSR1 (timeout)
FAIL: gdb.threads/detach-step-over.exp: breakpoint-condition-evaluation=target: target-non-stop=on: non-stop=off: displaced=off: iter 2: all threads running
FAIL: gdb.threads/detach-step-over.exp: breakpoint-condition-evaluation=target: target-non-stop=on: non-stop=off: displaced=off: iter 2: stop with SIGUSR1 (timeout)
FAIL: gdb.threads/detach-step-over.exp: breakpoint-condition-evaluation=target: target-non-stop=on: non-stop=off: displaced=off: iter 3: all threads running
FAIL: gdb.threads/detach-step-over.exp: breakpoint-condition-evaluation=target: target-non-stop=on: non-stop=off: displaced=off: iter 3: attach (got interactive prompt)
FAIL: gdb.threads/detach-step-over.exp: breakpoint-condition-evaluation=target: target-non-stop=on: non-stop=off: displaced=off: iter 3: stop with SIGUSR1 (timeout)
FAIL: gdb.threads/forking-threads-plus-breakpoint.exp: cond_bp_target=0: detach_on_fork=on: displaced=off: inferior 1 exited (timeout)
FAIL: gdb.threads/multiple-successive-infcall.exp: thread=3: created new thread
FAIL: gdb.threads/multiple-successive-infcall.exp: thread=4: created new thread
FAIL: gdb.threads/multiple-successive-infcall.exp: thread=5: created new thread
FAIL: gdb.threads/non-ldr-exit.exp: program exits normally (timeout)
FAIL: gdb.threads/process-dies-while-detaching.exp: single-process: continue: killed outside: continue
FAIL: gdb.threads/process-dies-while-detaching.exp: single-process: continue: watchpoint:hw: continue (timeout)
FAIL: gdb.threads/thread-specific-bp.exp: all-stop: continue to end (timeout)
FAIL: gdb.threads/tls.exp: print a_thread_local
FAIL: gdb.trace/actions.exp: tfile: tracepoint on gdb_asm_test
FAIL: gdb.trace/actions.exp: tfile: tracepoint on gdb_c_test
FAIL: gdb.trace/actions.exp: tfile: tracepoint on gdb_recursion_test 0
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
FAIL: gdb.trace/mi-trace-frame-collected.exp: tfile: -trace-frame-collected (unexpected output)
FAIL: gdb.trace/mi-trace-frame-collected.exp: tfile: -trace-frame-collected --var-print-values 2 --comp-print-values --simple-values --registers-format x --memory-contents (unexpected output)
FAIL: gdb.trace/pending.exp: ftrace resolved: (the program exited)
FAIL: gdb.trace/pending.exp: ftrace works: continue to marker (the program is no longer running)
FAIL: gdb.trace/pending.exp: ftrace works: start trace experiment
FAIL: gdb.trace/pending.exp: ftrace works: tfind test frame 0
FAIL: gdb.trace/pending.exp: ftrace works: tfind test frame 1
FAIL: gdb.trace/pending.exp: ftrace works: tfind test frame 2
FAIL: gdb.trace/pending.exp: ftrace works: (the program exited)
FAIL: gdb.trace/pending.exp: trace installed_in_trace: continue to marker 2
FAIL: gdb.trace/pending.exp: trace installed_in_trace: tfind test frame 0
FAIL: gdb.trace/tspeed.exp: advance through tracing (the program is no longer running)
FAIL: gdb.trace/tspeed.exp: advance through tracing (the program is no longer running)
FAIL: gdb.trace/tspeed.exp: advance to trace begin (the program is no longer running)
FAIL: gdb.trace/tspeed.exp: advance to trace begin (the program is no longer running)
FAIL: gdb.trace/tspeed.exp: start trace experiment
FAIL: gdb.trace/tspeed.exp: start trace experiment
FAIL: gdb.trace/unavailable.exp: collect globals: print object off: print derived_partial
FAIL: gdb.trace/unavailable.exp: collect globals: print object on: print derived_partial
FAIL: gdb.trace/unavailable.exp: collect globals: tfile: print object off: print derived_partial
FAIL: gdb.trace/unavailable.exp: collect globals: tfile: print object on: print derived_partial
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
UNRESOLVED: gdb.base/libsegfault.exp: gdb emits custom handler warning
UNRESOLVED: gdb.base/readline-ask.exp: bell for more message
UNRESOLVED: gdb.base/symbol-without-target_section.exp: list -q main
UNRESOLVED: gdb.dwarf2/dw2-icc-opaque.exp: ptype p_struct
UNRESOLVED: gdb.mi/mi-exec-run.exp: inferior-tty=main: mi=main: force-fail=1: run failure detected (eof)
UNRESOLVED: gdb.mi/mi-exec-run.exp: inferior-tty=main: mi=separate: force-fail=1: run failure detected (eof)
UNRESOLVED: gdb.mi/mi-exec-run.exp: inferior-tty=separate: mi=main: force-fail=1: run failure detected (eof)
UNRESOLVED: gdb.mi/mi-exec-run.exp: inferior-tty=separate: mi=separate: force-fail=1: run failure detected (eof)
UNRESOLVED: gdb.threads/attach-into-signal.exp: threaded: attach (pass 2), pending signal catch
FAIL: gdb.arch/ftrace-insn-reloc.exp: running to main in runto
FAIL: gdb.dwarf2/dw2-inline-param.exp: running to *0x608 in runto
FAIL: gdb.multi/remove-inferiors.exp: running to main in runto
FAIL: gdb.threads/access-mem-running-thread-exit.exp: non-stop: second inferior: running to main in runto
FAIL: gdb.threads/break-while-running.exp: w/ithr: always-inserted off: non-stop: running to main in runto
FAIL: gdb.threads/break-while-running.exp: w/ithr: always-inserted on: non-stop: running to main in runto
FAIL: gdb.threads/break-while-running.exp: wo/ithr: always-inserted off: non-stop: running to main in runto
FAIL: gdb.threads/break-while-running.exp: wo/ithr: always-inserted on: non-stop: running to main in runto
FAIL: gdb.threads/gcore-stale-thread.exp: running to main in runto
FAIL: gdb.threads/multi-create-ns-info-thr.exp: running to main in runto
FAIL: gdb.threads/non-stop-fair-events.exp: running to main in runto
KPASS: gdb.threads/process-dies-while-detaching.exp: single-process: continue: watchpoint:sw: continue (PRMS gdb/28375)
FAIL: gdb.threads/thread-execl.exp: non-stop: running to main in runto
FAIL: gdb.threads/thread-specific-bp.exp: non-stop: running to main in runto
FAIL: gdb.trace/change-loc.exp: 1 ftrace: running to main in runto
FAIL: gdb.trace/change-loc.exp: InstallInTrace disabled: ftrace: running to main in runto
FAIL: gdb.trace/ftrace-lock.exp: running to main in runto
FAIL: gdb.trace/ftrace.exp: running to main in runto
FAIL: gdb.trace/pending.exp: ftrace action_resolved: running to main in runto
FAIL: gdb.trace/pending.exp: ftrace disconn: running to main in runto
FAIL: gdb.trace/pending.exp: ftrace disconn_resolved: running to main in runto
FAIL: gdb.trace/pending.exp: ftrace installed_in_trace: running to main in runto
FAIL: gdb.trace/pending.exp: ftrace resolved_in_trace: running to main in runto
FAIL: gdb.trace/range-stepping.exp: running to main in runto
FAIL: gdb.trace/trace-break.exp: running to main in runto
FAIL: gdb.trace/trace-condition.exp: running to main in runto
FAIL: gdb.trace/trace-enable-disable.exp: test_tracepoint_enable_disable ftrace: running to main in runto
FAIL: gdb.trace/trace-enable-disable.exp: test_tracepoint_enable_disable trace: running to main in runto
FAIL: gdb.trace/trace-mt.exp: running to main in runto
FAIL: gdb.trace/tspeed.exp: running to main in runto
FAIL: gdb.trace/tspeed.exp: running to main in runto
DUPLICATE: gdb.trace/tspeed.exp: running to main in runto
EOF

known_failures_file="known-failures-${target_board}"
grep --invert-match --fixed-strings --file="$known_failures_file"  "${WORKSPACE}/results/gdb.sum" > "${WORKSPACE}/results/gdb.filtered.sum"

# For informational purposes: check if some known failure lines did not appear
# in the gdb.sum.
echo "Known failures that don't appear in gdb.sum:"
while read line; do
    if ! grep --silent --fixed-strings "$line" "${WORKSPACE}/results/gdb.sum"; then
        echo "$line"
    fi
done < "$known_failures_file"

# Convert results to JUnit format.
failed_tests=0
sum2junit "${WORKSPACE}/results/gdb.filtered.sum" "${WORKSPACE}/results/gdb.xml" || failed_tests=1

# Clean the build directory
$MAKE clean

# Exit with failure if any of the tests failed
exit $failed_tests

# EOF
