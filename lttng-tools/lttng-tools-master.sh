# Create build directory
rm -rf $WORKSPACE/build
mkdir -p $WORKSPACE/build

# liburcu
URCU_INCS="$WORKSPACE/dependencies/liburcu/build/include/"
URCU_LIBS="$WORKSPACE/dependencies/liburcu/build/lib/"

# lttng-ust
UST_INCS="$WORKSPACE/dependencies/lttng-ust/build/include/"
UST_LIBS="$WORKSPACE/dependencies/lttng-ust/build/lib/"

# babeltrace
BABEL_INCS="$WORKSPACE/dependencies/babeltrace/build/include/"
BABEL_LIBS="$WORKSPACE/dependencies/babeltrace/build/lib/"

PREFIX="$WORKSPACE/build"

if [ "$conf" = "no_ust" ]
then
    export CPPFLAGS="-I$URCU_INCS"
    export LDFLAGS="-L$URCU_LIBS"
    export LD_LIBRARY_PATH="$URCU_LIBS:$BABEL_LIBS:$LD_LIBRARY_PATH"
else
    export CPPFLAGS="-I$URCU_INCS -I$UST_INCS"
    export LDFLAGS="-L$URCU_LIBS -L$UST_LIBS"
    export LD_LIBRARY_PATH="$URCU_LIBS:$UST_LIBS:$BABEL_LIBS:$LD_LIBRARY_PATH"
fi

./bootstrap

CONF_OPTS=""
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
    CONF_OPTS="--enable-python-bindings"
    ;;
no_ust)
    echo "Build without UST support"
    CONF_OPTS="--disable-lttng-ust"
    ;;
*)
    echo "Standard build"
    CONF_OPTS=""
    ;;
esac

./configure --prefix=$PREFIX $CONF_OPTS

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

cd $WORKSPACE/tests

if [ "$conf" = "std" ]
then
    prove --merge --exec '' - < $WORKSPACE/tests/unit_tests --archive $WORKSPACE/tap/unit/ || true
    prove --merge --exec '' - < $WORKSPACE/tests/fast_regression --archive $WORKSPACE/tap/fast_regression/ || true
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
    prove --merge --exec '' - < $WORKSPACE/tests/unit_tests --archive $WORKSPACE/tap/unit/ || true
    prove --merge --exec '' - < $WORKSPACE/tests/fast_regression --archive $WORKSPACE/tap/fast_regression/ || true
    prove --merge --exec '' - < $WORKSPACE/tests/with_bindings_regression --archive $WORKSPACE/tap/with_bindings_regression/ || true
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
