import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.15

Item {
    id: page
    property var host
    property var service

    readonly property bool compact: host ? host.compact : false
    readonly property color pageText: host ? host.pageText : "#F2F2EF"
    readonly property color mutedText: host ? host.mutedText : "#A8A8A2"
    readonly property color softText: host ? host.softText : "#74746F"
    readonly property color accent: host ? host.accentBlue : "#F5A400"
    readonly property color danger: host ? host.accentDanger : "#D75450"
    readonly property color good: host ? host.accentGreen : "#D7D3C8"
    readonly property color panel: host ? host.glassPanel : "#9926282A"
    readonly property color strongPanel: host ? host.glassStrong : "#B32C2E30"
    readonly property color border: host ? host.glassBorder : "#40FFFFFF"

    function icon(code) { return host ? host.mdi(code) : "" }
    function motionLabel(state) {
        if (state === "stationary") return "车辆静止"
        if (state === "idle_vibration") return "怠速振动"
        if (state === "likely_moving") return "行驶中"
        return "状态未知"
    }
    function calibrationLabel(state) {
        if (state === "ready") return "校准完成"
        if (state === "collecting") return "请保持静止，正在校准"
        if (state === "failed") return "校准失败，请重试"
        return "等待校准"
    }

    Flickable {
        id: pageScroll
        anchors.fill: parent
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        contentWidth: width
        contentHeight: contentColumn.implicitHeight + edgeMargin * 2

        property int edgeMargin: page.compact ? 14 : 22

        ScrollBar.vertical: ScrollBar {
            policy: pageScroll.contentHeight > pageScroll.height
                    ? ScrollBar.AlwaysOn : ScrollBar.AsNeeded
            active: hovered || pressed || pageScroll.movingVertically
        }

    ColumnLayout {
        id: contentColumn
        x: pageScroll.edgeMargin
        y: pageScroll.edgeMargin
        width: Math.max(0, pageScroll.width - pageScroll.edgeMargin * 2)
        spacing: page.compact ? 12 : 16

        RowLayout {
            Layout.fillWidth: true
            Layout.preferredHeight: page.compact ? 48 : 56
            spacing: 12

            Rectangle {
                Layout.preferredWidth: page.compact ? 42 : 48
                Layout.preferredHeight: width
                radius: width / 2
                color: page.panel
                border.width: 1
                border.color: page.border
                Text {
                    anchors.centerIn: parent
                    text: page.icon("F0141")
                    color: page.pageText
                    font.family: host ? host.iconFamily : "sans-serif"
                    font.pixelSize: page.compact ? 24 : 28
                }
                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: host.functionPage = "grid"
                }
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 1
                Text {
                    Layout.fillWidth: true
                    text: "车辆姿态与行驶质量"
                    color: page.pageText
                    font.family: host ? host.uiFamily : "sans-serif"
                    font.pixelSize: page.compact ? 19 : 24
                    font.bold: true
                    elide: Text.ElideRight
                }
                Text {
                    Layout.fillWidth: true
                    text: service ? service.statusText : "IMU 服务不可用"
                    color: service && service.available ? page.good : page.mutedText
                    font.family: host ? host.uiFamily : "sans-serif"
                    font.pixelSize: page.compact ? 11 : 13
                    elide: Text.ElideRight
                }
            }

            Rectangle {
                Layout.preferredWidth: page.compact ? 128 : 152
                Layout.preferredHeight: page.compact ? 40 : 44
                radius: height / 2
                color: host && host.imu3DLinked
                       ? Qt.rgba(245 / 255, 164 / 255, 0, 0.18)
                       : Qt.rgba(1, 1, 1, 0.06)
                border.width: 1
                border.color: host && host.imu3DLinked ? page.accent : page.border

                Text {
                    anchors.centerIn: parent
                    text: host && host.imu3DLinked ? "姿态联动" : "自由旋转"
                    color: host && host.imu3DLinked ? page.accent : page.mutedText
                    font.family: host ? host.uiFamily : "sans-serif"
                    font.pixelSize: page.compact ? 11 : 13
                    font.bold: true
                }

                Rectangle {
                    width: page.compact ? 21 : 23
                    height: width
                    radius: width / 2
                    anchors.verticalCenter: parent.verticalCenter
                    x: host && host.imu3DLinked ? parent.width - width - 8 : 8
                    color: host && host.imu3DLinked ? page.accent : Qt.rgba(1, 1, 1, 0.34)
                    border.width: 1
                    border.color: host && host.imu3DLinked
                                  ? Qt.rgba(1, 1, 1, 0.32)
                                  : Qt.rgba(1, 1, 1, 0.16)
                    Behavior on x { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
                    Behavior on color { ColorAnimation { duration: 160 } }
                }

                MouseArea {
                    anchors.fill: parent
                    anchors.margins: -4
                    cursorShape: Qt.PointingHandCursor
                    onClicked: if (host) host.imu3DLinked = !host.imu3DLinked
                }
            }
        }

        RowLayout {
            Layout.fillWidth: true
            Layout.preferredHeight: Math.min(page.compact ? 560 : 620,
                                             Math.max(page.compact ? 500 : 560,
                                                      pageScroll.height
                                                      - pageScroll.edgeMargin * 2
                                                      - (page.compact ? 48 : 56)
                                                      - contentColumn.spacing))
            spacing: page.compact ? 12 : 16

            ColumnLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: page.compact ? 10 : 14

                RowLayout {
                    Layout.fillWidth: true
                    Layout.preferredHeight: page.compact ? 92 : 108
                    Layout.maximumHeight: page.compact ? 92 : 108
                    spacing: page.compact ? 10 : 14

                    Repeater {
                        model: [
                            { name: "驾驶行为评分",
                              value: service && service.available ? service.drivingScore : "—",
                              suffix: service && service.available ? "分" : "",
                              tone: service && service.available ? page.accent : page.softText },
                            { name: "行驶平稳度",
                              value: service && service.available ? service.smoothnessScore : "—",
                              suffix: service && service.available ? "分" : "",
                              tone: service && service.available ? page.good : page.softText },
                            { name: "视觉可信度",
                              value: service && service.available ? Math.round(service.visionConfidence * 100) : "—",
                              suffix: service && service.available ? "%" : "",
                              tone: service && service.available && service.visionConfidence < 0.55 ? page.danger
                                    : service && service.available ? page.pageText : page.softText }
                        ]
                        delegate: Rectangle {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            radius: 18
                            color: page.strongPanel
                            border.width: 1
                            border.color: page.border
                            Column {
                                anchors.centerIn: parent
                                spacing: 3
                                Text {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    text: modelData.value + modelData.suffix
                                    color: modelData.tone
                                    font.family: host ? host.uiFamily : "sans-serif"
                                    font.pixelSize: page.compact ? 26 : 34
                                    font.bold: true
                                }
                                Text {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    text: modelData.name
                                    color: page.mutedText
                                    font.family: host ? host.uiFamily : "sans-serif"
                                    font.pixelSize: page.compact ? 10 : 12
                                }
                            }
                        }
                    }
                }

                Rectangle {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    radius: 22
                    color: page.panel
                    border.width: 1
                    border.color: page.border

                    Item {
                        anchors.fill: parent
                        anchors.margins: page.compact ? 18 : 22
                        visible: !(service && service.available)

                        Column {
                            anchors.centerIn: parent
                            width: Math.min(parent.width - 32, 360)
                            spacing: page.compact ? 8 : 10

                            Text {
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: page.icon("F0D91")
                                color: page.softText
                                opacity: 0.52
                                font.family: host ? host.iconFamily : "sans-serif"
                                font.pixelSize: page.compact ? 34 : 42
                            }

                            Text {
                                anchors.horizontalCenter: parent.horizontalCenter
                                width: parent.width
                                text: "等待 MPU6050 数据"
                                color: page.pageText
                                horizontalAlignment: Text.AlignHCenter
                                font.family: host ? host.uiFamily : "sans-serif"
                                font.pixelSize: page.compact ? 16 : 19
                                font.bold: true
                            }

                            Text {
                                anchors.horizontalCenter: parent.horizontalCenter
                                width: parent.width
                                text: service ? service.statusText : "IMU 服务不可用"
                                color: page.mutedText
                                horizontalAlignment: Text.AlignHCenter
                                wrapMode: Text.WordWrap
                                lineHeight: 1.25
                                font.family: host ? host.uiFamily : "sans-serif"
                                font.pixelSize: page.compact ? 10 : 12
                            }

                            Rectangle {
                                anchors.horizontalCenter: parent.horizontalCenter
                                width: page.compact ? 150 : 176
                                height: 32
                                radius: 16
                                color: Qt.rgba(1, 1, 1, 0.055)
                                border.width: 1
                                border.color: page.border

                                Text {
                                    anchors.centerIn: parent
                                    text: "接入后显示姿态地平仪"
                                    color: page.softText
                                    font.family: host ? host.uiFamily : "sans-serif"
                                    font.pixelSize: page.compact ? 9 : 10
                                }
                            }
                        }
                    }

                    RowLayout {
                        anchors.fill: parent
                        anchors.margins: page.compact ? 14 : 18
                        spacing: page.compact ? 14 : 20
                        visible: service && service.available

                        Rectangle {
                            id: horizon
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            Layout.minimumWidth: 280
                            radius: 18
                            clip: true
                            color: "#1A2025"
                            border.width: 1
                            border.color: page.border

                            Item {
                                width: parent.width * 1.8
                                height: parent.height * 1.8
                                anchors.centerIn: parent
                                y: (parent.height - height) / 2
                                   + (service ? service.pitch * 2.0 : 0)
                                rotation: service ? -service.roll : 0
                                Behavior on y { NumberAnimation { duration: 90 } }
                                Behavior on rotation { NumberAnimation { duration: 90 } }

                                Rectangle {
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    anchors.top: parent.top
                                    height: parent.height / 2
                                    color: "#273846"
                                }
                                Rectangle {
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    anchors.bottom: parent.bottom
                                    height: parent.height / 2
                                    color: "#3A3328"
                                }
                                Rectangle {
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    anchors.verticalCenter: parent.verticalCenter
                                    height: 2
                                    color: page.accent
                                }
                            }

                            Text {
                                anchors.centerIn: parent
                                text: "+"
                                color: page.pageText
                                font.pixelSize: 30
                                font.bold: true
                            }
                            Text {
                                anchors.left: parent.left
                                anchors.bottom: parent.bottom
                                anchors.margins: 12
                                text: "姿态地平仪"
                                color: page.mutedText
                                font.family: host ? host.uiFamily : "sans-serif"
                                font.pixelSize: page.compact ? 10 : 12
                            }
                        }

                        ColumnLayout {
                            Layout.preferredWidth: page.compact ? 210 : 260
                            Layout.fillHeight: true
                            spacing: page.compact ? 7 : 10

                            Text {
                                text: page.motionLabel(service ? service.motionState : "unknown")
                                color: page.accent
                                font.family: host ? host.uiFamily : "sans-serif"
                                font.pixelSize: page.compact ? 18 : 22
                                font.bold: true
                            }
                            Text {
                                text: page.calibrationLabel(service ? service.calibrationState : "uncalibrated")
                                color: service && service.calibrated ? page.good : page.mutedText
                                font.family: host ? host.uiFamily : "sans-serif"
                                font.pixelSize: page.compact ? 10 : 12
                            }

                            Repeater {
                                model: [
                                    { name: "横滚 Roll", value: service ? service.roll : 0 },
                                    { name: "俯仰 Pitch", value: service ? service.pitch : 0 },
                                    { name: "航向提示", value: service ? service.yawCue : 0 }
                                ]
                                delegate: RowLayout {
                                    Layout.fillWidth: true
                                    Text {
                                        Layout.fillWidth: true
                                        text: modelData.name
                                        color: page.mutedText
                                        font.family: host ? host.uiFamily : "sans-serif"
                                        font.pixelSize: page.compact ? 10 : 12
                                    }
                                    Text {
                                        text: modelData.value.toFixed(1) + "°"
                                        color: page.pageText
                                        font.family: host ? host.uiFamily : "sans-serif"
                                        font.pixelSize: page.compact ? 14 : 17
                                        font.bold: true
                                    }
                                }
                            }

                            Rectangle { Layout.fillWidth: true; height: 1; color: page.border }

                            Repeater {
                                model: [
                                    { name: "线加速度 X", value: service ? service.linearAccelX : 0 },
                                    { name: "线加速度 Y", value: service ? service.linearAccelY : 0 },
                                    { name: "线加速度 Z", value: service ? service.linearAccelZ : 0 }
                                ]
                                delegate: RowLayout {
                                    Layout.fillWidth: true
                                    Text {
                                        Layout.fillWidth: true
                                        text: modelData.name
                                        color: page.softText
                                        font.family: host ? host.uiFamily : "sans-serif"
                                        font.pixelSize: page.compact ? 9 : 11
                                    }
                                    Text {
                                        text: modelData.value.toFixed(2) + " g"
                                        color: page.pageText
                                        font.family: host ? host.uiFamily : "sans-serif"
                                        font.pixelSize: page.compact ? 11 : 13
                                    }
                                }
                            }

                            Item { Layout.fillHeight: true }

                            Text {
                                Layout.fillWidth: true
                                text: "丢样率 " + (service ? (service.dropRate * 100).toFixed(2) : "0.00") + "%"
                                color: page.softText
                                font.family: host ? host.uiFamily : "sans-serif"
                                font.pixelSize: page.compact ? 9 : 11
                            }
                        }
                    }
                }

                RowLayout {
                    Layout.fillWidth: true
                    Layout.preferredHeight: page.compact ? 42 : 48
                    spacing: 10

                    Button {
                        id: calibrateButton
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        text: "静止零偏校准"
                        enabled: service && service.available
                        onClicked: service.recalibrate()
                        background: Rectangle { radius: 13; color: calibrateButton.down ? "#33F5A400" : page.strongPanel; border.width: 1; border.color: page.border }
                        contentItem: Text { text: calibrateButton.text; color: page.pageText; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter; font.family: host ? host.uiFamily : "sans-serif"; font.pixelSize: page.compact ? 11 : 13; font.bold: true }
                    }
                    Button {
                        id: resetButton
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        text: "重置本次行程"
                        enabled: service && service.available
                        onClicked: service.resetTrip()
                        background: Rectangle { radius: 13; color: resetButton.down ? "#22FFFFFF" : page.strongPanel; border.width: 1; border.color: page.border }
                        contentItem: Text { text: resetButton.text; color: page.pageText; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter; font.family: host ? host.uiFamily : "sans-serif"; font.pixelSize: page.compact ? 11 : 13; font.bold: true }
                    }
                    Button {
                        id: recordButton
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        text: service && service.recording ? "停止记录" : "记录原始数据"
                        enabled: service && service.available
                        onClicked: service.setRecording(!service.recording)
                        background: Rectangle { radius: 13; color: service && service.recording ? "#33D75450" : page.strongPanel; border.width: 1; border.color: service && service.recording ? page.danger : page.border }
                        contentItem: Text { text: recordButton.text; color: service && service.recording ? page.danger : page.pageText; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter; font.family: host ? host.uiFamily : "sans-serif"; font.pixelSize: page.compact ? 11 : 13; font.bold: true }
                    }
                }
            }

            Rectangle {
                Layout.preferredWidth: page.compact ? 300 : 350
                Layout.fillHeight: true
                radius: 22
                color: page.panel
                border.width: 1
                border.color: page.border

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: page.compact ? 12 : 16
                    spacing: 10

                    RowLayout {
                        Layout.fillWidth: true
                        Text {
                            Layout.fillWidth: true
                            text: "事件记录"
                            color: page.pageText
                            font.family: host ? host.uiFamily : "sans-serif"
                            font.pixelSize: page.compact ? 15 : 18
                            font.bold: true
                        }
                        Button {
                            text: "清空"
                            flat: true
                            onClicked: if (service) service.events.clear()
                            contentItem: Text { text: parent.text; color: page.mutedText; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter; font.pixelSize: 12 }
                        }
                    }

                    ListView {
                        id: eventList
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        model: service ? service.events : null
                        spacing: 8
                        clip: true
                        boundsBehavior: Flickable.StopAtBounds

                        Text {
                            anchors.centerIn: parent
                            visible: eventList.count === 0
                            text: "暂无驾驶事件\n去抖与冷却正在工作"
                            horizontalAlignment: Text.AlignHCenter
                            color: page.softText
                            font.family: host ? host.uiFamily : "sans-serif"
                            font.pixelSize: page.compact ? 11 : 13
                            lineHeight: 1.5
                        }

                        delegate: Rectangle {
                            width: eventList.width
                            height: page.compact ? 68 : 78
                            radius: 14
                            color: critical ? Qt.rgba(215 / 255, 84 / 255, 80 / 255, 0.14)
                                            : Qt.rgba(1, 1, 1, 0.05)
                            border.width: 1
                            border.color: critical ? page.danger : page.border
                            RowLayout {
                                anchors.fill: parent
                                anchors.margins: 10
                                spacing: 8
                                Rectangle {
                                    width: 6
                                    Layout.fillHeight: true
                                    radius: 3
                                    color: critical ? page.danger : page.accent
                                }
                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 2
                                    Text { Layout.fillWidth: true; text: title; color: page.pageText; font.family: host ? host.uiFamily : "sans-serif"; font.pixelSize: page.compact ? 11 : 13; font.bold: true; elide: Text.ElideRight }
                                    Text { Layout.fillWidth: true; text: detail; color: page.mutedText; font.family: host ? host.uiFamily : "sans-serif"; font.pixelSize: page.compact ? 9 : 11; elide: Text.ElideRight }
                                    Text { text: timestamp; color: page.softText; font.family: host ? host.uiFamily : "sans-serif"; font.pixelSize: 9 }
                                }
                                Text {
                                    text: "×"
                                    color: page.mutedText
                                    font.pixelSize: 22
                                    MouseArea { anchors.fill: parent; anchors.margins: -8; onClicked: service.events.acknowledge(index) }
                                }
                            }
                        }
                    }

                    Rectangle { Layout.fillWidth: true; height: 1; color: page.border }
                    Text {
                        Layout.fillWidth: true
                        text: "碰撞/侧翻仅作为疑似风险提示，不能仅凭 IMU 判定事故。"
                        color: page.mutedText
                        wrapMode: Text.WordWrap
                        font.family: host ? host.uiFamily : "sans-serif"
                        font.pixelSize: page.compact ? 9 : 11
                    }
                }
            }
        }
    }
    }
}
