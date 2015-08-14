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
python_bindings)  
    echo "Build with python bindings"
    # We only support bindings built with Python 3
    export PYTHON="python3"
    export PYTHON_CONFIG="/usr/bin/python3-config"
    CONF_OPTS="--enable-python-bindings"
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
TEST_PLAN_PATH=$WORKSPACE

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

		# Set test plan to dist tar
		TEST_PLAN_PATH=$BUILD_PATH
		;;
	*)
		echo "Standard tree build"
		$WORKSPACE/configure --prefix=$PREFIX $CONF_OPTS
		;;
esac

make
make install

rm -rf $WORKSPACE/tap
mkdir -p $WORKSPACE/tap

cd $BUILD_PATH/tests

# Run make check tests
if [ -e $TEST_PLAN_PATH/tests/tests ]; then
	prove --merge --exec '' - < $TEST_PLAN_PATH/tests/tests --archive $WORKSPACE/tap/ || true
else
	echo "Missing test plan"
	exit 1
fi

# TAP plugin is having a hard time with .yml files.
rm -f $WORKSPACE/tap/meta.yml

# And also with files without extension, so rename all result to *.tap
find $WORKSPACE/tap/ -type f -exec mv {} {}.tap \;

make clean

# Cleanup rpath and libtool .la files
find $WORKSPACE/build/bin -executable -type f -exec chrpath --delete {} \;
find $WORKSPACE/build/lib -name "*.so" -exec chrpath --delete {} \;
find $WORKSPACE/build/lib -name "*.la" -exec rm -f {} \;

if [ $build = "dist" ]; then
	rm -rf $BUILD_PATH
fi
