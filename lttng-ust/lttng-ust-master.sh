# Create build directory
rm -rf $WORKSPACE/build
mkdir -p $WORKSPACE/build

# liburcu
URCU_INCS="$WORKSPACE/dependencies/liburcu/build/include/"
URCU_LIBS="$WORKSPACE/dependencies/liburcu/build/lib/"

export CPPFLAGS="-I$URCU_INCS"
export LDFLAGS="-L$URCU_LIBS"
export LD_LIBRARY_PATH="$URCU_LIBS:$LD_LIBRARY_PATH"

PREFIX="$WORKSPACE/build"

./bootstrap

CONF_OPTS=""

case "$conf" in
# Unsupported! liblttng-ust can't pull in it's static (.a) dependencies.
#static)
#    echo "Static build"
#    CONF_OPTS="--enable-static --disable-shared"
#    ;;
java-agent)
    echo "Java agent build"
    export CLASSPATH="/usr/share/java/log4j-1.2.jar"
    CONF_OPTS="--enable-java-agent-all"
    ;;
python-agent)
	echo "Python agent build"
	CONF_OPTS="--enable-python-agent"
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
		BUILD_PATH=$WORKSPACE/oot
		mkdir -p $BUILD_PATH
		cd $BUILD_PATH
		$WORKSPACE/configure --prefix=$PREFIX $CONF_OPTS
		;;
	dist)
		BUILD_PATH=/tmp/dist

		# Initial configure and generate tarball
		./configure
		make dist

		mkdir -p $BUILD_PATH
		cp *.tar.* $BUILD_PATH/
		cd $BUILD_PATH
		$BUILD_PATH/configure --prefix=$PREFIX $CONF_OPTS

		# Ignore level 1 of tar
		tar xvf *.tar.* --strip 1
		;;
	*)
		BUILD_PATH=$WORKSPACE
		$WORKSPACE/configure --prefix=$PREFIX $CONF_OPTS
		;;
esac

make V=1
make install

# Run tests
rm -rf $WORKSPACE/tap
mkdir -p $WORKSPACE/tap/unit

cd $BUILD_PATH/tests

prove --merge --exec '' - < $BUILD_PATH/tests/unit_tests --archive $WORKSPACE/tap/unit/ || true

# TAP plugin is having a hard time with .yml files.
rm -f $WORKSPACE/tap/unit/meta.yml

# And also with files without extension, so rename all result to *.tap
find $WORKSPACE/tap/unit/ -type f -exec mv {} {}.tap \;

# Cleanup
make clean

# Cleanup rpath and libtool .la files
find $WORKSPACE/build/lib -name "*.so" -exec chrpath --delete {} \;
find $WORKSPACE/build/lib -name "*.la" -exec rm -f {} \;
