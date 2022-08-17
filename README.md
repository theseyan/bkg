<div align="center">
<br>
<h1>bkg</h1><br>
<i>
Package Bun apps into a single executable
</i>
<br><br>
<img alt="GitHub Workflow Status" src="https://img.shields.io/github/workflow/status/theseyan/bkg/CI">

<br><br>
</div>

bkg is a CLI tool that can generate self-sufficient binaries from your Bun code for multiple platforms.

## Usage

Fastest way to install:
```
curl -fsSL https://github.com/theseyan/bkg/raw/main/install.sh | sudo sh
```

OR, get the [latest release](https://github.com/theseyan/bkg/releases) for your platform (`bkg_runtime-` binaries are not required, they will be automatically downloaded).

Run `bkg --help` to get a list of options on usage:

```console
Usage: bkg [options] <ProjectDirectory>
Example: bkg myProject -o myapp

Options:
  -h, --help             Display this help message.
  -o, --output <str>     Output file name
  -t, --target <str>     Target architecture to build for (default is Host)
  --targets              Display list of supported targets
  --runtime <str>        Path to custom Bun binary (not recommended)
  -v, --version          Display bkg version.
  <str>...
```
### `bkg.config.json`
bkg assumes `index.js` to be the entry point of your application. This can be changed by creating `bkg.config.json` at the root directory of your project:
```json
{
    "entry": "app.ts"
}
```

## Why?
- Distribute a single binary that can run without Bun or any external dependencies installed
- Build executables for any platform supported by Bun
- Around 1/2 the size of Bun runtime
- Package any asset into the binary, not just scripts and modules
- No performance regression except for the first startup
- Although not yet possible, the goal is generating bytecode and the ability to distribute binaries stripped of sources

## Differences from `pkg`

bkg and pkg (Node) have a number of differences arising either from a design decision or a Bun limitation:
- **Sources are not compiled to bytecode:** Bun does not expose a JavascriptCore equivalent of `v8::ScriptCompiler` yet, hence sources are kept intact in the compiled executable.
- **File system:** bkg does not embed a virtual filesystem but instead archives sources using the very fast [LZ4 compression](https://github.com/lz4/lz4) which are decompressed to a temporary location at runtime. This makes the resulting binary about 1/2 the size of Bun itself, while not having to keep the entire runtime in memory.
- **Import resolution:** Unlike pkg, we do not recursively traverse through each import in the sources and package those files (yet). bkg will simply archive the entire source folder - this will change in version 1.0.

## Key takeaways

- bkg is **not** meant for very dynamic environments (for eg. serverless), as it adds considerable overhead to startup time. However, this overhead is only valid for the first start as the decompressed sources are cached in the filesystem onwards.
- It is not recommended to perform `fs` operations with relative paths, as there is no guarantee where the sources may be placed at runtime. This will be fixed when I complete overriding some of `fs` default paths.
- Generated executables must not be stripped or the embedded code sources get corrupted.

# Building from source
bkg is written in Zig and compilation is fairly straightforward. The prerequisites are:
- Zig version [0.10.0-dev.3554+bfe8a4d9f](https://ziglang.org/builds/zig-0.10.0-dev.3554+bfe8a4d9f.tar.xz)

```bash
# Clone the repository and update submodules
git clone https://github.com/theseyan/bkg && cd bkg
git submodule update --init --recursive

# Build for x86_64-linux
zig build -Drelease-fast -Dtarget=x86_64-linux

# [Optional] Build runtime for x86_64-linux
zig build-exe -target x86_64-linux src/bkg_runtime.zig -lc deps/lz4/lib/lz4.c deps/microtar/src/microtar.c --pkg-begin known-folders deps/known-folders/known-folders.zig --pkg-end

# Run bkg
./zig-out/bin/bkg --help

# OR, build runtime and CLI for all platforms
# Generated executables are placed in /build
chmod +x build.sh && ./build.sh
```

# Todo

**Release v0.1.0:**
- Switch to LZ4 high compression variant that compresses more but doesn't affect decompression speed (and shaves off 7MB!)
- :white_check_mark: ~~Runtime: Stream decompressed buffer directly to microtar instead of through the filesystem. This will greatly improve startup time.~~
- Compiler: Stream archive directly to `LZ4_compress_HC` instead of through the filesystem
- :white_check_mark: ~~Use [zfetch](https://github.com/truemedian/zfetch) instead of cURL~~
- :white_check_mark: ~~JSON configuration file~~
- :white_check_mark: ~~Pass CLI args to javascript~~
- :white_check_mark: ~~Named app directory containing the CRC32 hash of project sources. This will fix outdated cached code being executed.~~
- Override Bun default variables with an injected JS entry point

**Roadmap: v1.0**
- Optimizer/Bundler based on Rollup.js to bundle entire source tree into a handful of JS files. This is important because currently our biggest bottleneck is decompression speed with lots of files (>1000 files) which is common in projects with `node_modules`. Ideally, this will be replaced by Bun's own bundler.
- Prebuild, postbuild options and CLI argument counterparts of `bkg.config.json`
- Bundle sources (and possibly node_modules) into a single file before packaging
- Bun CLI flags
- Fork a custom build of Bun with only the JS runtime and use that instead of the official binaries