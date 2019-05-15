#!/bin/bash -eux
# Copyright (C) 2018 - Jonathan Rajotte-Julien <jonthan.rajotte-julien@efficios.com>
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

bucket=lava
file=$1
#Path must include the file name
path=$2

host=obj.internal.efficios.com
s3_k='jenkins'
s3_s='echo123456'

resource="/${bucket}/${path}"
content_type="application/octet-stream"
date=$(date -R)
_signature="PUT\n\n${content_type}\n${date}\n${resource}"
signature=$(echo -en "$_signature" | openssl sha1 -hmac "$s3_s" -binary | base64)

curl -v -k -X PUT -T "${file}" \
          -H "Host: $host" \
          -H "Date: ${date}" \
          -H "Content-Type: ${content_type}" \
          -H "Authorization: AWS ${s3_k}:${signature}" \
          https://"${host}${resource}"
