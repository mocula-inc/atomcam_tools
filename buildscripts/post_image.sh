#!/bin/bash
set -e

cd output/images
echo "atomcam" > hostname
touch authorized_keys
cp -dpf uImage.lzma factory_t31_ZMC6tiIDQN
mv rootfs.squashfs rootfs_hack.squashfs
rm -f /src/atomcam_tools.zip
zip -ry /src/atomcam_tools.zip factory_t31_ZMC6tiIDQN rootfs_hack.squashfs hostname authorized_keys
# firmware-deploy (buildscripts/upload_firmware.sh) はリポジトリ直下の atomcam_tools.zip を
# 読むため、そちらを正とする。dist/ には過去ビルドを追えるよう日時付きの控えを残す。
mkdir -p /src/dist/
cp -f /src/atomcam_tools.zip "/src/dist/atomcam_tools_$(date +"%Y-%m-%d_%H-%M-%S").zip"
cp -f factory_t31_ZMC6tiIDQN rootfs_hack.squashfs /src/target
