#!/bin/bash
#
# SPDX-FileCopyrightText: 2024 Kienan Stewart <kstewart@efficios.com>
# SPDX-License-Identifier: GPL-2.0-or-later
#
set -exu

os_field() {
    field=$1
    if [ -f /etc/os-release ]; then
        # shellcheck disable=SC1091
        echo "$(source /etc/os-release; echo "${!field}")"
    fi
}

os_id() {
    os_field 'ID'
}

# shellcheck disable=SC2317,SC2329
os_version_id() {
    os_field 'VERSION_ID'
}

# Version compare functions
vercomp () {
    set +u
    if [[ "$1" == "$2" ]]; then
        return 0
    fi
    local IFS=.
    # Ignore the shellcheck warning, we want splitting to happen based on IFS.
    # shellcheck disable=SC2206
    local i ver1=($1) ver2=($2)
    # fill empty fields in ver1 with zeros
    for ((i=${#ver1[@]}; i<${#ver2[@]}; i++)); do
        ver1[i]=0
    done
    for ((i=0; i<${#ver1[@]}; i++)); do
        if [[ -z ${ver2[i]} ]]; then
            # fill empty fields in ver2 with zeros
            ver2[i]=0
        fi
        if ((10#${ver1[i]} > 10#${ver2[i]})); then
            return 1
        fi
        if ((10#${ver1[i]} < 10#${ver2[i]})); then
            return 2
        fi
    done
    set -u
    return 0
}

# shellcheck disable=SC2317,SC2329
verlte() {
    vercomp "$1" "$2"; local res="$?"
    [ "$res" -eq "0" ] || [ "$res" -eq "2" ]
}

verlt() {
    vercomp "$1" "$2"; local res="$?"
    [ "$res" -eq "2" ]
}

vergte() {
    vercomp "$1" "$2"; local res="$?"
    [ "$res" -eq "0" ] || [ "$res" -eq "1" ]
}

# shellcheck disable=SC2317,SC2329
vergt() {
    vercomp "$1" "$2"; local res="$?"
    [ "$res" -eq "1" ]
}

# shellcheck disable=SC2317,SC2329
verne() {
    vercomp "$1" "$2"; local res="$?"
    [ "$res" -ne "0" ]
}

# shellcheck disable=SC2317,SC2329
function cleanup
{
    killall lttng-sessiond
}

trap cleanup EXIT SIGINT SIGTERM

LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}"
LIBDIR="lib"
LIBDIR_ARCH="$LIBDIR"

# RHEL and SLES both use lib64 but don't bother shipping a default autoconf
# site config that matches this.
if [[ ( -f /etc/redhat-release || -f /etc/products.d/SLES.prod || -f /etc/yocto-release ) ]]; then
    # Detect the userspace bitness in a distro agnostic way
    if file -L /bin/bash | grep '64-bit' >/dev/null 2>&1; then
        LIBDIR_ARCH="${LIBDIR}64"
    fi
fi

if [[ -z "${JAVA_HOME:-}" ]] ; then
    export JAVA_HOME="/usr/lib/jvm/default-java"
fi

DEPS_JAVA="${WORKSPACE/deps/build/share/java}"
export CLASSPATH="$DEPS_JAVA/lttng-ust-agent-all.jar:/usr/share/java/log4j-api.jar:/usr/share/java/log4j-core.jar:/usr/share/java/log4j-1.2.jar"
case "${java_preferred_jdk:-}" in
    'default')
        ;;
    '8')
        case "$(os_id)" in
            'ci') # yocto
                export JAVA_HOME="/usr/${LIBDIR_ARCH}/jvm/openjdk-8/"
                export PATH="/usr/${LIBDIR_ARCH}/jvm/openjdk-8/bin/:${PATH}"
                ;;
            *)
                echo "OS id '$(os_id)' not supported for java_preferred_jdk '${java_preferred_jdk}'"
                exit 1
        esac
        ;;
    *)
      echo "Unsupported java_preferred_jdk: '${java_preferred_jdk}'"
      exit 1
      ;;
esac

LTTNG_UST_JAVA_TESTS_ENV=(
    # Some ci nodes (eg. SLES12) don't have maven distributed by their
    # package manager. As a result, the maven binary is deployed in
    # '/opt/apache/maven/bin'.
    PATH="${WORKSPACE}/deps/build/bin/:$PATH:/opt/apache/maven/bin/"
    LD_LIBRARY_PATH="${WORKSPACE}/deps/build/${LIBDIR}/:${WORKSPACE}/deps/build/${LIBDIR_ARCH}:$LD_LIBRARY_PATH"
    LTTNG_CONSUMERD32_BIN="${WORKSPACE}/deps/build/${LIBDIR_ARCH}/lttng/libexec/lttng-consumerd"
    LTTNG_CONSUMERD64_BIN="${WORKSPACE}/deps/build/${LIBDIR_ARCH}/lttng/libexec/lttng-consumerd"
    LTTNG_SESSION_CONFIG_XSD_PATH="${WORKSPACE}/deps/build/share/xml/lttng"
    BABELTRACE_PLUGIN_PATH="${WORKSPACE}/deps/build/${LIBDIR_ARCH}/babeltrace2/plugins"
    BABELTRACE_PLUGIN_PROVIDER_PATH="${WORKSPACE}/deps/build/${LIBDIR_ARCH}/babeltrace2/plugin-providers"
    LIBBABELTRACE2_PLUGIN_PROVIDER_DIR="${WORKSPACE}/deps/build/${LIBDIR_ARCH}/babeltrace2/plugin-providers"
)
LTTNG_UST_JAVA_TESTS_MAVEN_OPTS=(
    "--no-transfer-progress"  # mvn 3.6.1+
    "-Dmaven.test.failure.ignore=true"
    "-Dcommon-jar-location=${WORKSPACE}/deps/build/share/java/lttng-ust-agent-common.jar"
    "-Djul-jar-location=${WORKSPACE}/deps/build/share/java/lttng-ust-agent-jul.jar"
    "-Dlog4j-jar-location=${WORKSPACE}/deps/build/share/java/lttng-ust-agent-log4j.jar"
    "-Dlog4j2-jar-location=${WORKSPACE}/deps/build/share/java/lttng-ust-agent-log4j2.jar"
    "-DargLine=-Djava.library.path=${WORKSPACE}/deps/build/${LIBDIR_ARCH}"
    "-Dmaven.test.redirectTestOutputToFile=true"
)

# Check lttng-tools version
# Merged into master ~ 47abf22b48023960069e1d3e23f42298ce4b3c2a
LTTNG_VERSION="$(env "${LTTNG_UST_JAVA_TESTS_ENV[@]}" lttng --version | cut -d ' ' -f 5)"
if verlt "${LTTNG_VERSION}" "2.14" ; then
    LTTNG_UST_JAVA_TESTS_MAVEN_OPTS+=(
        '-Dgroups=!domain:log4j2'
    )
fi

# Start the lttng-sessiond
mkdir -p "${WORKSPACE}/log"
SESSIOND_ARGS=(
    '-b'
)

if [[ "${VERBOSE_SESSIOND:-}" == "true" ]]; then
    SESSIOND_ARGS+=(
        '-vvv'
        '--verbose-consumer'
    )
fi

if [[ "${VERBOSE_UST:-}" == "true" ]]; then
    export LTTNG_UST_DEBUG=1
fi

env "${LTTNG_UST_JAVA_TESTS_ENV[@]}" lttng-sessiond "${SESSIOND_ARGS[@]}" > "${WORKSPACE}/log/lttng-sessiond.log" 2>&1

cd src/lttng-ust-java-tests
env "${LTTNG_UST_JAVA_TESTS_ENV[@]}" mvn -version
env "${LTTNG_UST_JAVA_TESTS_ENV[@]}" mvn "${LTTNG_UST_JAVA_TESTS_MAVEN_OPTS[@]}" clean verify
ret="${?}"

# Copy test result XML files
mkdir -p "${WORKSPACE}/junit"
while read -r line ; do
    project="$(echo "${line}" | cut -d '/' -f 2)"
    if [[ "${project}" == "target" ]]; then
        project="lttng-ust-java-tests"
    fi

    mkdir -p "${WORKSPACE}/junit/${project}"
    cp -t "${WORKSPACE}/junit/${project}/" "${line}"
done < <(find . -iname 'TEST-*.xml' -and -type f)

exit "${ret}"
