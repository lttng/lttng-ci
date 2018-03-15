# Copyright (C) 2018 - Francis Deslauriers <francis.deslauriers@efficios.com>
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

import datetime
import gzip
import os
import pprint
import subprocess
import sys

NB_KPROBES_PER_ITER=500
NB_KPROBES_PER_ROUND=20000

def load_instr_points(instr_points_archive):
    print('Reading instrumentation points from \'{}\'.'.format(instr_points_archive), end='')
    sys.stdout.flush()

    with gzip.open(instr_points_archive, 'r') as f:
        data = f.read()
    print(' Done.')

    return [x.decode('utf-8') for x in data.split()]

def enable_kprobe_events(instr_points):
    print('Enabling events from {} to {}...'.format(instr_points[0], instr_points[-1]), end='')
    sys.stdout.flush()

    # Use os module directly, because this is a sysfs file and seeking inside
    # the file is not supported. The python open() function with the append
    # ('a') flag uses lseek(, SEEK_END) to move the write pointer to the end.
    fd = os.open('/sys/kernel/debug/tracing/kprobe_events', os.O_WRONLY|os.O_CREAT|os.O_APPEND)
    for i, point in enumerate(instr_points):

        kprobe_cmd = 'r:event_{} {}\n'.format(i, point).encode('utf-8')
        try:
            os.write(fd, kprobe_cmd)
        except OSError:
            continue
    os.close(fd)
    print(' Done.')

def set_kprobe_tracing_state(state):
    if state not in (0 ,1):
        raise ValueError

    try:
        with open('/sys/kernel/debug/tracing/events/kprobes/enable', 'w') as enable_kprobe_file:
            enable_kprobe_file.write('{}\n'.format(state))
    except IOError:
        print('kprobes/enable file does not exist')

    if state == 0:
        # Clear the content of the trace.
        open('/sys/kernel/debug/tracing/trace', 'w').close()
        # Clear all the events.
        open('/sys/kernel/debug/tracing/kprobe_events', 'w').close()

def run_workload():
    print('Running workload...', end='')
    sys.stdout.flush()
    workload = ['stress', '--cpu', '2', '--io', '4', '--vm', '2',
                '--vm-bytes', '128M', '--hdd', '3', '--timeout', '3s']
    try:
        with open(os.devnull) as devnull:
            subprocess.call(workload, stdout=devnull, stderr=devnull)
    except OSError as e:
        print("Workload execution failed:", e, file=sys.stderr)
        pprint.pprint(workload)

    print(' Done.')

def mount_tracingfs():
    with open(os.devnull) as devnull:
        subprocess.call(['mount', '-t', 'debugfs', 'nodev', '/sys/kernel/debug/'],
                stdout=devnull, stderr=devnull)

def print_dashed_line():
    print('-'*100)

def main():
    assert(len(sys.argv) == 3)

    instr_point_archive = sys.argv[1]
    round_nb = int(sys.argv[2])
    # Load instrumentation points to disk and attach it to lava test run.
    instrumentation_points = load_instr_points(instr_point_archive)

    # We are past the end of the instrumentation point list.
    if len(instrumentation_points)/NB_KPROBES_PER_ROUND <= round_nb:
        print('No instrumentation point for round {}.'.format(round_nb))
        return

    mount_tracingfs()

    # Loop over the list by enabling ranges of NB_KPROBES_PER_ITER kprobes.
    for i in range(int(NB_KPROBES_PER_ROUND/NB_KPROBES_PER_ITER)):
        print_dashed_line()
        lower_bound = (round_nb * NB_KPROBES_PER_ROUND) + (i * NB_KPROBES_PER_ITER)
        upper_bound = lower_bound + NB_KPROBES_PER_ITER
        print('Time now: {}, {} to {}'.format(datetime.datetime.now(), lower_bound , upper_bound))
        enable_kprobe_events(instrumentation_points[lower_bound:upper_bound])
        set_kprobe_tracing_state(1)
        run_workload()
        print('\n')
        set_kprobe_tracing_state(0)

if __name__ == "__main__":
    main()
