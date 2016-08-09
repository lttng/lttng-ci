# Set the JAVA_HOME to use according to the configuration

case "$arch" in
  "x86-32")
    ARCH_SUFFIX="i386"
    ;;
  "x86-64")
    ARCH_SUFFIX="amd64"
    ;;
  "*")
    ARCH_SUFFIX="$arch"
esac

echo "JAVA_HOME=/usr/lib/jvm/${java_version}-$ARCH_SUFFIX/jre"
