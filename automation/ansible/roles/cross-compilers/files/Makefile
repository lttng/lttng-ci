.PHONY: gcc48 gcc48-container gcc55 gcc55-container

all: gcc48 gcc55

#ARCHES = x86_64-pc-linux-gnu aarch64-linux-gnu arm-linux-gnueabihf i686-linux-gnu powerpc64le-linux-gnu powerpc-linux-gnu riscv64-linux-gnu s390x-linux-gnu
ARCHES = x86_64-pc-linux-gnu aarch64-linux-gnu
# The last build of gcc-4.8 used a native gcc-4.8 compiler from snapshot.debian.org,
# so we avoid rebuilding the host compiler at this time.
ARCHES_48 := $(filter-out x86_64-pc-linux-gnu,$(ARCHES))

gcc55: gcc55-container
	mkdir -p gcc55
	podman run --rm -e "TARGETS=$(ARCHES)" -e "SRC_DIR=/src/gcc-releases-gcc-5.5.0" -e "BIN_SUFFIX=5.5" -e "CSTD=gnu11" -e "CXXSTD=gnu++11" -v ./gcc55:/output localhost/gcc-5.5
	tar -czf gcc55.tar.gz -C gcc55 ./

gcc55-container:
	podman build -t gcc-5.5 -f gcc5.Containerfile .

gcc48: gcc48-container
	mkdir -p gcc48
	podman run --rm -e "TARGETS=$(ARCHES_48)" -v ./gcc48:/output localhost/gcc-4.8
	tar -czf gcc48.tar.gz -C gcc48 ./

gcc48-container:
	podman build -t gcc-4.8 -f Containerfile .

clean:
	rm -rf gcc55/ gcc48/
