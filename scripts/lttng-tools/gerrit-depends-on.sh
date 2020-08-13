#!/bin/bash -exu
# shellcheck disable=SC2103
#
# Copyright (C) 2020 Jonathan Rajotte-Julien <jonathan.rajotte-julien@efficios.com>
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

#Required variables
GERRIT_NAME=${GERRIT_NAME:-}
WORKSPACE=${WORKSPACE:-}
conf=${conf:-}

gerrit_url="https://${GERRIT_NAME}"
gerrit_query="?o=CURRENT_REVISION&o=DOWNLOAD_COMMANDS"
gerrit_json_query=".revisions[.current_revision].ref"

possible_depends_on="lttng-ust|lttng-modules"
re="Depends-on: (${possible_depends_on}): ([^'$'\n'']*)"
property_file="${WORKSPACE}/gerrit_custom_dependencies.properties"

# Create the property file even if it ends up being empty
touch "$property_file"

# Move to lttng-tools source directory
pushd "${WORKSPACE}/src/lttng-tools"

git rev-list --format=%B --max-count=1 HEAD | while read -r line; do
    # Deactivate debug mode to prevent the gcc warning publisher from picking up
    # compiler error present in the commit message.
    set +x
    if ! [[ ${line} =~ ${re} ]]; then
        set -x
        continue
    fi
    set -x

    project=${BASH_REMATCH[1]}
    gerrit_id=${BASH_REMATCH[2]}

    project_sanitize=${BASH_REMATCH[1]//-/_}

    if [ "$conf" = "no-ust" ] && [ "$project" = "lttng-ust" ]; then
        # No need to checkout lttng-ust for this configuration axis
        continue
    fi

    if [ "$project" = "lttng-modules" ]; then
        if [ -d "$WORKSPACE/src/lttng-modules" ]; then
            # Remove the regular modules sources to replace them with those
	    # from the gerrit change
            rm -rf "$WORKSPACE/src/lttng-modules"
        else
            # This job does not require modules sources
            continue
	fi
    fi

    # Export the GERRIT_DEP_... into the property file for further jenkins usage
    echo "GERRIT_DEP_${project_sanitize^^}=${gerrit_id}" >> "$property_file"

    # Get the change latest ref
    ref=$(curl "${gerrit_url}/changes/${gerrit_id}${gerrit_query}" | tail -n+2 | jq -r "$gerrit_json_query")
    git clone "${gerrit_url}/${project}" "$WORKSPACE/src/$project"
    pushd "$WORKSPACE/src/$project"
    git fetch "${gerrit_url}/${project}" "$ref"
    git checkout FETCH_HEAD
    popd
done

popd
