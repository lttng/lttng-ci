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
import random
import subprocess
import sys

def save_instr_points(instr_points):

    # Save in /root to be persistent across lava slave reboots.
    instrumenation_points_arch = '/root/instr_points.txt.gz'

    print('Saving instrumentation points to \'{}\' ...'.format(instrumenation_points_arch), end='')
    sys.stdout.flush()

    text = "\n".join(instr_points)

    with gzip.open(instrumenation_points_arch, 'w') as f:
        f.write(text.encode('utf-8'))

    # Attach fuzzing data to test case.
    events = ['lava-test-case-attach', 'generate-fuzzing-data', instrumenation_points_arch]

    try:
        subprocess.call(events)
    except OSError as e:
        print("Execution failed:", e, file=sys.stderr)
        print("Probably not running on the lava worker")
        pprint.pprint(events)
    print('Done.')

def main():
    assert(len(sys.argv) == 2)

    seed = int(sys.argv[1])
    print('Random seed: {}'.format(seed))

    rng = random.Random(seed)

    # Get all the symbols from kallsyms.
    with open('/proc/kallsyms') as kallsyms_file:
        raw_symbol_list = kallsyms_file.readlines()

    # Keep only the symbol name.
    raw_symbol_list = [x.split()[2].strip() for x in raw_symbol_list]

    instrumentation_points = []

    # Add all symbols.
    instrumentation_points.extend(raw_symbol_list)

    # For each symbol, create 2 new instrumentation points by random offsets.
    for s in raw_symbol_list:
        offsets = rng.sample(range(1, 10), 2)
        for offset in offsets:
            instrumentation_points.append(s + "+" + str(hex(offset)))

    lower_bound = 0x0
    upper_bound = 0xffffffffffffffff
    address_list = []

    # Add random addresses to the instrumentation points.
    for _ in range(1000):
        instrumentation_points.append(hex(rng.randint(lower_bound, upper_bound)))

    # Shuffle the entire list.
    rng.shuffle(instrumentation_points)

    # Save instrumentation points to disk and attach it to lava test run.
    save_instr_points(instrumentation_points)

if __name__ == "__main__":
    main()
