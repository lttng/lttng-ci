#!/bin/bash -exu
#
# Copyright (C) 2015 - Alexandre Montplaisir <alexmonthy@efficios.com>
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

# Required parameters
#wm=${wm:-}
wm="unity"

# Launch the window manager defined by the configuration
case "$wm" in
  "unity")
    $wm &
    ;;

  "metacity")
    $wm --replace --sm-disable &
    ;;

  *)
    echo "Unknown windows manager $wm"
    exit 1
    ;;
esac
