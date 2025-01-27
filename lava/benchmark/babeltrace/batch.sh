#!/usr/bin/bash

COMMITS="${COMMITS:-}"
BT_REPO="${1}"
BENCHMARK_DIR="${2}"

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

    pushd "${BT_REPO}" || continue
    git clean -dxf
    git checkout "${commit}"
    ./bootstrap || continue
    ./configure CFLAGS='-O3 -g0 -flto -fuse-linker-plugin' CXXFLAGS='-O3 -g0 -flto -fuse-linker-plugin' LDFLAGS='-flto -fuse-linker-plugin' BABELTRACE_DEV_MODE=0 BABELTRACE_DEBUG_MODE=0 BABELTRACE_MINIMAL_LOG_LEVEL=INFO --disable-man-pages || continue
    make -j || continue
    make install || continue
    ldconfig
    BT_BIN=/usr/local/bin/babeltrace2
    if [ -a /usr/local/bin/babeltrace ] ; then
        echo "Running bt1"
        BT_BIN=/usr/local/bin/babeltrace
    fi
    popd || continue

    for trace in "${TRACES[@]}" ; do
        trace_location_var="TRACE_${trace}_LOCATION"
        trace_location="${!trace_location_var}"
        trace_unpack_dir="${BENCHMARK_DIR}/trace_${trace}"
        if [ ! -d "${trace_unpack_dir}" ] ; then
            mkdir -p "${trace_unpack_dir}"
            curl "${trace_location}" -o - | tar -C "${trace_unpack_dir}" -xz
        fi

        for sink in "${TRACE_SINKS[@]}" ; do
            echo 3 | tee /proc/sys/vm/drop_caches
            ARGS=(
                "${BT_BIN}"
                "${trace_unpack_dir}"
            )
            if [[ "${sink}" == "dummy" ]]; then
                ARGS+=("-o" "dummy")
            fi

            python3 ./ci/scripts/babeltrace-benchmark/time.py --output=result --command "${ARGS[*]}" --iteration 5 --taskset 0
            ./ci/lava/upload_artifact.sh result "results/benchmarks/babeltrace/${sink}-${trace}/${commit}"
            rm -f result
        done
    done

    rm -rf /usr/local/* ; mkdir -p /usr/local
done <<< "${COMMITS}"
