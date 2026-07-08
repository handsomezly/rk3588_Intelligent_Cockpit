#!/bin/sh

set -u

rc=0

load_module()
{
    module_name="$1"
    module_path="$2"

    if grep -q "^${module_name} " /proc/modules; then
        echo "${module_name}: already loaded"
        return 0
    fi

    if [ ! -f "${module_path}" ]; then
        echo "${module_name}: ${module_path} not found" >&2
        return 1
    fi

    echo "loading ${module_name}: ${module_path}"
    insmod "${module_path}"
}

load_module dht11_drv /root/workspace/driver/01_dht11/dht11_drv.ko || rc=1
load_module bh1750_drv /root/workspace/driver/02_gy30/bh1750_drv.ko || rc=1
load_module mlx90614_drv /root/workspace/driver/03_mlx90614/mlx90614_drv.ko || rc=1
load_module mpu6050 /root/workspace/driver/04_mpu6050/mpu6050.ko || rc=1

load_module snd_hwdep       /root/workspace/driver/audio/snd-hwdep.ko       || rc=1
load_module snd_rawmidi     /root/workspace/driver/audio/snd-rawmidi.ko     || rc=1
load_module snd_usbmidi_lib /root/workspace/driver/audio/snd-usbmidi-lib.ko || rc=1
load_module snd_usb_audio   /root/workspace/driver/audio/snd-usb-audio.ko   || rc=1

exit "${rc}"
