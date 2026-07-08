#!/usr/bin/env bash
set -euo pipefail

qml_file="${1:-QML_version/qml/main.qml}"

if rg -Fq 'id: homeCameraSwitch' "$qml_file"; then
    echo "home camera shortcut switch should not be present"
    exit 1
fi
rg -Fq 'id: cameraPageCameraSwitch' "$qml_file"

command_count="$(rg -c 'fatigueService\.setCameraEnabled\(' "$qml_file")"
test "$command_count" -eq 1

checked_count="$(rg -F -c 'checked: fatigueService.cameraEnabled || fatigueService.cameraState === "starting"' "$qml_file")"
test "$checked_count" -eq 1

rg -Fq 'if (k === "camera_off") return "摄像头已关闭"' "$qml_file"
rg -Fq 'fatigueService.setWantFrames(root.cameraPageActive && fatigueService.cameraEnabled)' "$qml_file"
rg -Fq 'function onCameraControlChanged()' "$qml_file"
rg -Fq 'feedView.clear()' "$qml_file"

echo "camera controls: PASS"
