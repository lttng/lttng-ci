#!/bin/bash
#
# SPDX-FileCopyrightText: 2024 Kienan Stewart <kstewart@efficios.com>
# SPDX-License-Identifier: GPL-2.0-or-later
#
set -exu

# shellcheck disable=SC2317
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

# Work-around for the sles12sp5, sles15sp4 where the last successful builds were
# completed before 'followSymlinks' was set to try, and is thus missing the
# links for all the libraries.
if [[ -f /etc/products.d/SLES.prod ]] ; then
    pushd "${WORKSPACE}/deps/build/${LIBDIR_ARCH}"
    while read -r LIB ; do
        LIB_ANY=$(echo "${LIB}" | rev | cut -d'.' -f4- | rev)
        LIB_MAJOR=$(echo "${LIB}" | rev | cut -d'.' -f3- | rev)
        if [[ ! -f "${LIB_ANY}" ]]; then
            ln -s "$(realpath "${LIB}")" "${LIB_ANY}"
        fi
        if [[ ! -f "${LIB_MAJOR}" ]] ; then
            ln -s "$(realpath "${LIB}")" "${LIB_MAJOR}"
        fi
    done < <(find . -type f -iregex '.*\.so\.[0-9]+\.[0-9]+\.[0-9]+')
    popd
fi

if [[ -z "${JAVA_HOME:-}" ]] ; then
    export JAVA_HOME="/usr/lib/jvm/default-java"
fi

DEPS_JAVA="${WORKSPACE/deps/build/share/java}"
export CLASSPATH="$DEPS_JAVA/lttng-ust-agent-all.jar:/usr/share/java/log4j-api.jar:/usr/share/java/log4j-core.jar:/usr/share/java/log4j-1.2.jar"

LTTNG_UST_JAVA_TESTS_ENV=(
    # Some ci nodes (eg. SLES12) don't have maven distributed by their
    # package manager. As a result, the maven binary is deployed in
    # '/opt/apache/maven/bin'.
    PATH="${WORKSPACE}/deps/build/bin/:$PATH:/opt/apache/maven/bin/"
    LD_LIBRARY_PATH="${WORKSPACE}/deps/build/${LIBDIR}/:${WORKSPACE}/deps/build/${LIBDIR_ARCH}:$LD_LIBRARY_PATH"
    LTTNG_UST_DEBUG=1
    LTTNG_CONSUMERD32_BIN="${WORKSPACE}/deps/build/${LIBDIR_ARCH}/lttng/libexec/lttng-consumerd"
    LTTNG_CONSUMERD64_BIN="${WORKSPACE}/deps/build/${LIBDIR_ARCH}/lttng/libexec/lttng-consumerd"
    LTTNG_SESSION_CONFIG_XSD_PATH="${WORKSPACE}/deps/build/share/xml/lttng"
    BABELTRACE_PLUGIN_PATH="${WORKSPACE}/deps/build/${LIBDIR_ARCH}/babeltrace2/plugins"
    LIBBABELTRACE2_PLUGIN_PROVIDER_DIR="${WORKSPACE}/deps/build/${LIBDIR_ARCH}/babeltrace2/plugin-providers"
)
LTTNG_UST_JAVA_TESTS_MAVEN_OPTS=(
    "-Dmaven.test.failure.ignore=true"
    "-Dcommon-jar-location=${WORKSPACE}/deps/build/share/java/lttng-ust-agent-common.jar"
    "-Djul-jar-location=${WORKSPACE}/deps/build/share/java/lttng-ust-agent-jul.jar"
    "-Dlog4j-jar-location=${WORKSPACE}/deps/build/share/java/lttng-ust-agent-log4j.jar"
    "-Dlog4j2-jar-location=${WORKSPACE}/deps/build/share/java/lttng-ust-agent-log4j2.jar"
    "-DargLine=-Djava.library.path=${WORKSPACE}/deps/build/${LIBDIR_ARCH}"
    '-Dgroups=!domain:log4j2'
)

# Start the lttng-sessiond
mkdir -p "${WORKSPACE}/log"
env "${LTTNG_UST_JAVA_TESTS_ENV[@]}" lttng-sessiond -b -vvv > "${WORKSPACE}/log/lttng-sessiond.log" 2>&1

cd src/lttng-ust-java-tests
env "${LTTNG_UST_JAVA_TESTS_ENV[@]}" mvn -version
env "${LTTNG_UST_JAVA_TESTS_ENV[@]}" mvn "${LTTNG_UST_JAVA_TESTS_MAVEN_OPTS[@]}" clean verify
exit "${?}"
