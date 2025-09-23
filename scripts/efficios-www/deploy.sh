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

# Fail early if not set
echo "Deploy target: ${DEPLOY_TARGET}"

# Add ssh key for deployment
cp "$HOST_PUBLIC_KEYS" ~/.ssh/known_hosts
cp "$KEY_FILE_VARIABLE" ~/.ssh/id_rsa

export DEBIAN_FRONTEND=noninteractive
apt-get update

print_header "Install web tooling dependencies"
apt-get install --no-install-recommends -y npm
./bootstrap-ubuntu.sh

print_header "Install NPM stuff"
npm install

print_header "Build website with grunt"
grunt build:dev --verbose
grunt deploy:pre --verbose

grunt build:prod --verbose

# Check for broken internal links
print_header "Check links"
apt-get install -y linkchecker
grunt connect:prod watch:prod &
SERVER_PID="${!}"
sleep 10 # While serve:prod starts up

OUTPUT_DIR="$(mktemp -d)"
OUTPUT_FILE="${OUTPUT_DIR}/linkchecker-out.csv"

# linkchecker drops privileges to 'nobody' when run as root
chown nobody "${OUTPUT_DIR}"

LINKCHECKER_ARGS=(
    '-q' '-F' "csv/utf-8/${OUTPUT_FILE}"
    http://localhost:10000/
)
if test -f .linkcheckerrc ; then
    LINKCHECKER_ARGS+=(
        '-f' '.linkcheckerrc'
    )
fi

# @Note: Only internal links are checked by default
if ! linkchecker "${LINKCHECKER_ARGS[@]}" ; then
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
grunt "${DEPLOY_TARGET}" --verbose
# EOF
