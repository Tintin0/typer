# Vendored llama.cpp headers

These are public C API headers from [llama.cpp](https://github.com/ggml-org/llama.cpp)
(MIT License, © ggml.ai / Georgi Gerganov and contributors), included only as a
build fallback when llama.cpp isn't found via Homebrew or `$TYPER_LLAMA_PREFIX`.

The recommended path is `brew install llama.cpp`, which provides matching headers
**and** libraries; `scripts/build.sh` prefers that automatically.
