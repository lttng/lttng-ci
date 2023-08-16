#!/bin/bash
# shellcheck disable=SC2103
#
# Copyright (C) 2022 Jonathan Rajotte-Julien <jonathan.rajotte-julien@efficios.com>
# Copyright (C) 2023 Michael Jeanson <mjeanson@efficios.com>
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

set -eux

BASEDIR_64="$WORKSPACE/deps-64/build"
BASEDIR_32="$WORKSPACE/deps-32/build"
PREFIX="/build"

export CPPFLAGS="-I$BASEDIR_64/include"
export LDFLAGS="-L$BASEDIR_64/lib"
export CFLAGS="-g -O0"
export CXXFLAGS="-g -O0"
export PKG_CONFIG_PATH="$BASEDIR_64/lib/pkgconfig"
export LD_LIBRARY_PATH="$BASEDIR_64/lib:$BASEDIR_32/lib"
export PATH="$PATH:$BASEDIR_64/bin"

export BABELTRACE_PLUGIN_PATH="$BASEDIR_64/lib/babeltrace2/plugins/"
export LIBBABELTRACE2_PLUGIN_PROVIDER_DIR="$BASEDIR_64/lib/babeltrace2/plugin-providers/"

export JAVA_HOME="/usr/lib/jvm/default-java"
DEPS_JAVA="$WORKSPACE/deps-64/build/share/java"
export CLASSPATH="$DEPS_JAVA/lttng-ust-agent-all.jar:/usr/share/java/log4j-api.jar:/usr/share/java/log4j-core.jar:/usr/share/java/log4j-1.2.jar"

export PYTHON2="python2"
export PYTHON3="python3"

if command -v $PYTHON2 >/dev/null 2>&1; then
    P2_VERSION=$($PYTHON2 -c 'import sys;v = sys.version.split()[0].split("."); print("{}.{}".format(v[0], v[1]))')
    DEPS_PYTHON2="$WORKSPACE/deps/build/lib/python$P2_VERSION/site-packages"

    PYTHON_TEST_ARG="--enable-test-python-agent-all"
else
    PYTHON_TEST_ARG="--enable-test-python3-agent"
fi

P3_VERSION=$($PYTHON3 -c 'import sys;v = sys.version.split()[0].split("."); print("{}.{}".format(v[0], v[1]))')
DEPS_PYTHON3="$WORKSPACE/deps-64/build/lib/python$P3_VERSION/site-packages"

# Most build configs require access to the babeltrace 2 python bindings.
# This also makes the lttngust python agent available for `agents` builds.
export PYTHONPATH="${DEPS_PYTHON2:-}${DEPS_PYTHON2:+:}$DEPS_PYTHON3"

export LTTNG_CONSUMERD32_BIN="$BASEDIR_32/lib/lttng/libexec/lttng-consumerd"
export LTTNG_CONSUMERD32_LIBDIR="$BASEDIR_32/lib"
export LTTNG_CONSUMERD64_BIN="$BASEDIR_64/lib/lttng/libexec/lttng-consumerd"
export LTTNG_CONSUMERD64_LIBDIR="$BASEDIR_64/lib/"

# Stable 2.12 and 2.13 still look for "babeltrace"
ln -s "$BASEDIR_64/bin/babeltrace2" "$BASEDIR_64/bin/babeltrace"

echo "# Setup endpoint
host_base = obj.internal.efficios.com
host_bucket = obj.internal.efficios.com
bucket_location = us-east-1
use_https = True

# Setup access keys
access_key = jenkins
secret_key = echo123456

# Enable S3 v4 signature APIs
signature_v2 = False" > "$WORKSPACE/.s3cfg"


mkdir artefact
pushd artefact
s3cmd -c "$WORKSPACE/.s3cfg" get "s3://jenkins/32-64-bit-integration/$ARTIFACT_ID"
tar -xvf "$ARTIFACT_ID"
popd

cp -r artefact/sources/* ./
cp -r artefact/deps/* ./

pushd src/lttng-modules
make -j"$(nproc)" V=1
make modules_install
depmod -a
popd

pushd src/lttng-tools

./bootstrap
./configure --prefix="$PREFIX" --enable-test-java-agent-all $PYTHON_TEST_ARG
popd

# Deativate health test, simply because there is little value for this integration testing
# and because de ld_preloaded object is for both lttng-sessiond/consumer leading to difficult ld_preloading
# Deactivate clock plugin test since the app must load the correct biness so and the sessiond its bitness so,
# this is simply not feasible from outside the script. There is little value for this test in this testing context.
pushd src/lttng-tools/tests/regression
sed -i '/tools\/health\/test_thread_ok/d' Makefile.am
sed -i '/ust\/clock-override\/test_clock_override/d' Makefile.am
popd

pushd src/lttng-tools/
make -j"$(nproc)" V=1
popd

case "$TEST_TYPE" in
	"canary")
		;;
	"32bit-sessiond")
		pushd src/lttng-tools/src/bin/lttng-sessiond
		rm lttng-sessiond
		ln -s "$BASEDIR_32/bin/lttng-sessiond" lttng-sessiond
		popd

		cp -rv "$WORKSPACE/artefact/testing-overlay/sessiond/"* ./
		;;
	"32bit-relayd")
		pushd src/lttng-tools/src/bin/lttng-relayd
		rm lttng-relayd
		ln -s "$BASEDIR_32/bin/lttng-relayd" lttng-relayd
		popd
		;;
	"32bit-cli")
		pushd src/lttng-tools/src/bin/lttng
		rm lttng
		ln -s "$BASEDIR_32/bin/lttng" lttng
		popd
		;;
	*)
		exit 1
esac
failed_test=0
pushd src/lttng-tools/tests
make --keep-going check || failed_test=1
popd

exit $failed_test
