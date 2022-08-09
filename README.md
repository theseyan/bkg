<div align="center">
<br>
<h1>bkg</h1><br>
<i>
Package Bun apps into a single executable
</i>
<!--<br><br>
<a href="https://lgtm.com/projects/g/theseyan/arian/context:javascript"><img alt="LGTM Grade" src="https://img.shields.io/lgtm/grade/javascript/github/theseyan/arian?logo=lgtm"></a>-->

<br><br>
</div>

# WIP

This is a work in progress, the compiler does not work yet.

## Why?
- Distribute a single binary without any dependencies, smaller than the Bun runtime itself
- Build executables for any architecture supported by Bun
- Package any asset into the binary, not just scripts and modules

## Differences from `pkg`

bkg and pkg (Node) have a number of differences arising either from a design decision or a Bun limitation:
- **Sources are not compiled to bytecode:** Bun does not expose an equivalent of `v8::ScriptCompiler` yet, hence sources are kept intact in the compiled executable.
- **File system:** bkg does not embed a virtual filesystem but instead archives the sources using the very fast [LZ4 compression](https://github.com/lz4/lz4) which are decompressed to a temporary location at runtime. This makes the resulting binary about 1/2 the size of Bun itself, while not having to keep the entire runtime in memory.
- **Import resolution:** Unlike pkg, we do not recursively traverse through each import in the sources and package those files (yet). bkg will simply archive the entire source folder - this will change once Bun can bundle dependencies and the sources into one file.

## Key takeaways

- bkg is **not** meant for very dynamic environments (for eg. serverless), as it adds considerable overhead to startup time. However, this overhead is only valid for the first start as the decompressed sources are cached in the filesystem onwards.
- It is not recommended to perform `fs` operations with relative paths, as there is no guarantee where the sources may be placed at runtime. This may be fixed when I complete overriding some of the `fs` default paths.

## Todo

There are a number of possible optimizations:
- Fork a custom build of Bun with only the JS runtime and use that instead of the official binaries
- JSON based build script
- If size of `bun` can be brought down under 50 MB, consider executing directly from memory