#!/bin/bash

rm -r build
mkdir build

## CLI tool
# Binaries are automatically stripped (set in build.zig)

# Build bkg for x86_64-linux
echo "Building bkg CLI for x86_64-linux..."
zig build -Drelease-fast -Dtarget=x86_64-linux
mv zig-out/bin/bkg build/bkg-x86_64-linux

# Build bkg for aarch64-linux
echo "Building bkg CLI for aarch64-linux..."
zig build -Drelease-fast -Dtarget=aarch64-linux
mv zig-out/bin/bkg build/bkg-aarch64-linux

# Build bkg for x86_64-macos
echo "Building bkg CLI for x86_64-macos..."
zig build -Drelease-fast -Dtarget=x86_64-macos.12
mv zig-out/bin/bkg build/bkg-x86_64-macos

# Build bkg for aarch64-macos
echo "Building bkg CLI for aarch64-macos..."
zig build -Drelease-fast -Dtarget=aarch64-macos.12
mv zig-out/bin/bkg build/bkg-aarch64-macos

## Runtime
# Binaries are stripped with --strip flag

# Build bkg_runtime for x86_64-linux
echo "Building bkg runtime for x86_64-linux..."
zig build-exe -target x86_64-linux -Drelease-fast src/bkg_runtime.zig --strip -lc deps/lz4/lib/lz4.c deps/microtar/src/microtar.c --pkg-begin known-folders deps/known-folders/known-folders.zig --pkg-end
mv bkg_runtime build/bkg_runtime-x86_64-linux

# Build bkg_runtime for aarch64-linux
echo "Building bkg runtime for aarch64-linux..."
zig build-exe -target aarch64-linux -Drelease-fast src/bkg_runtime.zig --strip -lc deps/lz4/lib/lz4.c deps/microtar/src/microtar.c --pkg-begin known-folders deps/known-folders/known-folders.zig --pkg-end
mv bkg_runtime build/bkg_runtime-aarch64-linux

# Build bkg_runtime for x86_64-macos
echo "Building bkg runtime for x86_64-macos..."
zig build-exe -target x86_64-macos -Drelease-fast src/bkg_runtime.zig --strip -lc deps/lz4/lib/lz4.c deps/microtar/src/microtar.c --pkg-begin known-folders deps/known-folders/known-folders.zig --pkg-end
mv bkg_runtime build/bkg_runtime-x86_64-macos

# Build bkg_runtime for aarch64-macos
echo "Building bkg runtime for aarch64-macos..."
zig build-exe -target aarch64-macos -Drelease-fast src/bkg_runtime.zig --strip -lc deps/lz4/lib/lz4.c deps/microtar/src/microtar.c --pkg-begin known-folders deps/known-folders/known-folders.zig --pkg-end
mv bkg_runtime build/bkg_runtime-aarch64-macos

echo "Done!"