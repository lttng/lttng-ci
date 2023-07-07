#!/bin/bash
# shellcheck disable=SC2103
#
# Copyright (C) 2022 Kienan Stewart <kstewart@efficios.com>
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

# Add ssh key for deployment
cp "$HOST_PUBLIC_KEYS" ~/.ssh/known_hosts
cp "$KEY_FILE_VARIABLE" ~/.ssh/id_rsa

apt-get update

# Nodejs
apt-get install --no-install-recommends -y npm
./bootstrap-ubuntu.sh
npm install

grunt build:dev --verbose
grunt deploy:pre --verbose

grunt build:prod --verbose

# Check for broken internal links
apt-get install -y linkchecker
grunt connect:prod watch:prod &
SERVER_PID="${!}"
sleep 10 # While serve:prod starts up
OUTPUT_FILE="$(mktemp -d)/linkchecker-out.csv"
# linkchecker drops privileges to 'nobody' when run as root
chown nobody "$(dirname "${OUTPUT_FILE}")"
# @Note: Only internal links are checked by default
if ! linkchecker -q -F "csv/utf-8/${OUTPUT_FILE}" http://localhost:10000/ ; then
    echo "Linkchecker failed or found broken links"
    cat "${OUTPUT_FILE}"
    kill "${SERVER_PID}"
    rm -rf "${OUTPUT_FILE}/.."
    sleep 5 # Let serve:prod stop
    exit 1
else
    rm -rf "${OUTPUT_FILE}/.."
    kill "${SERVER_PID}"
fi

grunt deploy:prod --verbose
# EOF
