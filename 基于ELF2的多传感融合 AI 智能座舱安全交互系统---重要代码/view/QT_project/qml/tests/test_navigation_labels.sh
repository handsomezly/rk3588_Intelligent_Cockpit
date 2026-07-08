#!/usr/bin/env bash
set -euo pipefail

qml_file="${1:-QML_version/qml/main.qml}"

rg -Fq 'text: "AI 智能座舱安全交互系统"' "$qml_file"
! rg -Fq 'text: "疲劳驾驶智能座舱监测系统"' "$qml_file"
! rg -Fq 'text: model.hint' "$qml_file"
rg -Fq 'id: navLabel' "$qml_file"
rg -Fq 'anchors.verticalCenter: parent.verticalCenter' "$qml_file"

echo "navigation labels: PASS"
