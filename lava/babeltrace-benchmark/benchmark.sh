#!/bin/bash

set -exu
set -o pipefail

function upload_artifact()
{
    local local_file=$1
    local s3_key=$2
    local md5

    md5="$(openssl md5 -binary coredump.tar.xz | openssl base64)"

    # Fetch the S3 keys stored in secrets
    set +x
    # shellcheck disable=SC1091
    . ../../../secrets
    echo "user = \"$S3_ACCESS_KEY:$S3_SECRET_KEY\"" > s3curlrc
    set -x

    curl -v -s -f -T "$local_file" \
        --config s3curlrc \
        --aws-sigv4 "aws:amz:us-east-1:s3" \
        -H "Content-MD5: $md5" \
        "https://${S3_HOST}/${S3_BUCKET}/${S3_BASE_DIR}/$s3_key"
}

BASE_DIR="$(pwd)"
BT_SRCDIR="$SCRATCH_DIR/babeltrace"
COREDUMP_DIR="$SCRATCH_DIR/coredump"
BENCHMARK_DIR="$TMPDIR/ram_disk"
PREFIX="${BENCHMARK_DIR}/opt"

# Set the cpu governor to performance
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors
echo performance | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor

# Setup coredumps
mkdir -p "$COREDUMP_DIR"
echo "$COREDUMP_DIR/core.%e.%p.%h.%t" > /proc/sys/kernel/core_pattern
ulimit -c unlimited

# Create a 10GB ramdisk for the benchmark
mkdir "$BENCHMARK_DIR"
mount -t tmpfs -o size=10024m none "$BENCHMARK_DIR"

# Checkout the babeltrace git repo
git clone -q "${BT_REPO}" "$BT_SRCDIR"

TRACES=(
    'default'
    'tools_2_10'
    'tools_2_14'
)

TRACE_SINKS=(
    'dummy'
    'text'
)

while read -d ' ' -r commit ; do
    if [ -z "${commit}" ]; then
        echo "Empty commit" >&2
        continue
    fi

    cd "${BT_SRCDIR}"

    # Clean the source dir
    git clean -xdf

    # Checkout the commit to benchmark
    git checkout "${commit}"

    # Build and install babeltrace, a build failure should not abort the whole
    # benchmark run, only skip this commit.
    ./bootstrap || continue
    ./configure \
        CFLAGS='-O3 -g0 -flto -fuse-linker-plugin' \
        CXXFLAGS='-O3 -g0 -flto -fuse-linker-plugin' \
        LDFLAGS='-flto -fuse-linker-plugin' \
        BABELTRACE_DEV_MODE=0 \
        BABELTRACE_DEBUG_MODE=0 \
        BABELTRACE_MINIMAL_LOG_LEVEL=INFO \
        --prefix="$PREFIX" \
        --disable-man-pages || continue
    make -j || continue
    make install || continue

    ldconfig

    BT_BIN=$PREFIX/bin/babeltrace2
    if [ -a "$PREFIX/bin/babeltrace" ] ; then
        echo "Running bt1"
        BT_BIN=$PREFIX/bin/babeltrace
    fi

    cd "$BENCHMARK_DIR"

    for trace in "${TRACES[@]}" ; do
        trace_location_var="TRACE_${trace^^}_LOCATION"
        trace_location="${!trace_location_var}"
        trace_unpack_dir="${BENCHMARK_DIR}/trace_${trace}"

        # Download the test trace once
        if [ ! -d "${trace_unpack_dir}" ] ; then
            mkdir -p "${trace_unpack_dir}"
            curl "${trace_location}" -o - | tar -xzv -C "${trace_unpack_dir}"
        fi

        # Run the benchmark for each sink type
        for sink in "${TRACE_SINKS[@]}" ; do
            # Drop the page cache
            echo 3 | tee /proc/sys/vm/drop_caches

            ARGS=(
                "${trace_unpack_dir}"
            )

            if [[ "${sink}" == "dummy" ]]; then
                ARGS+=("-o" "dummy")
            fi

            python3 "$BASE_DIR/scripts/babeltrace-benchmark/time.py" --output=result --command "$BT_BIN" "${ARGS[*]}" --iteration 5 --taskset 0

            upload_artifact result "results/benchmarks/babeltrace/${sink}-${trace}/${commit}"

            rm -f result
        done
    done

    rm -rf "$PREFIX"
done <<< "${BT_COMMITS}"
