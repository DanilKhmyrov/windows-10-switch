# Toolchain for mesa-switch-woa's NVK Vulkan driver for Windows ARM64 (Linux ARM64 build host):
# host LLVM/Clang with libclc and the SPIR-V translator for Mesa's build-time tools (mesa_clc,
# vtn_bindgen2), Rust with the aarch64-pc-windows-gnullvm target, bindgen and cbindgen, and
# LLVM-MinGW for the Windows ARM64 cross build. See drivers/nvk/build.sh.
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl git xz-utils build-essential pkg-config cmake ninja-build bison flex \
        python3 python3-pip python3-mako python3-yaml python3-packaging python3-ply \
        llvm-18-dev clang-18 libclang-18-dev libclang-cpp18-dev libclc-18-dev llvm-spirv-18 \
        libllvmspirvlib-18-dev spirv-tools glslang-tools zlib1g-dev libzstd-dev libexpat1-dev \
    && rm -rf /var/lib/apt/lists/*
# Mesa needs Meson >= 1.4 (Ubuntu 24.04 ships 1.3).
RUN pip3 install --break-system-packages --no-cache-dir meson==1.7.2
ENV RUSTUP_HOME=/opt/rustup CARGO_HOME=/opt/cargo PATH=/opt/cargo/bin:/usr/lib/llvm-18/bin:$PATH
RUN curl -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain 1.90.0 \
        --target aarch64-pc-windows-gnullvm \
    && cargo install --locked bindgen-cli@0.71.1 cbindgen@0.28.0 \
    && rm -rf /opt/cargo/registry /opt/cargo/git
ARG LLVM_MINGW=llvm-mingw-20261020-ucrt-ubuntu-22.04-aarch64
RUN curl -sSfL "https://github.com/mstorsjo/llvm-mingw/releases/download/20261020/$LLVM_MINGW.tar.xz" \
        | tar -xJ -C /opt && mv "/opt/$LLVM_MINGW" /opt/llvm-mingw
ENV PATH=$PATH:/opt/llvm-mingw/bin
