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

# Add ssh key for deployment
echo "StrictHostKeyChecking no" >> ~/.ssh/config
cp "$KEY_FILE_VARIABLE" ~/.ssh/id_rsa

# lttng-www dependencies

# Nodejs
# Using Debian, as root
curl -fsSL https://deb.nodesource.com/setup_15.x | bash -
apt-get install -y nodejs 

apt-get install -y ruby asciidoc xmlto

npm install -g grunt-cli
npm install -g sass

./bootstrap-ubuntu.sh

grunt build:prod
grunt deploy:prod

# EOF
