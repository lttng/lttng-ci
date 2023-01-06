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

RUBY_VERSION=2.7

# Add ssh key for deployment
cp "$HOST_PUBLIC_KEYS" ~/.ssh/known_hosts
cp "$KEY_FILE_VARIABLE" ~/.ssh/id_rsa

# lttng-www dependencies

# Nodejs
# Using Debian, as root
curl -fsSL https://deb.nodesource.com/setup_16.x | bash -
apt-get install -y nodejs

apt-add-repository ppa:brightbox/ruby-ng
apt-get install -y ruby${RUBY_VERSION} ruby${RUBY_VERSION}-dev ruby-switch ruby-bundler

ruby-switch --list
ruby-switch --set ruby${RUBY_VERSION}

ruby -v

apt-get install -y asciidoc xmlto python3 python3-pip

npm install -g grunt-cli
npm install -g sass

export PATH="/root/.gem/ruby/${RUBY_VERSION}.0/bin:$PATH"

bundle config set --local path "/root/.gem"

./bootstrap.sh

grunt build:prod
grunt deploy:prod

# EOF
