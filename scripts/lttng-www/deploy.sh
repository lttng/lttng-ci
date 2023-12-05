#!/bin/bash
# shellcheck disable=SC2103
#
# Copyright (C) 2021 Jonathan Rajotte-Julien <jonathan.rajotte-julien@efficios.com>
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

print_header() {
    set +x

    local message=" $1 "
    local message_len
    local padding_len

    message_len="${#message}"
    padding_len=$(( (80 - (message_len)) / 2 ))

    printf '\n'; printf -- '#%.0s' {1..80}; printf '\n'
    printf -- '-%.0s' {1..80}; printf '\n'
    printf -- '#%.0s' $(seq 1 $padding_len); printf '%s' "$message"; printf -- '#%.0s' $(seq 1 $padding_len); printf '\n'
    printf -- '-%.0s' {1..80}; printf '\n'
    printf -- '#%.0s' {1..80}; printf '\n\n'

    set -x
}

# Fail out early if this is not set
echo "Deploy target: ${DEPLOY_TARGET}"

# Add ssh key for deployment
cp "$HOST_PUBLIC_KEYS" ~/.ssh/known_hosts
cp "$KEY_FILE_VARIABLE" ~/.ssh/id_rsa

# lttng-www dependencies
export DPKG_FRONTEND=noninteractive
apt-get update

print_header "Install web tooling dependencies"
apt-get install -y nodejs node-grunt-cli npm ruby-bundler ruby-dev python3-pip python3-venv

ruby -v

apt-get install -y xmlto doclifter linkchecker

python3 -m venv build_venv
# shellcheck disable=SC1091
source build_venv/bin/activate

bundle config set --local path "vendor/bundle"

./bootstrap-debian.sh

print_header "Build website with grunt"
bundle exec grunt build:prod

print_header "Check links"
bundle exec grunt connect:prod watch:prod &
SERVER_PID="${!}"
sleep 10 # While serve:prod starts up

OUTPUT_DIR="$(mktemp -d)"
OUTPUT_FILE="${OUTPUT_DIR}/linkchecker-out.csv"

# linkchecker drops privileges to 'nobody' when run as root
chown nobody "${OUTPUT_DIR}"

# @Note: Only internal links are checked by default
if ! linkchecker -q -F "csv/utf-8/${OUTPUT_FILE}" http://localhost:10000/ ; then
    echo "Linkchecker failed or found broken links"
    cat "${OUTPUT_FILE}"
    kill "${SERVER_PID}"
    rm -rf "${OUTPUT_DIR}"
    sleep 5 # Let serve:prod stop
    exit 1
else
    rm -rf "${OUTPUT_DIR}"
    kill "${SERVER_PID}"
fi

print_header "Deploy website"
bundle exec grunt "${DEPLOY_TARGET}" --network

# EOF
