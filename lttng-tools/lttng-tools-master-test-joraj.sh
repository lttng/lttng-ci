#!/bin/bash
set -x
# Create build directory
rm -rf $WORKSPACE/build
mkdir -p $WORKSPACE/build

# liburcu
URCU_INCS="$WORKSPACE/dependencies/liburcu/build/include/"
URCU_LIBS="$WORKSPACE/dependencies/liburcu/build/lib/"

# lttng-ust
UST_INCS="$WORKSPACE/dependencies/lttng-ust/build/include/"
UST_LIBS="$WORKSPACE/dependencies/lttng-ust/build/lib/"
UST_PREFIX="$WORKSPACE/dependencies/lttng-ust/build/"

# babeltrace
BABEL_INCS="$WORKSPACE/dependencies/babeltrace/build/include/"
BABEL_LIBS="$WORKSPACE/dependencies/babeltrace/build/lib/"

PREFIX="$WORKSPACE/build"

CONF_OPTS=""
if [ "$conf" = "no_ust" ]
then
    export CPPFLAGS="-I$URCU_INCS"
    export LDFLAGS="-L$URCU_LIBS"
    export LD_LIBRARY_PATH="$URCU_LIBS:$BABEL_LIBS:$LD_LIBRARY_PATH"
else
	CONF_OPTS+=" --with-lttng-ust-prefix=$UST_PREFIX"
    export CPPFLAGS="-I$URCU_INCS"
    export LDFLAGS="-L$URCU_LIBS"
    export LD_LIBRARY_PATH="$URCU_LIBS:$BABEL_LIBS:$LD_LIBRARY_PATH"
fi

./bootstrap

case "$conf" in
# Currently disabled, ust doesn't seem to be built right for static linking.
#static)
#    echo "Static build"
#    CONF_OPTS="--enable-static --disable-shared"
#    ;;
python_bindings)
    echo "Build with python bindings"
    # We only support bindings built with Python 3
    export PYTHON="python3"
    export PYTHON_CONFIG="/usr/bin/python3-config"
    CONF_OPTS+=" --enable-python-bindings"
    ;;
no_ust)
    echo "Build without UST support"
    CONF_OPTS+=" --disable-lttng-ust"
    ;;
java_jul)
    echo "Build with java-jul UST support"
    CONF_OPTS+=" --enable-java-agent-tests-jul --with-java-classpath=$UST_PREFIX/share/java/\*"
	;;
java_log4j)
	echo "Build with java-log4j UST support"
	CONF_OPTS+=" --enable-java-agent-tests-log4j --with-java-classpath=/usr/share/java/log4j-1.2.jar"
	;;
*)
    echo "Standard build"
    CONF_OPTS+=" "
    ;;
esac

# Build type
# oot : out-of-tree build
# dist: build via make dist
# *   : normal tree build
#
# Make sure to move to the build_path and configure
# before continuing
echo "**************************************************"
echo $CONF_OPTS
echo "**************************************************"

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
		./configure $CONF_OPTS
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


make
make install

# Run tests
# Allow core dumps
ulimit -c unlimited

chmod +x $WORKSPACE/dependencies/babeltrace/build/bin/babeltrace
export PATH="$PATH:$WORKSPACE/dependencies/babeltrace/build/bin"

rm -rf $WORKSPACE/tap
mkdir -p $WORKSPACE/tap
mkdir -p $WORKSPACE/tap/unit
mkdir -p $WORKSPACE/tap/fast_regression
mkdir -p $WORKSPACE/tap/with_bindings_regression

cd $BUILD_PATH/tests

if [ "$conf" = "std" ]
then
    prove --merge --exec '' - < $BUILD_PATH/tests/unit_tests --archive $WORKSPACE/tap/unit/ || true
    prove --merge --exec '' - < $BUILD_PATH/tests/fast_regression --archive $WORKSPACE/tap/fast_regression/ || true
fi

if [ "$conf" = "java_jul" ]
then
	prove --merge --exec '' - < $BUILD_PATH/tests/unit_tests --archive $WORKSPACE/tap/unit/ || true
	prove --merge --exec '' - < $BUILD_PATH/tests/fast_regression --archive $WORKSPACE/tap/fast_regression/ || true
fi

if [ "$conf" = "no_ust" ]
then
    # Regression is disabled for now, we need to adjust the testsuite for no ust builds.
    echo "Testsuite disabled. See job configuration for more info."
fi

if [ "$conf" = "python_bindings" ]
then
    # Disabled due to race conditions in tests
    echo "Testsuite disabled. See job configuration for more info."
    prove --merge --exec '' - < $BUILD_PATH/tests/unit_tests --archive $WORKSPACE/tap/unit/ || true
    prove --merge --exec '' - < $BUILD_PATH/tests/fast_regression --archive $WORKSPACE/tap/fast_regression/ || true
    prove --merge --exec '' - < $BUILD_PATH/tests/with_bindings_regression --archive $WORKSPACE/tap/with_bindings_regression/ || true
fi

# TAP plugin is having a hard time with .yml files.
rm -f $WORKSPACE/tap/unit/meta.yml
rm -f $WORKSPACE/tap/fast_regression/meta.yml
rm -f $WORKSPACE/tap/with_bindings_regression/meta.yml

# And also with files without extension, so rename all result to *.tap
find $WORKSPACE/tap/unit/ -type f -exec mv {} {}.tap \;
find $WORKSPACE/tap/fast_regression/ -type f -exec mv {} {}.tap \;
find $WORKSPACE/tap/with_bindings_regression/ -type f -exec mv {} {}.tap \;

# Cleanup
make clean

# Cleanup rpath and libtool .la files
find $WORKSPACE/build/bin -executable -type f -exec chrpath --delete {} \;
find $WORKSPACE/build/lib -name "*.so" -exec chrpath --delete {} \;
find $WORKSPACE/build/lib -name "*.la" -exec rm -f {} \;

# Clean temp dir for dist build
if [ $build = "dist" ]; then
	rm -rf $BUILD_PATH
fi
set +x
