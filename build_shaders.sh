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
    echo $dir
    $shdc -i $dir/$name.glsl -o $dir/$name.odin -l glsl430:metal_macos:hlsl5 -f sokol_odin
}

build_shader cube
build_shader terrain
