#!/bin/sh

set -e

ARCH=`uname -m`
OS=`uname`
TARGET="bkg-${ARCH}-"

if [ "${OS}" = "Linux" ]
then
    TARGET="${TARGET}linux"
elif [ "$OS" = "Darwin" ]
then
    TARGET="${TARGET}macos"
else
    echo "Unsupported OS/CPU"
    exit 1
fi

URL="https://github.com/theseyan/bkg/releases/latest/download/"
URL="${URL}${TARGET}"

echo "Downloading bkg..."
curl --fail --location --progress-bar --output /usr/local/bin/bkg $URL
chmod +x /usr/local/bin/bkg
echo "bkg was successfully installed to /usr/local/bin/bkg"
echo "Run \`bkg --help\` to get started!"