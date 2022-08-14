#!/bin/bash

ARCH=`uname -m`
OS=`uname`
TARGET="bkg-"
TARGET+=$ARCH
TARGET+="-"

if [[ $OS == "Linux" ]]
then
    TARGET+="linux"
elif [[ $OS == "Darwin" ]]
then
    TARGET+="macos"
else
    echo "Unsupported OS/CPU"
    exit 1
fi

URL="https://github.com/theseyan/bkg/releases/latest/download/"
URL+=$TARGET

echo "Downloading bkg..."
wget -O /usr/local/bin/bkg $URL
chmod +x /usr/local/bin/bkg
echo "bkg was successfully installed to /usr/local/bin/bkg"
echo "Run \`bkg --help\` to get started!"