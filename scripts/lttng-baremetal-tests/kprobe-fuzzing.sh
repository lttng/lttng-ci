#!/bin/bash -xeu
# Copyright (C) 2017 - Francis Deslauriers <francis.deslauriers@efficios.com>
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

NB_KPROBE_PER_ITER=500
SESSION_NAME="my_kprobe_session"

# Silence the script to avoid redirection of kallsyms to fill the screen
set +x
syms=$(awk '{print $3;}' /proc/kallsyms | sort -R)
nb_syms=$(echo "$syms" | wc -l)
set -x

# Loop over the list of symbols and enable the symbols in groups of
# $NB_KPROBE_PER_ITER
for i in $(seq 0 "$NB_KPROBE_PER_ITER" "$nb_syms"); do
	# Print time in UTC at each iteration to easily see when the script
	# hangs
	date --utc

	# Pick $NB_KPROBE_PER_ITER symbols to instrument, craft enable-event
	# command and save them to a file. We craft the commands and executed
	# them in two steps so that the pipeline can be done without the bash
	# '-x' option that would fill the serial buffer because of the multiple
	# pipe redirections.
	set +x
	echo "$syms" | head -n $((i+NB_KPROBE_PER_ITER)) | tail -n $NB_KPROBE_PER_ITER |awk '{print "lttng enable-event --kernel --function=" $1 " " $1}' > lttng-enable-event.sh
	set -x

	# Print what iteration we are at
	echo "$i" $((i+NB_KPROBE_PER_ITER))

	# Destroy previous session and create a new one
	lttng create "$SESSION_NAME"

	# Expect commands to fail, turn off early exit of shell script on
	# non-zero return value
	set +e
	source  ./lttng-enable-event.sh
	set -e

	# Run stress util to generate some kernel activity
	stress --cpu 2 --io 4 --vm 2 --vm-bytes 128M --hdd 3 --timeout 5s

	lttng list "$SESSION_NAME"
	lttng destroy "$SESSION_NAME"
done
