#!/bin/bash
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

set -exu

#Required variables
GERRIT_NAME=${GERRIT_NAME:-}
WORKSPACE=${WORKSPACE:-}
conf=${conf:-}

gerrit_url="https://${GERRIT_NAME}"
gerrit_query="&o=CURRENT_REVISION&o=DOWNLOAD_COMMANDS"
gerrit_json_query=".[0].revisions[.[0].current_revision].ref"
gerrit_json_query_status=".[0].status"

possible_depends_on="lttng-ust|lttng-modules|userspace-rcu|babeltrace"
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
        fi
    fi

    # Export the GERRIT_DEP_... into the property file for further jenkins usage
    echo "GERRIT_DEP_${project_sanitize^^}=${gerrit_id}" >> "$property_file"
    # Deactivate tests for the project
    echo "${project_sanitize^^}_RUN_TESTS=no" >> "$property_file"

    # Get the change latest ref
    case $project in
        lttng-*)
            # This is necessary since a cherry pick can have the same change id
            # across branches. Still this is only valid for projects where the
            # branch name fits the same branch name style of the lttng-tools
            # project.
            # We will need to be much more clever if the situation arise where
            # we need to depends-on a cherry picked change id for the
            # userspace-rcu or babeltrace project. Until then let's use this
            # hack. The quick solution to this is to tell the committer to change
            # the change id. We could also be clever and require that the
            # "branch name" be included in the `Depends-on` clause.
            local_query="${gerrit_url}/changes/?q=change:${gerrit_id}+branch:${GERRIT_BRANCH}${gerrit_query}"
	    default_branch="${GERRIT_BRANCH}"
            ;;
        *)
            local_query="${gerrit_url}/changes/?q=change:${gerrit_id}${gerrit_query}"
	    default_branch="master"
            ;;
    esac

    json_doc=$(curl "$local_query" | tail -n+2)
    count=$(jq -r '. | length' <<< "$json_doc")
    if [ "$count" != "1" ]; then
	    echo "Expected an array of size 1 got $count"
	    exit 1
    fi

    ref=$(jq -r "$gerrit_json_query" <<< "$json_doc")
    change_status=$(jq -r "$gerrit_json_query_status" <<< "$json_doc")
    if [ "$change_status" == "MERGED" ]; then
	    # When the change we depends on is merged use master as the ref.
	    # This is not ideal CI time wise since we do not reuse artifacts.
	    # This solve a tricky situation where we actually want to use master
	    # instead of the change available on gerrit. Intermediary changes
	    # present in master could have an impact on the change under test.
	    echo "Depends-on change is MERGED. Defaulting to ${default_branch}"
	    ref="refs/heads/$default_branch"
    elif [ "$change_status" == "ABANDONED" ]; then
	    # We have a situation where the "HEAD" commit for feature branch are
	    # not merged and abandoned. Default to the master branch and hope
	    # for the best. This is far from ideal but we need might also need
	    # to find a better way to handle feature branch here. In the
	    # meantime use master for such cases.
	    echo "Depends-on change is ABANDONED. Defaulting to ${default_branch}"
	    ref="refs/heads/${default_branch}"
    fi

    # The build.sh script from userspace-rcu expects the source to be located in
    # `liburcu` instead of userspace-rcu. Accommodate for this here.
    if [ "$project" = "userspace-rcu" ]; then
        clone_directory="liburcu"
    else
	clone_directory="$project"
    fi

    clone_directory="$WORKSPACE/src/$clone_directory"

    git clone "${gerrit_url}/${project}" "$clone_directory"
    pushd "$clone_directory"
    git fetch "${gerrit_url}/${project}" "$ref"
    git checkout FETCH_HEAD
    popd
done

popd
