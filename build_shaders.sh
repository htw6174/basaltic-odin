#!/usr/bin/env bash
set -e

if [ -z "$1" ]
then
    echo "usage: ./build_shaders.sh [path-to-sokol-shdc]"
    exit 1
fi

shdc="$1"

build_shader() {
    name=$1
    dir=source/shader
    echo $dir/$name
    # NOTE: disabled metal_macos because lacking support for PrimitiveID in fragment language
    # NOTE: likely a bug with wgsl and shader includes (specific to odin bindings?), disabled for now
    $shdc -i $dir/$name.glsl -o $dir/$name.odin -l glsl430:hlsl5 -f sokol_odin
}

build_shader cube
build_shader terrain
