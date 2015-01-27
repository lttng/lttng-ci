# Create build directory
rm -rf $WORKSPACE/build
mkdir -p $WORKSPACE/build

PREFIX="$WORKSPACE/build"

./bootstrap

CONF_OPTS=""

case "$conf" in
static)
    echo "Static build"
    CONF_OPTS="--enable-static --disable-shared"
    ;;
tls_fallback)  
    echo  "Using pthread_getspecific() to emulate TLS"
    CONF_OPTS="--disable-compiler-tls"
    ;;
*)
    echo "Standard build"
    CONF_OPTS=""
    ;;
esac

# Build type
# oot : out-of-tree build
# dist: build via make dist
# *   : normal tree build
#
# Make sure to move to the build_path and configure
# before continuing

BUILD_PATH=$WORKSPACE
case "$build" in
	oot)
		echo "Out of tree build"
		BUILD_PATH=$WORKSPACE/oot
		mkdir -p $BUILD_PATH
		cd $BUILD_PATH
		$WORKSPACE/configure --prefix=$PREFIX $CONF_OPTS
		;;
	dist)
		echo "Distribution out of tree build"
		BUILD_PATH=`mktemp -d`

		# Initial configure and generate tarball
		./configure
		make dist

		mkdir -p $BUILD_PATH
		cp *.tar.* $BUILD_PATH/
		cd $BUILD_PATH

		# Ignore level 1 of tar
		tar xvf *.tar.* --strip 1

		$BUILD_PATH/configure --prefix=$PREFIX $CONF_OPTS
		;;
	*)
		BUILD_PATH=$WORKSPACE
		echo "Standard tree build"
		$WORKSPACE/configure --prefix=$PREFIX $CONF_OPTS
		;;
esac

make V=1
make install
make clean

# Cleanup rpath and libtool .la files
find $WORKSPACE/build/lib -name "*.so" -exec chrpath --delete {} \;
find $WORKSPACE/build/lib -name "*.la" -exec rm -f {} \;

if [ $build = "dist" ]; then
	rm -rf $BUILD_PATH
fi
