#!/bin/bash -exu
#
# Copyright (C) 2015 - Michael Jeanson <mjeanson@efficios.com>
#                      Jonathan Rajotte-Julien <jonathan.rajotte-julien@efficios.com>
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

# Coverity settings
# The project name and token have to be provided trough env variables
#COVERITY_SCAN_PROJECT_NAME=""
#COVERITY_SCAN_TOKEN=""
COVERITY_SCAN_DESCRIPTION="Automated CI build"
COVERITY_SCAN_NOTIFICATION_EMAIL="ci-notification@lists.lttng.org"
COVERITY_SCAN_BUILD_OPTIONS=""
#COVERITY_SCAN_BUILD_OPTIONS="--return-emit-failures 8 --parse-error-threshold 85"

SRCDIR="$WORKSPACE/src/${COVERITY_SCAN_PROJECT_NAME}"
TMPDIR="$WORKSPACE/tmp"

NPROC=$(nproc)
PLATFORM=$(uname)
export CFLAGS="-O0 -g -DDEBUG"

TOOL_ARCHIVE="$TMPDIR/cov-analysis-${PLATFORM}.tgz"
TOOL_URL=https://scan.coverity.com/download/${PLATFORM}
TOOL_BASE="$TMPDIR/coverity-scan-analysis"

UPLOAD_URL="https://scan.coverity.com/builds"
SCAN_URL="https://scan.coverity.com"

RESULTS_DIR_NAME="cov-int"
RESULTS_DIR="$WORKSPACE/$RESULTS_DIR_NAME"
RESULTS_ARCHIVE=analysis-results.tgz

# Create tmp directory
rm -rf "$TMPDIR"
mkdir -p "$TMPDIR"

export TMPDIR

case "$COVERITY_SCAN_PROJECT_NAME" in
babeltrace)
    CONF_OPTS="--enable-python-bindings --enable-python-bindings-doc"
    BUILD_TYPE="autotools"
    ;;
liburcu)
    CONF_OPTS=""
    BUILD_TYPE="autotools"
    ;;
lttng-modules)
    CONF_OPTS=""
    BUILD_TYPE="autotools"
    ;;
lttng-tools)
    CONF_OPTS=""
    BUILD_TYPE="autotools"
    ;;
lttng-ust)
    CONF_OPTS="--enable-java-agent-all --enable-python-agent"
    BUILD_TYPE="autotools"
    export CLASSPATH="/usr/share/java/log4j-1.2.jar"
    ;;
lttng-scope|ctf-java|libdelorean-java|jabberwocky)
    CONF_OPTS=""
    BUILD_TYPE="maven"
    MVN_BIN="$HOME/tools/hudson.tasks.Maven_MavenInstallation/default/bin/mvn"
    ;;
linux-rseq)
    CONF_OPTS=""
    BUILD_TYPE="linux-rseq"
    ;;
*)
    echo "Generic project, no configure options."
    CONF_OPTS=""
    BUILD_TYPE="autotools"
    ;;
esac

# liburcu dependency
if [ -d "$WORKSPACE/deps/liburcu" ]; then
  URCU_INCS="$WORKSPACE/deps/liburcu/build/include/"
  URCU_LIBS="$WORKSPACE/deps/liburcu/build/lib/"

  export CPPFLAGS="-I$URCU_INCS ${CPPFLAGS:-}"
  export LDFLAGS="-L$URCU_LIBS ${LDFLAGS:-}"
  export LD_LIBRARY_PATH="$URCU_LIBS:${LD_LIBRARY_PATH:-}"
fi


# lttng-ust dependency
if [ -d "$WORKSPACE/deps/lttng-ust" ]; then
  UST_INCS="$WORKSPACE/deps/lttng-ust/build/include/"
  UST_LIBS="$WORKSPACE/deps/lttng-ust/build/lib/"

  export CPPFLAGS="-I$UST_INCS ${CPPFLAGS:-}"
  export LDFLAGS="-L$UST_LIBS ${LDFLAGS:-}"
  export LD_LIBRARY_PATH="$UST_LIBS:${LD_LIBRARY_PATH:-}"
fi

if [ -d "$WORKSPACE/src/linux" ]; then
	export KERNELDIR="$WORKSPACE/src/linux"
fi

# Hack to get coverity with gcc >= 7
#
# We have to define the _Float* types as those are not defined by coverity and as result
# the codes linking agains those (pretty much anything linking against stdlib.h and math.h)
# won't be covered.
echo "
#ifdef __cplusplus
extern \"C\" {
#endif

#define _Float128 long double
#define _Float64x long double
#define _Float64 double
#define _Float32x double
#define _Float32 float

#ifdef __cplusplus
}
#endif" >> /tmp/coverity.h

export CPPFLAGS="-include /tmp/coverity.h ${CPPFLAGS:-}"


# Verify upload is permitted
#  Added "--insecure" because Coverity can't be bothered to properly install SSL certificate chains
set +x
AUTH_RES=$(curl -s --insecure --form project="$COVERITY_SCAN_PROJECT_NAME" --form token="$COVERITY_SCAN_TOKEN" $SCAN_URL/api/upload_permitted)
set -x
if [ "$AUTH_RES" = "Access denied" ]; then
  echo -e "\033[33;1mCoverity Scan API access denied. Check COVERITY_SCAN_PROJECT_NAME and COVERITY_SCAN_TOKEN.\033[0m"
  exit 1
else
  AUTH=$(echo "$AUTH_RES" | jq .upload_permitted)
  if [ "$AUTH" = "true" ]; then
    echo -e "\033[33;1mCoverity Scan analysis authorized per quota.\033[0m"
  else
    WHEN=$(echo "$AUTH_RES" | jq .next_upload_permitted_at)
    echo -e "\033[33;1mCoverity Scan analysis NOT authorized until $WHEN.\033[0m"
    exit 1
  fi
fi


# Download Coverity Scan Analysis Tool
if [ ! -d "$TOOL_BASE" ]; then
  if [ ! -e "$TOOL_ARCHIVE" ]; then
    echo -e "\033[33;1mDownloading Coverity Scan Analysis Tool...\033[0m"
    set +x
    curl -s --insecure --form project="$COVERITY_SCAN_PROJECT_NAME" --form token="$COVERITY_SCAN_TOKEN" -o "$TOOL_ARCHIVE" "$TOOL_URL"
    set -x
  fi

  # Extract Coverity Scan Analysis Tool
  echo -e "\033[33;1mExtracting Coverity Scan Analysis Tool...\033[0m"
  mkdir -p "$TOOL_BASE"
  cd "$TOOL_BASE" || exit 1
  tar xzf "$TOOL_ARCHIVE"
  cd -
fi

TOOL_DIR=$(find "$TOOL_BASE" -type d -name 'cov-analysis*')
export PATH=$TOOL_DIR/bin:$PATH

cd "$SRCDIR"

COVERITY_SCAN_VERSION=$(git describe --always | sed 's|-|.|g')

# Build
echo -e "\033[33;1mRunning Coverity Scan Analysis Tool...\033[0m"
case "$BUILD_TYPE" in
maven)
    cov-configure --java
    cov-build --dir "$RESULTS_DIR" $COVERITY_SCAN_BUILD_OPTIONS "$MVN_BIN" \
      -s "$MVN_SETTINGS" \
      -Dmaven.repo.local="$WORKSPACE/.repository" \
      -Dmaven.compiler.fork=true \
      -Dmaven.compiler.forceJavaCompilerUse=true \
      -Dmaven.test.skip=true \
      -DskipTests \
      clean verify
    ;;
autotools)
    # Prepare build dir for autotools based projects
    if [ -f "./bootstrap" ]; then
      ./bootstrap
      ./configure $CONF_OPTS
    fi

    cov-build --dir "$RESULTS_DIR" $COVERITY_SCAN_BUILD_OPTIONS make -j"$NPROC" V=1
    ;;
linux-rseq)
    make defconfig
    cov-build --dir "$RESULTS_DIR" $COVERITY_SCAN_BUILD_OPTIONS make -j"$NPROC" kernel/rseq.o kernel/cpu_opv.o V=1
    ;;
*)
    echo "Unsupported build type: $BUILD_TYPE"
    exit 1
    ;;
esac



cov-import-scm --dir "$RESULTS_DIR" --scm git --log "$RESULTS_DIR/scm_log.txt"

cd "${WORKSPACE}"

# Tar results
echo -e "\033[33;1mTarring Coverity Scan Analysis results...\033[0m"
tar czf $RESULTS_ARCHIVE $RESULTS_DIR_NAME

# Upload results
echo -e "\033[33;1mUploading Coverity Scan Analysis results...\033[0m"
set +x
response=$(curl --insecure \
  --silent --write-out "\n%{http_code}\n" \
  --form project="$COVERITY_SCAN_PROJECT_NAME" \
  --form token="$COVERITY_SCAN_TOKEN" \
  --form email="$COVERITY_SCAN_NOTIFICATION_EMAIL" \
  --form file=@"$RESULTS_ARCHIVE" \
  --form version="$COVERITY_SCAN_VERSION" \
  --form description="$COVERITY_SCAN_DESCRIPTION" \
  "$UPLOAD_URL")
set -x
status_code=$(echo "$response" | sed -n '$p')
if [ "${status_code:0:1}" == "2" ]; then
  echo -e "\033[33;1mCoverity Scan upload successful.\033[0m"
else
  TEXT=$(echo "$response" | sed '$d')
  echo -e "\033[33;1mCoverity Scan upload failed: $TEXT.\033[0m"
  exit 1
fi

# EOF
