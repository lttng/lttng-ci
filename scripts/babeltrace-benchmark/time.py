#!/usr/bin/python3
# Copyright (C) 2019 - Jonathan Rajotte Julien <jonathan.rajotte-julien@efficios.com>
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

import argparse
import json
import os
import subprocess
import tempfile
from collections import defaultdict


def wall_clock_parser(value):
    """
    Parse /usr/bin/time wall clock value.
    Wall clock value is expressed in different formats depending on the actual
    elapsed time.
    """
    total = 0.0
    pos = value.find(".")
    if value.find("."):
        total += float(value[pos:])
        value = value[:pos]

    v_split = value.split(":")
    if len(v_split) == 2:
        total += float(v_split[0]) * 60.0
        total += float(v_split[1]) * 1.0
    elif len(v_split) == 3:
        total += float(v_split[0]) * 360.0
        total += float(v_split[1]) * 60.0
        total += float(v_split[2]) * 1.0
    else:
        return 0.0

    return total


def percent_parser(value):
    """
    Parse /usr/bin/time percent value.
    """
    parsed = value.replace("%", "").replace("?", "")
    if parsed:
        return float(parsed)
    return 0


_METRIC = {
    "User time (seconds)": float,
    "System time (seconds)": float,
    "Percent of CPU this job got": percent_parser,
    "Elapsed (wall clock) time (h:mm:ss or m:ss)": wall_clock_parser,
    "Average shared text size (kbytes)": int,
    "Average unshared data size (kbytes)": int,
    "Average stack size (kbytes)": int,
    "Average total size (kbytes)": int,
    "Maximum resident set size (kbytes)": int,
    "Average resident set size (kbytes)": int,
    "Major (requiring I/O) page faults": int,
    "Minor (reclaiming a frame) page faults": int,
    "Voluntary context switches": int,
    "Involuntary context switches": int,
    "Swaps": int,
    "File system inputs": int,
    "File system outputs": int,
    "Socket messages sent": int,
    "Socket messages received": int,
    "Signals delivered": int,
    "Page size (bytes)": int,
}


def parse(path, results):
    """
    Parser and accumulator for /usr/bin/time results.
    """
    with open(path, "r") as data:
        for line in data:
            if line.rfind(":") == -1:
                continue
            key, value = line.lstrip().rsplit(": ")
            if key in _METRIC:
                results[key].append(_METRIC[key](value))

    return results


def save(path, results):
    """
    Save the result in json format to path.
    """
    with open(path, "w") as out:
        json.dump(results, out, sort_keys=True, indent=4)


def run(command, iteration, output, stdout, stderr):
    """
    Run the command throught /usr/bin/time n iterations and parse each result.
    """
    results = defaultdict(list)
    for i in range(iteration):
        time_stdout = tempfile.NamedTemporaryFile(delete=False)
        # We must delete this file later on.
        time_stdout.close()
        with open(stdout, "a+") as out, open(stderr, "a+") as err:
            cmd = "/usr/bin/time -v --output='{}' {}".format(time_stdout.name, command)
            ret = subprocess.run(cmd, shell=True, stdout=out, stderr=err)
            if ret.returncode != 0:
                print("Iteration: {}, Command failed: {}".format(str(i), cmd))
        results = parse(time_stdout.name, results)
        os.remove(time_stdout.name)
    save(output, results)


def main():
    """
    Run /usr/bin/time N time and collect the result.
    The resulting json have the following form:
    {
      "/usr/bin/time": {
        "User time (seconds)": [],
        "System time (seconds)": [],
        "Percent of CPU this job got": [],
        "Elapsed (wall clock) time (h:mm:ss or m:ss)": [],
        "Average shared text size (kbytes)": [],
        "Average unshared data size (kbytes)": [],
        "Average stack size (kbytes)": [],
        "Average total size (kbytes)": [],
        "Maximum resident set size (kbytes)": [],
        "Average resident set size (kbytes)": [],
        "Major (requiring I/O) page faults": [],
        "Minor (reclaiming a frame) page faults": [],
        "Voluntary context switches": [],
        "Involuntary context switches": [],
        "Swaps": [],
        "File system inputs": [],
        "File system outputs": [],
        "Socket messages sent": [],
        "Socket messages received": [],
        "Signals delivered": [],
        "Page size (bytes)": [],
      }
    }
    """
    parser = argparse.ArgumentParser(
        description="Run command N time using /usr/bin/time and collect the statistics"
    )
    parser.add_argument("--output", help="Where to same the result", required=True)
    parser.add_argument("--command", help="The command to benchmark", required=True)
    parser.add_argument(
        "--iteration",
        type=int,
        default=5,
        help="The number of iteration to run the command (default: 5)",
    )
    parser.add_argument(
        "--stdout",
        default="/dev/null",
        help="Where to append the stdout of each command (default: /dev/null)",
    )
    parser.add_argument(
        "--stderr",
        default=os.path.join(os.getcwd(), "stderr.out"),
        help="Where to append the stderr of each command (default: $CWD/stderr.out)",
    )

    args = parser.parse_args()
    run(args.command, args.iteration, args.output, args.stdout, args.stderr)


if __name__ == "__main__":
    main()
