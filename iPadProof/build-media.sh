#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
root="$PWD"
mkdir -p build-media/install /private/tmp/binge-ipad-ffmpeg
if [[ ! -d /private/tmp/binge-ipad-ffmpeg/source ]]; then cp -R vendor/ffmpeg-8.0 /private/tmp/binge-ipad-ffmpeg/source; fi
mkdir -p /private/tmp/binge-ipad-ffmpeg/build
cd /private/tmp/binge-ipad-ffmpeg/build
sdk=$(xcrun --sdk iphoneos --show-sdk-path)
../source/configure --prefix="/private/tmp/binge-ipad-ffmpeg/install" \
 --target-os=darwin --arch=aarch64 --enable-cross-compile --cc="$(xcrun --find clang)" --ar="$(xcrun --find ar)" --ranlib="$(xcrun --find ranlib)" \
 --sysroot="$sdk" --extra-cflags='-target arm64-apple-ios17.0 -fPIC' --extra-ldflags='-target arm64-apple-ios17.0' \
 --disable-everything --disable-autodetect --disable-programs --disable-doc --disable-debug --disable-asm \
 --disable-network --disable-avdevice --disable-avfilter --disable-swscale --enable-swresample \
 --enable-static --disable-shared --enable-avformat --enable-avcodec --enable-avutil \
 --enable-demuxer=matroska,mov,srt,webvtt --enable-muxer=mp4,hls,webvtt --enable-protocol=file \
 --enable-parser=h264,hevc,aac,ac3,dca,flac,opus --enable-decoder=h264,hevc,subrip,webvtt,ac3,eac3,dca,mp3,opus,vorbis,flac,truehd,pcm_s16le,pcm_s24le,pcm_f32le --enable-encoder=movtext,webvtt,aac
rg -q '^#define CONFIG_MOVTEXT_ENCODER 1$' config_components.h
rg -q '^#define CONFIG_SUBRIP_DECODER 1$' config_components.h
make -j4
make install

cp -R /private/tmp/binge-ipad-ffmpeg/install/include "$root/build-media/install/"
cp -R /private/tmp/binge-ipad-ffmpeg/install/lib "$root/build-media/install/"
