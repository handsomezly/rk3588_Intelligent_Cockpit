import QtQuick 2.15
import QtQuick.Window 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.15
import QtQuick.Scene3D 2.15
import QtGraphicalEffects 1.15
import QtMultimedia 5.15
import Qt3D.Core 2.15
import Qt3D.Render 2.15
import Qt3D.Input 2.15
import Qt3D.Extras 2.15
import Cockpit 1.0

Item {
    id: root
    // 不写死尺寸；view 用 SizeRootObjectToView，root 跟着 view 走。
    // 之前 width:1280 height:800 会让 compact 初值为 false，
    // 然后大量 Layout.preferredHeight 已经按非 compact 算好，
    // 收到 resize 后部分项目不重排，nav 被挤出屏幕外。

    Rectangle {
        anchors.fill: parent
        color: "#070809"
        z: -100
    }

    property bool compact: width < 1120 || height < 700
    property int pageMargin: compact ? 18 : 28
    property int activeNavIndex: 0
    property string functionPage: "grid"
    property bool homePageActive: activeNavIndex === 0
    property bool cameraPageActive: activeNavIndex === 1 && functionPage === "camera"
    property bool videoPageActive: activeNavIndex === 1 && functionPage === "video"
    property bool musicPageActive: activeNavIndex === 1 && functionPage === "music"
    property bool aiPageActive: activeNavIndex === 1 && functionPage === "ai"
    property bool thermoPageActive: activeNavIndex === 1 && functionPage === "thermo"
    property bool imuPageActive: activeNavIndex === 1 && functionPage === "imu"
    property bool imu3DLinked: false
    property bool imuAlertVisible: false
    property string imuAlertTitle: ""
    property string imuAlertDetail: ""
    property var thermoHistory: []
    readonly property int thermoMaxPoints: 90
    property bool bodyTempPageActive: activeNavIndex === 1 && functionPage === "bodytemp"
    property var bodyTempHistory: []
    readonly property int bodyTempMaxPoints: 120
    property bool videoFullscreen: false
    // PERCLOS 实时趋势采样缓冲（摄像头页 sparkline 用，~2Hz 采样）。
    property var perclosHistory: []
    readonly property int perclosMaxPoints: 120
    property bool switchingPage: false
    property string displayTime: Qt.formatDateTime(new Date(), "hh:mm")
    property string displayDate: Qt.formatDateTime(new Date(), "MM月dd日 ddd")

    readonly property string uiFamily: "Inter"
    readonly property color pageText: "#F2F2EF"
    readonly property color mutedText: "#A8A8A2"
    readonly property color softText: "#74746F"
    readonly property color glassPanel: Qt.rgba(38 / 255, 40 / 255, 42 / 255, 0.62)
    readonly property color glassStrong: Qt.rgba(44 / 255, 46 / 255, 48 / 255, 0.72)
    readonly property color glassBorder: Qt.rgba(1, 1, 1, 0.26)
    readonly property color accentBlue: "#F5A400"
    readonly property color accentCyan: "#B8B8AE"
    readonly property color accentGreen: "#D7D3C8"
    readonly property color accentOrange: "#C87521"
    readonly property color accentCold: "#7FB3D5"
    readonly property color accentDanger: "#D75450"
    readonly property color shadowTint: Qt.rgba(0, 0, 0, 0.42)

    // Material Design Icons 字体（内嵌 qrc）。图标 = 字体字形，着色=字体色、随尺寸矢量清晰，
    // 不依赖 qsvg 插件（板子 BSP 可能没有）。glyph 用十六进制码点字符串，render 处用 mdi() 转字符。
    FontLoader { id: iconFont; source: "qrc:/assets/fonts/materialdesignicons-webfont.ttf" }
    readonly property string iconFamily: iconFont.name
    function mdi(cp) { return cp ? String.fromCodePoint(parseInt(cp, 16)) : "" }
    readonly property string brandLogoSource: customUiIconRoot + "brand-logo.png"
    function customNavIconSource(fileName) { return customUiIconRoot + fileName }

    // ---- 真实疲劳状态（来自 v2 推理服务）：首页概览卡 + 摄像头页共用的派生量 ----
    // 推理服务在 App 启动即连接、常驻；首页只读指标，摄像头页才额外要画面帧。
    Component.onCompleted: fatigueService.start()
    readonly property string fatigueStatusKey: fatigueService.connected ? fatigueService.status : "disconnected"
    // PERCLOS 0..1 映射成 0..1 进度（满量程 0.30，阈值 0.15 在半程），仅作显示刻度。
    readonly property real fatigueFrac: fatigueService.connected
                                        ? Math.max(0, Math.min(1, fatigueService.perclos / 0.30)) : 0
    function fatigueText(k) {
        if (k === "fatigue_alarm") return "疲劳报警 · 建议立即休息"
        if (k === "warming_up") return "预热中 · 正在累积窗口"
        if (k === "low_visibility") return "可见度低 · 请正视摄像头"
        if (k === "camera_off") return "摄像头已关闭"
        if (k === "disconnected") return "未连接推理服务"
        return "监测正常 · 状态稳定"
    }
    function fatigueColor(k) {
        if (k === "fatigue_alarm") return root.accentDanger
        if (k === "warming_up") return root.accentBlue
        if (k === "low_visibility") return root.accentOrange
        if (k === "camera_off") return root.softText
        if (k === "disconnected") return root.softText
        return root.accentGreen
    }

    Timer {
        interval: 30000
        running: true
        repeat: true
        onTriggered: {
            root.displayTime = Qt.formatDateTime(new Date(), "hh:mm")
            root.displayDate = Qt.formatDateTime(new Date(), "MM月dd日 ddd")
        }
    }

    Timer {
        id: switchGuardTimer
        interval: 180
        repeat: false
        onTriggered: root.switchingPage = false
    }

    onCameraPageActiveChanged: {
        // 服务在 onCompleted 已常驻连接（首页概览卡也要实时指标）。这里只切换是否
        // 拉取画面帧：摄像头页才要 live 画面，首页只用指标，省掉每帧 ~900KB 拷贝。
        if (root.cameraPageActive)
            root.perclosHistory = []
        fatigueService.setWantFrames(root.cameraPageActive && fatigueService.cameraEnabled)
    }

    onVideoPageActiveChanged: {
        if (!root.videoPageActive && root.videoFullscreen) {
            root.videoFullscreen = false
        }
    }

    signal musicPageDeactivated()
    onMusicPageActiveChanged: {
        if (!root.musicPageActive)
            root.musicPageDeactivated()
    }

    // 注意：videoFullscreen 是"视频播放器内部放大"的状态，跟应用窗口 fullscreen
    // 没关系。kiosk 车机 main.cpp showFullScreen() 已经永久 fullscreen，
    // windowController 的状态不要反向同步到 videoFullscreen，否则启动时
    // 应用窗口=FullScreen 会让 videoFullscreen=true，进而让 navVisible=false，
    // 底栏消失。已删除反向同步。

    Connections {
        target: typeof sensorService !== "undefined" ? sensorService : null
        function onCabinUpdated() {
            if (!sensorService.cabinValid) return
            var arr = root.thermoHistory.slice()
            arr.push({
                t: Date.now(),
                temp: sensorService.cabinTemperature,
                humidity: sensorService.cabinHumidity
            })
            if (arr.length > root.thermoMaxPoints) arr.shift()
            root.thermoHistory = arr
        }
        function onDriverUpdated() {
            if (!sensorService.driverValid) return
            var arr = root.bodyTempHistory.slice()
            arr.push({ t: Date.now(), temp: sensorService.driverTemperature })
            if (arr.length > root.bodyTempMaxPoints) arr.shift()
            root.bodyTempHistory = arr
        }
    }

    Connections {
        target: typeof imuService !== "undefined" ? imuService : null
        function onCriticalEvent(title, detail) {
            root.imuAlertTitle = title
            root.imuAlertDetail = detail
            root.imuAlertVisible = true
            imuAlertTimer.restart()
        }
    }

    Timer {
        id: imuAlertTimer
        interval: 6500
        repeat: false
        onTriggered: root.imuAlertVisible = false
    }

    ListModel {
        id: navItems
        ListElement { glyph: "F06A1"; iconFile: "nav-home.png"; label: "首页"; hint: "座舱概览" }
        ListElement { glyph: "F11D9"; iconFile: "nav-functions.png"; label: "功能"; hint: "系统功能" }
    }

    ListModel {
        id: functionApps
        ListElement { label: "温度湿度"; glyph: "F0510"; top: "#4B3A18"; bottom: "#161719"; accent: "#F5A400" }
        ListElement { label: "人体体温"; glyph: "F0BE3"; top: "#4A2E20"; bottom: "#171819"; accent: "#C87521" }
        ListElement { label: "AI智能助手"; glyph: "F167A"; top: "#3A3B3C"; bottom: "#111214"; accent: "#D7D3C8" }
        ListElement { label: "天气"; glyph: "F0595"; top: "#33404A"; bottom: "#151719"; accent: "#B8B8AE" }
        ListElement { label: "视频播放器"; glyph: "F0FCF"; top: "#3F3022"; bottom: "#111214"; accent: "#F5A400" }
        ListElement { label: "音乐播放器"; glyph: "F0F74"; top: "#393735"; bottom: "#151515"; accent: "#D7D3C8" }
        ListElement { label: "摄像头"; glyph: "F0C7B"; top: "#2F3337"; bottom: "#111214"; accent: "#B8B8AE" }
        ListElement { label: "屏幕亮度"; glyph: "F00E0"; top: "#4B3A18"; bottom: "#161719"; accent: "#F5A400" }
        ListElement { label: "车辆姿态"; glyph: "F0D91"; top: "#49341E"; bottom: "#121416"; accent: "#F5A400" }
    }

    Rectangle {
        anchors.fill: parent
        gradient: Gradient {
            GradientStop { position: 0.0; color: "#050607" }
            GradientStop { position: 0.50; color: "#111214" }
            GradientStop { position: 1.0; color: "#1D1E20" }
        }
    }

    Rectangle {
        x: root.width * 0.08
        y: -root.height * 0.10
        width: root.width * 0.92
        height: root.height * 0.42
        radius: 34
        rotation: -15
        color: Qt.rgba(1, 1, 1, 0.16)
        border.width: 1
        border.color: Qt.rgba(1, 1, 1, 0.10)
    }

    Rectangle {
        x: -root.width * 0.10
        y: root.height * 0.58
        width: root.width * 1.08
        height: root.compact ? 96 : 130
        radius: 40
        rotation: 4
        color: Qt.rgba(245 / 255, 164 / 255, 0, 0.065)
        border.width: 1
        border.color: Qt.rgba(245 / 255, 164 / 255, 0, 0.12)
    }

    Repeater {
        model: 18

        Rectangle {
            x: 0
            y: index * root.height / 18
            width: root.width
            height: 1
            color: Qt.rgba(1, 1, 1, index % 3 === 0 ? 0.035 : 0.014)
        }
    }

    // navSlot 抢先锚定屏幕底部 —— 避免中间 slot 溢出把它挤下屏外。
    // 必须放在 ColumnLayout 之前声明，这样它的 id 在下面 ColumnLayout 里能引用。
    readonly property bool navVisible: !root.videoFullscreen
                                       && !(root.activeNavIndex === 1 && root.functionPage !== "grid")
    readonly property int navReserve: navVisible ? (root.compact ? 82 : 92) : 0

    ColumnLayout {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        anchors.leftMargin: root.pageMargin
        anchors.rightMargin: root.pageMargin
        anchors.topMargin: root.pageMargin
        anchors.bottomMargin: root.pageMargin + root.navReserve + (root.navVisible ? (root.compact ? 14 : 18) : 0)
        spacing: root.compact ? 14 : 18

        Item {
            Layout.fillWidth: true
            Layout.preferredHeight: root.activeNavIndex === 1 ? 0 : (root.compact ? 72 : 82)
            visible: root.activeNavIndex !== 1

            Rectangle {
                anchors.fill: headerPanel
                anchors.topMargin: 10
                radius: headerPanel.radius
                color: root.shadowTint
            }

            Rectangle {
                id: headerPanel
                anchors.fill: parent
                radius: root.compact ? 24 : 28
                color: root.glassPanel
                border.width: 1
                border.color: root.glassBorder

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: root.compact ? 18 : 24
                    anchors.rightMargin: root.compact ? 18 : 24
                    spacing: root.compact ? 12 : 18

                    Rectangle {
                        Layout.preferredWidth: root.compact ? 48 : 56
                        Layout.preferredHeight: root.compact ? 48 : 56
                        radius: 18
                        color: Qt.rgba(245 / 255, 164 / 255, 0, 0.16)
                        border.width: 1
                        border.color: Qt.rgba(245 / 255, 164 / 255, 0, 0.28)

                        Image {
                            id: customBrandLogo
                            anchors.fill: parent
                            anchors.margins: root.compact ? 7 : 8
                            source: root.brandLogoSource
                            fillMode: Image.PreserveAspectFit
                            asynchronous: true
                            cache: true
                            smooth: true
                            mipmap: true
                            visible: status === Image.Ready
                        }

                        Text {
                            anchors.centerIn: parent
                            text: "E2"
                            visible: customBrandLogo.status !== Image.Ready
                            color: root.accentBlue
                            font.family: root.uiFamily
                            font.pixelSize: root.compact ? 16 : 18
                            font.bold: true
                        }
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 2

                        Text {
                            Layout.fillWidth: true
                            text: "AI 智能座舱安全交互系统"
                            color: root.pageText
                            font.family: root.uiFamily
                            font.pixelSize: root.compact ? 18 : 22
                            font.bold: true
                            elide: Text.ElideRight
                        }

                    }

                    ColumnLayout {
                        Layout.preferredWidth: root.compact ? 86 : 112
                        Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
                        spacing: 0

                        Text {
                            Layout.alignment: Qt.AlignRight
                            text: root.displayTime
                            color: root.pageText
                            font.family: root.uiFamily
                            font.pixelSize: root.compact ? 22 : 28
                            font.bold: true
                        }

                        Text {
                            Layout.alignment: Qt.AlignRight
                            text: root.displayDate
                            color: root.mutedText
                            font.family: root.uiFamily
                            font.pixelSize: root.compact ? 10 : 12
                        }
                    }
                }

                Component {
                    id: cameraPageComponent

                    Item {
                        id: cameraPageRoot
                        anchors.fill: parent

                        // 全部指标取自 v2 推理服务（fatigueService），Qt 不做任何疲劳计算。
                        readonly property string statusKey: fatigueService.connected ? fatigueService.status : "disconnected"

                        function statusColor(k) {
                            if (k === "fatigue_alarm") return root.accentDanger
                            if (k === "warming_up") return root.accentBlue
                            if (k === "low_visibility") return root.accentOrange
                            if (k === "camera_off") return root.softText
                            if (k === "disconnected") return root.softText
                            return root.accentGreen
                        }
                        function statusLabel(k) {
                            if (k === "fatigue_alarm") return "疲劳报警"
                            if (k === "warming_up") return "预热中"
                            if (k === "low_visibility") return "可见度低"
                            if (k === "camera_off") return "摄像头已关闭"
                            if (k === "disconnected") return "服务未连接"
                            return "监测正常"
                        }
                        function statusGlyph(k) {
                            if (k === "fatigue_alarm") return "⚠"
                            if (k === "warming_up") return "⏳"
                            if (k === "low_visibility") return "◐"
                            if (k === "camera_off") return "⊘"
                            if (k === "disconnected") return "⊘"
                            return "✓"
                        }
                        function statusHint(k) {
                            if (k === "fatigue_alarm") return "检测到疲劳 · 建议立即休息"
                            if (k === "warming_up") return "正在累积观测窗口…"
                            if (k === "low_visibility") return "人脸丢失过多 · 请正视摄像头"
                            if (k === "camera_off") return "使用右上角开关启动疲劳监测"
                            if (k === "disconnected") return "等待推理服务 (v2 fatigue_service)"
                            return "状态稳定 · 持续监测中"
                        }
                        function perclosColor(p) {
                            if (p > 0.15) return root.accentDanger
                            if (p >= 0.10) return root.accentOrange
                            return root.accentGreen
                        }
                        function eyeColor(label) {
                            if (label === "open") return root.accentGreen
                            if (label === "squint") return root.accentOrange
                            if (label === "closed") return root.accentDanger
                            return root.softText
                        }
                        function eyeLabelCn(label) {
                            if (label === "open") return "睁"
                            if (label === "squint") return "眯"
                            if (label === "closed") return "闭"
                            return "—"
                        }

                        // 推理服务推帧 → 直接喂给 CameraView（场景图纹理，零闪烁）。
                        Connections {
                            target: fatigueService
                            function onFrameReady(image) { feedView.setImage(image) }
                            function onConnectedChanged() {
                                if (!fatigueService.connected) feedView.clear()
                            }
                            function onCameraControlChanged() {
                                fatigueService.setWantFrames(root.cameraPageActive && fatigueService.cameraEnabled)
                                if (!fatigueService.cameraEnabled
                                        && fatigueService.cameraState !== "starting") {
                                    feedView.clear()
                                    root.perclosHistory = []
                                }
                            }
                        }

                        // PERCLOS 趋势 ~2Hz 采样。
                        Timer {
                            interval: 500
                            repeat: true
                            running: root.cameraPageActive && fatigueService.connected
                                     && fatigueService.cameraEnabled
                            onTriggered: {
                                var arr = root.perclosHistory.slice()
                                arr.push(fatigueService.perclos)
                                if (arr.length > root.perclosMaxPoints) arr.shift()
                                root.perclosHistory = arr
                            }
                        }

                        Item {
                            anchors.fill: parent
                            anchors.margins: root.compact ? 16 : 22

                            RowLayout {
                                id: camTopBar
                                anchors.top: parent.top
                                anchors.left: parent.left
                                anchors.right: parent.right
                                height: root.compact ? 56 : 68
                                spacing: 14

                                Rectangle {
                                    Layout.preferredWidth: root.compact ? 44 : 50
                                    Layout.preferredHeight: root.compact ? 44 : 50
                                    radius: width / 2
                                    color: root.glassPanel
                                    border.width: 1
                                    border.color: root.glassBorder
                                    Text {
                                        anchors.centerIn: parent
                                        text: root.mdi("F0141")
                                        color: root.pageText
                                        font.family: root.iconFamily
                                        font.pixelSize: root.compact ? 26 : 30
                                    }
                                    MouseArea { anchors.fill: parent; onClicked: root.functionPage = "grid" }
                                }

                                Column {
                                    Layout.fillWidth: true
                                    spacing: 2
                                    Text {
                                        text: "摄像头疲劳检测"
                                        color: root.pageText
                                        font.family: root.uiFamily
                                        font.pixelSize: root.compact ? 20 : 24
                                        font.bold: true
                                        elide: Text.ElideRight
                                        width: parent.width
                                    }
                                    Text {
                                        text: "v2 边缘推理 · RetinaFace + EyeCNN + PERCLOS"
                                        color: root.mutedText
                                        font.family: root.uiFamily
                                        font.pixelSize: root.compact ? 12 : 13
                                        elide: Text.ElideRight
                                        width: parent.width
                                    }
                                }

                                Rectangle {
                                    Layout.preferredHeight: 28
                                    Layout.preferredWidth: connRow.width + 22
                                    radius: 14
                                    color: Qt.rgba(0, 0, 0, 0.30)
                                    border.width: 1
                                    border.color: root.glassBorder
                                    Row {
                                        id: connRow
                                        anchors.centerIn: parent
                                        spacing: 7
                                        Rectangle {
                                            width: 9; height: 9; radius: 4.5
                                            anchors.verticalCenter: parent.verticalCenter
                                            color: fatigueService.connected ? root.accentGreen : root.accentDanger
                                        }
                                        Text {
                                            text: fatigueService.connected ? "服务已连接" : "服务未连接"
                                            color: root.mutedText
                                            font.family: root.uiFamily
                                            font.pixelSize: 12
                                            anchors.verticalCenter: parent.verticalCenter
                                        }
                                    }
                                }

                                RowLayout {
                                    Layout.alignment: Qt.AlignVCenter
                                    spacing: 8

                                    Text {
                                        text: fatigueService.cameraControlBusy
                                              ? (fatigueService.cameraState === "starting"
                                                 ? "正在开启…" : "正在关闭…")
                                              : (fatigueService.cameraEnabled ? "监测已开启" : "摄像头已关闭")
                                        color: fatigueService.cameraEnabled ? root.accentBlue : root.mutedText
                                        font.family: root.uiFamily
                                        font.pixelSize: root.compact ? 11 : 13
                                    }

                                    Switch {
                                        id: cameraPageCameraSwitch
                                        Layout.preferredWidth: root.compact ? 46 : 52
                                        Layout.preferredHeight: root.compact ? 26 : 28
                                        padding: 0
                                        enabled: fatigueService.connected && !fatigueService.cameraControlBusy
                                        opacity: enabled ? 1.0 : 0.45
                                        checked: fatigueService.cameraEnabled || fatigueService.cameraState === "starting"
                                        onClicked: fatigueService.setCameraEnabled(!fatigueService.cameraEnabled)
                                        Accessible.name: "摄像头疲劳监测开关"

                                        indicator: Rectangle {
                                            anchors.fill: parent
                                            radius: height / 2
                                            color: cameraPageCameraSwitch.checked
                                                   ? Qt.rgba(245 / 255, 164 / 255, 0, 0.28)
                                                   : Qt.rgba(1, 1, 1, 0.10)
                                            border.width: 1
                                            border.color: cameraPageCameraSwitch.checked
                                                          ? root.accentBlue : root.glassBorder
                                            Behavior on color { ColorAnimation { duration: 140 } }

                                            Rectangle {
                                                x: cameraPageCameraSwitch.checked ? parent.width - width - 3 : 3
                                                anchors.verticalCenter: parent.verticalCenter
                                                width: parent.height - 6
                                                height: parent.height - 6
                                                radius: height / 2
                                                color: cameraPageCameraSwitch.checked ? root.accentBlue : root.mutedText
                                                Behavior on x {
                                                    NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
                                                }
                                                Behavior on color { ColorAnimation { duration: 140 } }
                                            }
                                        }
                                        contentItem: Item {}
                                    }
                                }
                            }

                            RowLayout {
                                id: camMainArea
                                anchors.top: camTopBar.bottom
                                anchors.bottom: parent.bottom
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.topMargin: root.compact ? 12 : 16
                                spacing: root.compact ? 12 : 16

                                // ============ 左：实时画面 ============
                                Rectangle {
                                    id: feedCard
                                    Layout.preferredWidth: camMainArea.width * 0.62
                                    Layout.fillHeight: true
                                    radius: 20
                                    color: "#000"
                                    border.width: fatigueService.cameraEnabled && fatigueService.fatigueAlarm ? 2 : 1
                                    border.color: fatigueService.cameraEnabled && fatigueService.fatigueAlarm
                                                  ? root.accentDanger : root.glassBorder
                                    clip: true

                                    CameraView {
                                        id: feedView
                                        anchors.fill: parent
                                        anchors.margins: 2
                                    }

                                    Column {
                                        anchors.centerIn: parent
                                        spacing: 10
                                        visible: !fatigueService.cameraEnabled

                                        Text {
                                            anchors.horizontalCenter: parent.horizontalCenter
                                            text: root.mdi("F0C7B")
                                            color: root.softText
                                            font.family: root.iconFamily
                                            font.pixelSize: root.compact ? 44 : 54
                                        }
                                        Text {
                                            anchors.horizontalCenter: parent.horizontalCenter
                                            text: fatigueService.cameraState === "starting"
                                                  ? "正在开启摄像头…"
                                                  : (fatigueService.cameraState === "error"
                                                     && fatigueService.cameraError.length > 0
                                                     ? fatigueService.cameraError : "摄像头已关闭")
                                            color: fatigueService.cameraState === "error"
                                                   ? root.accentDanger : root.mutedText
                                            font.family: root.uiFamily
                                            font.pixelSize: root.compact ? 14 : 16
                                        }
                                    }

                                    // 人脸框 / 双眼框：相机像素坐标 → CameraView.contentRect 映射。
                                    Item {
                                        id: overlay
                                        anchors.fill: feedView
                                        visible: fatigueService.connected && fatigueService.cameraEnabled
                                                 && fatigueService.faceFound
                                                 && fatigueService.frameWidth > 0
                                        property real sx: feedView.contentRect.width / Math.max(1, fatigueService.frameWidth)
                                        property real sy: feedView.contentRect.height / Math.max(1, fatigueService.frameHeight)

                                        Rectangle {
                                            visible: fatigueService.faceBox.width > 0
                                            x: feedView.contentRect.x + fatigueService.faceBox.x * overlay.sx
                                            y: feedView.contentRect.y + fatigueService.faceBox.y * overlay.sy
                                            width: fatigueService.faceBox.width * overlay.sx
                                            height: fatigueService.faceBox.height * overlay.sy
                                            radius: 6
                                            color: "transparent"
                                            border.width: 2
                                            border.color: Qt.rgba(0.96, 0.64, 0, 0.85)
                                        }
                                        Rectangle {
                                            visible: fatigueService.eyeLeftBox.width > 0
                                            x: feedView.contentRect.x + fatigueService.eyeLeftBox.x * overlay.sx
                                            y: feedView.contentRect.y + fatigueService.eyeLeftBox.y * overlay.sy
                                            width: fatigueService.eyeLeftBox.width * overlay.sx
                                            height: fatigueService.eyeLeftBox.height * overlay.sy
                                            radius: 3
                                            color: "transparent"
                                            border.width: 2
                                            border.color: cameraPageRoot.eyeColor(fatigueService.eyeLeft)
                                        }
                                        Rectangle {
                                            visible: fatigueService.eyeRightBox.width > 0
                                            x: feedView.contentRect.x + fatigueService.eyeRightBox.x * overlay.sx
                                            y: feedView.contentRect.y + fatigueService.eyeRightBox.y * overlay.sy
                                            width: fatigueService.eyeRightBox.width * overlay.sx
                                            height: fatigueService.eyeRightBox.height * overlay.sy
                                            radius: 3
                                            color: "transparent"
                                            border.width: 2
                                            border.color: cameraPageRoot.eyeColor(fatigueService.eyeRight)
                                        }
                                    }

                                    // 疲劳报警脉冲边框。
                                    Rectangle {
                                        anchors.fill: feedView
                                        visible: fatigueService.cameraEnabled && fatigueService.fatigueAlarm
                                        color: "transparent"
                                        radius: 18
                                        border.width: 4
                                        border.color: root.accentDanger
                                        SequentialAnimation on opacity {
                                            running: fatigueService.cameraEnabled && fatigueService.fatigueAlarm
                                            loops: Animation.Infinite
                                            NumberAnimation { to: 0.25; duration: 600; easing.type: Easing.InOutSine }
                                            NumberAnimation { to: 1.0; duration: 600; easing.type: Easing.InOutSine }
                                        }
                                    }

                                    Rectangle {
                                        id: liveBadge
                                        visible: fatigueService.connected && fatigueService.cameraEnabled
                                        anchors.top: parent.top
                                        anchors.left: parent.left
                                        anchors.margins: 12
                                        width: liveRow.width + 14
                                        height: 24
                                        radius: 12
                                        color: Qt.rgba(0, 0, 0, 0.55)
                                        border.width: 1
                                        border.color: Qt.rgba(1, 1, 1, 0.10)
                                        Row {
                                            id: liveRow
                                            anchors.centerIn: parent
                                            spacing: 6
                                            Rectangle {
                                                width: 8; height: 8; radius: 4
                                                color: root.accentDanger
                                                anchors.verticalCenter: parent.verticalCenter
                                                SequentialAnimation on opacity {
                                                    running: fatigueService.connected
                                                    loops: Animation.Infinite
                                                    NumberAnimation { to: 0.35; duration: 700; easing.type: Easing.InOutSine }
                                                    NumberAnimation { to: 1.0; duration: 700; easing.type: Easing.InOutSine }
                                                }
                                            }
                                            Text {
                                                text: "LIVE"
                                                color: "#FFFFFF"
                                                font.family: root.uiFamily
                                                font.pixelSize: 11
                                                font.bold: true
                                                anchors.verticalCenter: parent.verticalCenter
                                            }
                                        }
                                    }

                                    Rectangle {
                                        id: fpsBadge
                                        visible: fatigueService.connected
                                        anchors.top: parent.top
                                        anchors.right: parent.right
                                        anchors.margins: 12
                                        width: fpsText.width + 16
                                        height: 24
                                        radius: 12
                                        color: Qt.rgba(0, 0, 0, 0.55)
                                        border.width: 1
                                        border.color: Qt.rgba(1, 1, 1, 0.10)
                                        Text {
                                            id: fpsText
                                            anchors.centerIn: parent
                                            text: fatigueService.fps.toFixed(1) + " fps"
                                            color: root.mutedText
                                            font.family: root.uiFamily
                                            font.pixelSize: 11
                                        }
                                    }

                                    Rectangle {
                                        visible: fatigueService.connected && fatigueService.motionGated
                                        anchors.top: fpsBadge.bottom
                                        anchors.right: parent.right
                                        anchors.topMargin: 8
                                        anchors.rightMargin: 12
                                        width: motionGateText.width + 20
                                        height: 30
                                        radius: 15
                                        color: Qt.rgba(200 / 255, 117 / 255, 33 / 255, 0.88)
                                        border.width: 1
                                        border.color: root.accentOrange
                                        Text {
                                            id: motionGateText
                                            anchors.centerIn: parent
                                            text: "车身晃动 · 视觉观测暂缓 "
                                                  + Math.round(fatigueService.imuVisionConfidence * 100) + "%"
                                            color: root.pageText
                                            font.family: root.uiFamily
                                            font.pixelSize: root.compact ? 10 : 12
                                            font.bold: true
                                        }
                                    }

                                    // 未连接占位。
                                    Column {
                                        anchors.centerIn: parent
                                        visible: !fatigueService.connected
                                        spacing: 12
                                        Text {
                                            anchors.horizontalCenter: parent.horizontalCenter
                                            text: "⊘"
                                            color: root.softText
                                            font.pixelSize: 48
                                        }
                                        Text {
                                            anchors.horizontalCenter: parent.horizontalCenter
                                            text: "等待推理服务…"
                                            color: root.softText
                                            font.family: root.uiFamily
                                            font.pixelSize: 15
                                        }
                                        Text {
                                            anchors.horizontalCenter: parent.horizontalCenter
                                            text: "请先启动 v2 fatigue_service"
                                            color: root.softText
                                            font.family: root.uiFamily
                                            font.pixelSize: 12
                                        }
                                    }
                                }

                                // ============ 右：指标面板 ============
                                Rectangle {
                                    id: metricsCard
                                    Layout.fillWidth: true
                                    Layout.fillHeight: true
                                    radius: 20
                                    color: root.glassPanel
                                    border.width: 1
                                    border.color: root.glassBorder

                                    Flickable {
                                        anchors.fill: parent
                                        anchors.margins: root.compact ? 14 : 18
                                        contentWidth: width
                                        contentHeight: metricsStack.implicitHeight
                                        clip: true
                                        boundsBehavior: Flickable.StopAtBounds
                                        interactive: contentHeight > height
                                        flickableDirection: Flickable.VerticalFlick

                                        Column {
                                            id: metricsStack
                                            width: parent.width
                                            spacing: root.compact ? 10 : 14

                                            // -- 状态横幅 --
                                            Rectangle {
                                                width: parent.width
                                                height: root.compact ? 60 : 68
                                                radius: 14
                                                readonly property color sc: cameraPageRoot.statusColor(cameraPageRoot.statusKey)
                                                color: Qt.rgba(sc.r, sc.g, sc.b, 0.16)
                                                border.width: 1
                                                border.color: Qt.rgba(sc.r, sc.g, sc.b, 0.55)
                                                Row {
                                                    anchors.left: parent.left
                                                    anchors.leftMargin: 14
                                                    anchors.verticalCenter: parent.verticalCenter
                                                    spacing: 12
                                                    Text {
                                                        anchors.verticalCenter: parent.verticalCenter
                                                        text: cameraPageRoot.statusGlyph(cameraPageRoot.statusKey)
                                                        color: cameraPageRoot.statusColor(cameraPageRoot.statusKey)
                                                        font.pixelSize: root.compact ? 26 : 30
                                                    }
                                                    Column {
                                                        anchors.verticalCenter: parent.verticalCenter
                                                        spacing: 2
                                                        Text {
                                                            text: cameraPageRoot.statusLabel(cameraPageRoot.statusKey)
                                                            color: cameraPageRoot.statusColor(cameraPageRoot.statusKey)
                                                            font.family: root.uiFamily
                                                            font.pixelSize: root.compact ? 18 : 20
                                                            font.bold: true
                                                        }
                                                        Text {
                                                            text: fatigueService.fatigueAlarm && fatigueService.fatigueReason.length > 0
                                                                  ? fatigueService.fatigueReason
                                                                  : cameraPageRoot.statusHint(cameraPageRoot.statusKey)
                                                            color: root.mutedText
                                                            font.family: root.uiFamily
                                                            font.pixelSize: 11
                                                            width: metricsStack.width - 80
                                                            elide: Text.ElideRight
                                                        }
                                                    }
                                                }
                                            }

                                            // -- PERCLOS 仪表 + 趋势 --
                                            Rectangle {
                                                width: parent.width
                                                height: root.compact ? 196 : 216
                                                radius: 14
                                                color: Qt.rgba(1, 1, 1, 0.04)
                                                border.width: 1
                                                border.color: Qt.rgba(1, 1, 1, 0.08)

                                                Text {
                                                    id: perclosTitle
                                                    anchors.top: parent.top
                                                    anchors.left: parent.left
                                                    anchors.margins: 12
                                                    text: "PERCLOS · 闭眼时间占比"
                                                    color: root.mutedText
                                                    font.family: root.uiFamily
                                                    font.pixelSize: root.compact ? 12 : 13
                                                }

                                                Canvas {
                                                    id: perclosRing
                                                    anchors.top: perclosTitle.bottom
                                                    anchors.left: parent.left
                                                    anchors.leftMargin: 12
                                                    anchors.topMargin: 6
                                                    width: root.compact ? 92 : 104
                                                    height: width
                                                    antialiasing: true

                                                    property real val: fatigueService.connected ? fatigueService.perclos : 0
                                                    property color col: cameraPageRoot.perclosColor(fatigueService.perclos)
                                                    property bool ready: fatigueService.connected
                                                    onValChanged: requestPaint()
                                                    onColChanged: requestPaint()
                                                    onReadyChanged: requestPaint()

                                                    onPaint: {
                                                        var ctx = getContext("2d")
                                                        ctx.reset()
                                                        var cx = width / 2, cy = height / 2
                                                        var R = Math.min(cx, cy) - 5
                                                        // 满量程 0.30（阈值 0.15 在半圈处）。
                                                        var frac = Math.max(0, Math.min(1, val / 0.30))
                                                        ctx.lineWidth = 6
                                                        ctx.strokeStyle = Qt.rgba(1, 1, 1, 0.10)
                                                        ctx.beginPath(); ctx.arc(cx, cy, R, 0, Math.PI * 2); ctx.stroke()
                                                        if (ready) {
                                                            ctx.strokeStyle = col
                                                            ctx.lineCap = "round"
                                                            ctx.beginPath()
                                                            ctx.arc(cx, cy, R, -Math.PI / 2, -Math.PI / 2 + Math.PI * 2 * frac)
                                                            ctx.stroke()
                                                        }
                                                        // 阈值刻度 @0.15 -> frac 0.5
                                                        var ta = -Math.PI / 2 + Math.PI * 2 * 0.5
                                                        ctx.strokeStyle = root.accentDanger
                                                        ctx.lineWidth = 2
                                                        ctx.beginPath()
                                                        ctx.moveTo(cx + (R - 7) * Math.cos(ta), cy + (R - 7) * Math.sin(ta))
                                                        ctx.lineTo(cx + (R + 5) * Math.cos(ta), cy + (R + 5) * Math.sin(ta))
                                                        ctx.stroke()
                                                    }

                                                    Column {
                                                        anchors.centerIn: parent
                                                        spacing: 0
                                                        Text {
                                                            anchors.horizontalCenter: parent.horizontalCenter
                                                            text: fatigueService.connected
                                                                  ? (fatigueService.perclos * 100).toFixed(1) + "%"
                                                                  : "—"
                                                            color: cameraPageRoot.perclosColor(fatigueService.perclos)
                                                            font.family: root.uiFamily
                                                            font.pixelSize: root.compact ? 22 : 26
                                                            font.bold: true
                                                        }
                                                        Text {
                                                            anchors.horizontalCenter: parent.horizontalCenter
                                                            text: "阈值 15%"
                                                            color: root.softText
                                                            font.family: root.uiFamily
                                                            font.pixelSize: 10
                                                        }
                                                    }
                                                }

                                                // 趋势 sparkline
                                                Canvas {
                                                    id: perclosSpark
                                                    anchors.left: perclosRing.right
                                                    anchors.right: parent.right
                                                    anchors.top: perclosRing.top
                                                    anchors.bottom: perclosRing.bottom
                                                    anchors.leftMargin: 12
                                                    anchors.rightMargin: 12
                                                    antialiasing: true
                                                    property var pts: root.perclosHistory
                                                    onPtsChanged: requestPaint()
                                                    onWidthChanged: requestPaint()
                                                    onHeightChanged: requestPaint()
                                                    onPaint: {
                                                        var ctx = getContext("2d")
                                                        ctx.reset()
                                                        var w = width, h = height
                                                        var maxV = 0.30
                                                        // 阈值线
                                                        var ty = h - (0.15 / maxV) * h
                                                        ctx.strokeStyle = Qt.rgba(0.84, 0.33, 0.31, 0.55)
                                                        ctx.lineWidth = 1
                                                        ctx.beginPath(); ctx.moveTo(0, ty); ctx.lineTo(w, ty); ctx.stroke()
                                                        if (!pts || pts.length < 2) return
                                                        var n = pts.length
                                                        ctx.strokeStyle = root.accentBlue
                                                        ctx.lineWidth = 2
                                                        ctx.lineJoin = "round"
                                                        ctx.beginPath()
                                                        for (var i = 0; i < n; ++i) {
                                                            var x = (n === 1) ? 0 : (i / (n - 1)) * w
                                                            var v = Math.max(0, Math.min(maxV, pts[i]))
                                                            var y = h - (v / maxV) * h
                                                            if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y)
                                                        }
                                                        ctx.stroke()
                                                    }
                                                    Text {
                                                        anchors.top: parent.top
                                                        anchors.right: parent.right
                                                        text: "近 60s 趋势"
                                                        color: root.softText
                                                        font.family: root.uiFamily
                                                        font.pixelSize: 10
                                                    }
                                                }
                                            }

                                            // -- 双眼状态 --
                                            Row {
                                                width: parent.width
                                                spacing: root.compact ? 10 : 12
                                                Repeater {
                                                    model: [
                                                        { lab: "左眼", st: fatigueService.eyeLeft, po: fatigueService.pOpenLeft },
                                                        { lab: "右眼", st: fatigueService.eyeRight, po: fatigueService.pOpenRight }
                                                    ]
                                                    Rectangle {
                                                        width: (metricsStack.width - (root.compact ? 10 : 12)) / 2
                                                        height: root.compact ? 92 : 100
                                                        radius: 14
                                                        color: Qt.rgba(1, 1, 1, 0.04)
                                                        border.width: 1
                                                        border.color: Qt.rgba(1, 1, 1, 0.08)
                                                        Column {
                                                            anchors.centerIn: parent
                                                            spacing: 4
                                                            Text {
                                                                anchors.horizontalCenter: parent.horizontalCenter
                                                                text: modelData.lab
                                                                color: root.mutedText
                                                                font.family: root.uiFamily
                                                                font.pixelSize: 12
                                                            }
                                                            Text {
                                                                anchors.horizontalCenter: parent.horizontalCenter
                                                                text: fatigueService.connected ? cameraPageRoot.eyeLabelCn(modelData.st) : "—"
                                                                color: fatigueService.connected ? cameraPageRoot.eyeColor(modelData.st) : root.softText
                                                                font.family: root.uiFamily
                                                                font.pixelSize: root.compact ? 28 : 32
                                                                font.bold: true
                                                            }
                                                            Rectangle {
                                                                anchors.horizontalCenter: parent.horizontalCenter
                                                                width: parent.width * 0.7
                                                                height: 6
                                                                radius: 3
                                                                color: Qt.rgba(1, 1, 1, 0.08)
                                                                Rectangle {
                                                                    anchors.left: parent.left
                                                                    anchors.top: parent.top
                                                                    anchors.bottom: parent.bottom
                                                                    width: fatigueService.connected
                                                                           ? parent.width * Math.max(0, Math.min(1, modelData.po))
                                                                           : 0
                                                                    radius: 3
                                                                    color: cameraPageRoot.eyeColor(modelData.st)
                                                                    Behavior on width { NumberAnimation { duration: 150 } }
                                                                }
                                                            }
                                                            Text {
                                                                anchors.horizontalCenter: parent.horizontalCenter
                                                                text: fatigueService.connected ? "睁眼 " + Math.round(modelData.po * 100) + "%" : ""
                                                                color: root.softText
                                                                font.family: root.uiFamily
                                                                font.pixelSize: 10
                                                            }
                                                        }
                                                    }
                                                }
                                            }

                                            // -- 眨眼统计 --
                                            Row {
                                                width: parent.width
                                                spacing: root.compact ? 8 : 10
                                                Repeater {
                                                    model: [
                                                        { lab: "眨眼频率", val: fatigueService.connected ? fatigueService.blinkRate.toFixed(0) : "—", unit: "次/分" },
                                                        { lab: "平均时长", val: (fatigueService.connected && fatigueService.meanBlinkMs >= 0) ? fatigueService.meanBlinkMs.toFixed(0) : "—", unit: "ms" },
                                                        { lab: "微睡眠", val: fatigueService.connected ? fatigueService.longBlinkCount : "—", unit: "次" }
                                                    ]
                                                    Rectangle {
                                                        width: (metricsStack.width - (root.compact ? 16 : 20)) / 3
                                                        height: root.compact ? 64 : 70
                                                        radius: 12
                                                        color: Qt.rgba(1, 1, 1, 0.04)
                                                        border.width: 1
                                                        border.color: (modelData.lab === "微睡眠" && fatigueService.longBlinkCount > 0)
                                                                      ? Qt.rgba(0.84, 0.33, 0.31, 0.55)
                                                                      : Qt.rgba(1, 1, 1, 0.08)
                                                        Column {
                                                            anchors.centerIn: parent
                                                            spacing: 2
                                                            Text {
                                                                anchors.horizontalCenter: parent.horizontalCenter
                                                                text: modelData.val
                                                                color: (modelData.lab === "微睡眠" && fatigueService.longBlinkCount > 0)
                                                                       ? root.accentDanger : root.pageText
                                                                font.family: root.uiFamily
                                                                font.pixelSize: root.compact ? 20 : 23
                                                                font.bold: true
                                                            }
                                                            Text {
                                                                anchors.horizontalCenter: parent.horizontalCenter
                                                                text: modelData.lab + " (" + modelData.unit + ")"
                                                                color: root.mutedText
                                                                font.family: root.uiFamily
                                                                font.pixelSize: 10
                                                            }
                                                        }
                                                    }
                                                }
                                            }

                                            // -- 可观测性 / 窗口健康 --
                                            Item {
                                                width: parent.width
                                                height: root.compact ? 44 : 50
                                                Text {
                                                    id: obsLabel
                                                    anchors.top: parent.top
                                                    anchors.left: parent.left
                                                    text: "观测窗口"
                                                    color: root.mutedText
                                                    font.family: root.uiFamily
                                                    font.pixelSize: root.compact ? 12 : 13
                                                }
                                                Text {
                                                    anchors.top: parent.top
                                                    anchors.right: parent.right
                                                    text: fatigueService.connected
                                                          ? fatigueService.validCount + " / " + fatigueService.windowLen
                                                          : "—"
                                                    color: root.pageText
                                                    font.family: root.uiFamily
                                                    font.pixelSize: 13
                                                    font.bold: true
                                                }
                                                Rectangle {
                                                    anchors.top: obsLabel.bottom
                                                    anchors.left: parent.left
                                                    anchors.right: parent.right
                                                    anchors.topMargin: 10
                                                    height: 8
                                                    radius: 4
                                                    color: Qt.rgba(1, 1, 1, 0.08)
                                                    Rectangle {
                                                        anchors.left: parent.left
                                                        anchors.top: parent.top
                                                        anchors.bottom: parent.bottom
                                                        width: (fatigueService.connected && fatigueService.windowLen > 0)
                                                               ? parent.width * Math.min(1, fatigueService.validCount / fatigueService.windowLen)
                                                               : 0
                                                        radius: 4
                                                        color: cameraPageRoot.statusKey === "warming_up" ? root.accentBlue : root.accentGreen
                                                        Behavior on width { NumberAnimation { duration: 200 } }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                Component {
                    id: weatherPageComponent

                    Item {
                        id: weatherPageRoot
                        anchors.fill: parent

                        function windPowerInt() {
                            if (!weatherService.windPower) return 0
                            var v = parseInt(weatherService.windPower)
                            return isNaN(v) ? 0 : v
                        }

                        function drivingScore() {
                            if (!weatherService.cityName) return -1
                            var score = 100
                            var w = weatherService.weather || ""
                            if (w.indexOf("暴雨") >= 0 || w.indexOf("大暴雨") >= 0 || w.indexOf("暴雪") >= 0 || w.indexOf("大雪") >= 0) score -= 50
                            else if (w.indexOf("中雨") >= 0 || w.indexOf("中雪") >= 0 || w.indexOf("冻雨") >= 0 || w.indexOf("雨夹雪") >= 0) score -= 30
                            else if (w.indexOf("雷") >= 0) score -= 25
                            else if (w.indexOf("小雨") >= 0 || w.indexOf("小雪") >= 0 || w.indexOf("阵雨") >= 0 || w.indexOf("阵雪") >= 0) score -= 15
                            else if (w.indexOf("沙") >= 0 || w.indexOf("尘") >= 0) score -= 35
                            else if (w.indexOf("雾") >= 0 || w.indexOf("霾") >= 0) score -= 25
                            else if (w === "阴") score -= 5

                            var wp = windPowerInt()
                            if (wp >= 8) score -= 40
                            else if (wp === 7) score -= 25
                            else if (wp === 6) score -= 15
                            else if (wp === 5) score -= 8
                            else if (wp === 4) score -= 3

                            var t = weatherService.temperature
                            if (t <= -10 || t >= 40) score -= 20
                            else if (t <= -5 || t >= 38) score -= 12
                            else if (t <= 0 || t >= 35) score -= 6
                            else if (t <= 5 || t >= 32) score -= 3

                            if (weatherService.humidity >= 95) score -= 5
                            else if (weatherService.humidity > 0 && weatherService.humidity <= 15) score -= 3

                            return Math.max(0, score)
                        }

                        function scoreGrade(s) {
                            if (s < 0) return "—"
                            if (s >= 85) return "极佳"
                            if (s >= 70) return "良好"
                            if (s >= 50) return "一般"
                            if (s >= 30) return "较差"
                            return "危险"
                        }

                        function scoreColor(s) {
                            if (s < 0) return root.mutedText
                            if (s >= 85) return root.accentGreen
                            if (s >= 70) return root.accentBlue
                            if (s >= 50) return root.accentOrange
                            return root.accentDanger
                        }

                        function iconType(weather, isNight) {
                            if (!weather) return "cloudy"
                            if (isNight && (weather === "晴" || weather === "多云")) return "moon"
                            if (weather.indexOf("雷") >= 0) return "thunder"
                            if (weather.indexOf("雪") >= 0) return "snow"
                            if (weather.indexOf("雨") >= 0) return "rain"
                            if (weather.indexOf("雾") >= 0 || weather.indexOf("霾") >= 0 || weather.indexOf("沙") >= 0 || weather.indexOf("尘") >= 0) return "fog"
                            if (weather === "晴") return "sun"
                            if (weather === "多云") return "partlyCloudy"
                            if (weather === "阴") return "cloudy"
                            return "cloudy"
                        }

                        function rainCount(weather) {
                            if (weather.indexOf("大") >= 0) return 7
                            if (weather.indexOf("中") >= 0) return 5
                            return 3
                        }

                        function drawIcon(ctx, type, cx, cy, size, weatherStr) {
                            var s = size
                            var primary = root.accentBlue
                            var cloud = Qt.rgba(0.84, 0.83, 0.78, 0.80)
                            var rainColor = root.accentCold
                            var snowColor = "#F2F2EF"
                            var fogColor = Qt.rgba(0.84, 0.83, 0.78, 0.55)

                            ctx.lineCap = "round"
                            ctx.lineJoin = "round"

                            if (type === "sun") {
                                ctx.fillStyle = primary
                                ctx.beginPath()
                                ctx.arc(cx, cy, s * 0.30, 0, Math.PI * 2)
                                ctx.fill()
                                ctx.strokeStyle = primary
                                ctx.lineWidth = Math.max(2, s * 0.04)
                                for (var i = 0; i < 8; ++i) {
                                    var a = i * Math.PI / 4
                                    var r1 = s * 0.40, r2 = s * 0.50
                                    ctx.beginPath()
                                    ctx.moveTo(cx + Math.cos(a) * r1, cy + Math.sin(a) * r1)
                                    ctx.lineTo(cx + Math.cos(a) * r2, cy + Math.sin(a) * r2)
                                    ctx.stroke()
                                }
                            } else if (type === "moon") {
                                ctx.fillStyle = Qt.rgba(0.96, 0.64, 0.0, 0.85)
                                ctx.beginPath()
                                ctx.arc(cx, cy, s * 0.36, 0, Math.PI * 2)
                                ctx.fill()
                                ctx.globalCompositeOperation = "destination-out"
                                ctx.beginPath()
                                ctx.arc(cx + s * 0.16, cy - s * 0.06, s * 0.32, 0, Math.PI * 2)
                                ctx.fill()
                                ctx.globalCompositeOperation = "source-over"
                            } else if (type === "partlyCloudy") {
                                ctx.fillStyle = primary
                                ctx.beginPath()
                                ctx.arc(cx - s * 0.16, cy - s * 0.14, s * 0.22, 0, Math.PI * 2)
                                ctx.fill()
                                ctx.fillStyle = cloud
                                ctx.beginPath()
                                ctx.arc(cx, cy + s * 0.10, s * 0.22, 0, Math.PI * 2)
                                ctx.arc(cx + s * 0.18, cy + s * 0.06, s * 0.18, 0, Math.PI * 2)
                                ctx.arc(cx - s * 0.18, cy + s * 0.06, s * 0.16, 0, Math.PI * 2)
                                ctx.fill()
                            } else if (type === "cloudy") {
                                ctx.fillStyle = cloud
                                ctx.beginPath()
                                ctx.arc(cx, cy, s * 0.24, 0, Math.PI * 2)
                                ctx.arc(cx + s * 0.20, cy - s * 0.04, s * 0.18, 0, Math.PI * 2)
                                ctx.arc(cx - s * 0.20, cy - s * 0.04, s * 0.18, 0, Math.PI * 2)
                                ctx.arc(cx - s * 0.08, cy + s * 0.10, s * 0.18, 0, Math.PI * 2)
                                ctx.arc(cx + s * 0.10, cy + s * 0.10, s * 0.18, 0, Math.PI * 2)
                                ctx.fill()
                            } else if (type === "rain") {
                                ctx.fillStyle = cloud
                                ctx.beginPath()
                                ctx.arc(cx, cy - s * 0.08, s * 0.22, 0, Math.PI * 2)
                                ctx.arc(cx + s * 0.18, cy - s * 0.12, s * 0.16, 0, Math.PI * 2)
                                ctx.arc(cx - s * 0.18, cy - s * 0.12, s * 0.16, 0, Math.PI * 2)
                                ctx.fill()
                                var n = rainCount(weatherStr || "")
                                ctx.strokeStyle = rainColor
                                ctx.lineWidth = Math.max(2, s * 0.04)
                                var rainTop = cy + s * 0.10
                                for (var r = 0; r < n; ++r) {
                                    var rx = cx - s * 0.30 + (s * 0.60) * (r + 0.5) / n
                                    ctx.beginPath()
                                    ctx.moveTo(rx, rainTop)
                                    ctx.lineTo(rx - s * 0.06, rainTop + s * 0.18)
                                    ctx.stroke()
                                }
                            } else if (type === "thunder") {
                                ctx.fillStyle = cloud
                                ctx.beginPath()
                                ctx.arc(cx, cy - s * 0.12, s * 0.20, 0, Math.PI * 2)
                                ctx.arc(cx + s * 0.18, cy - s * 0.16, s * 0.16, 0, Math.PI * 2)
                                ctx.arc(cx - s * 0.18, cy - s * 0.16, s * 0.16, 0, Math.PI * 2)
                                ctx.fill()
                                ctx.strokeStyle = rainColor
                                ctx.lineWidth = Math.max(2, s * 0.04)
                                ctx.beginPath()
                                ctx.moveTo(cx - s * 0.22, cy + s * 0.08); ctx.lineTo(cx - s * 0.28, cy + s * 0.26); ctx.stroke()
                                ctx.beginPath()
                                ctx.moveTo(cx + s * 0.18, cy + s * 0.08); ctx.lineTo(cx + s * 0.12, cy + s * 0.26); ctx.stroke()
                                ctx.fillStyle = root.accentBlue
                                ctx.beginPath()
                                ctx.moveTo(cx - s * 0.04, cy + s * 0.04)
                                ctx.lineTo(cx + s * 0.10, cy + s * 0.04)
                                ctx.lineTo(cx + s * 0.02, cy + s * 0.20)
                                ctx.lineTo(cx + s * 0.14, cy + s * 0.20)
                                ctx.lineTo(cx - s * 0.04, cy + s * 0.40)
                                ctx.lineTo(cx + s * 0.06, cy + s * 0.24)
                                ctx.lineTo(cx - s * 0.06, cy + s * 0.24)
                                ctx.closePath()
                                ctx.fill()
                            } else if (type === "snow") {
                                ctx.fillStyle = cloud
                                ctx.beginPath()
                                ctx.arc(cx, cy - s * 0.08, s * 0.22, 0, Math.PI * 2)
                                ctx.arc(cx + s * 0.18, cy - s * 0.12, s * 0.16, 0, Math.PI * 2)
                                ctx.arc(cx - s * 0.18, cy - s * 0.12, s * 0.16, 0, Math.PI * 2)
                                ctx.fill()
                                ctx.strokeStyle = snowColor
                                ctx.lineWidth = Math.max(2, s * 0.03)
                                var flakeY = cy + s * 0.22
                                for (var sf = 0; sf < 5; ++sf) {
                                    var sx = cx - s * 0.30 + (s * 0.60) * (sf + 0.5) / 5
                                    var sR = s * 0.06
                                    for (var sa = 0; sa < 3; ++sa) {
                                        var sang = sa * Math.PI / 3
                                        ctx.beginPath()
                                        ctx.moveTo(sx - Math.cos(sang) * sR, flakeY - Math.sin(sang) * sR)
                                        ctx.lineTo(sx + Math.cos(sang) * sR, flakeY + Math.sin(sang) * sR)
                                        ctx.stroke()
                                    }
                                }
                            } else if (type === "fog") {
                                ctx.strokeStyle = fogColor
                                ctx.lineWidth = Math.max(3, s * 0.06)
                                var fogY = cy - s * 0.18
                                ctx.beginPath(); ctx.moveTo(cx - s * 0.40, fogY); ctx.lineTo(cx + s * 0.40, fogY); ctx.stroke()
                                ctx.beginPath(); ctx.moveTo(cx - s * 0.30, fogY + s * 0.16); ctx.lineTo(cx + s * 0.36, fogY + s * 0.16); ctx.stroke()
                                ctx.beginPath(); ctx.moveTo(cx - s * 0.40, fogY + s * 0.32); ctx.lineTo(cx + s * 0.28, fogY + s * 0.32); ctx.stroke()
                                ctx.beginPath(); ctx.moveTo(cx - s * 0.24, fogY + s * 0.48); ctx.lineTo(cx + s * 0.36, fogY + s * 0.48); ctx.stroke()
                            }
                        }

                        function moodTopColor(type) {
                            if (type === "sun") return Qt.rgba(0.96, 0.64, 0.0, 0.20)
                            if (type === "partlyCloudy") return Qt.rgba(0.84, 0.74, 0.32, 0.16)
                            if (type === "cloudy") return Qt.rgba(0.72, 0.72, 0.68, 0.15)
                            if (type === "rain") return Qt.rgba(0.50, 0.70, 0.83, 0.20)
                            if (type === "thunder") return Qt.rgba(0.84, 0.33, 0.31, 0.15)
                            if (type === "snow") return Qt.rgba(0.84, 0.83, 0.78, 0.20)
                            if (type === "fog") return Qt.rgba(0.45, 0.45, 0.43, 0.20)
                            if (type === "moon") return Qt.rgba(0.96, 0.64, 0.0, 0.12)
                            return Qt.rgba(0.84, 0.83, 0.78, 0.10)
                        }

                        function apparentInt() {
                            var T = weatherService.temperature
                            var RH = weatherService.humidity
                            if (!RH) return T
                            return Math.round(T - (0.55 - 0.0055 * RH) * (T - 14.5))
                        }

                        function visibilityLevel() {
                            var w = weatherService.weather || ""
                            if (w.indexOf("浓雾") >= 0 || w.indexOf("沙尘暴") >= 0) return "差"
                            if (w.indexOf("雾") >= 0 || w.indexOf("霾") >= 0 || w.indexOf("沙") >= 0) return "一般"
                            if (w.indexOf("大雨") >= 0 || w.indexOf("暴雨") >= 0 || w.indexOf("大雪") >= 0) return "一般"
                            if (w.indexOf("雨") >= 0 || w.indexOf("雪") >= 0) return "良"
                            return "优"
                        }

                        function uvLevel() {
                            var w = weatherService.weather || ""
                            if (w.indexOf("雨") >= 0 || w.indexOf("雪") >= 0 || w.indexOf("雾") >= 0 || w === "阴") return "低"
                            if (w === "多云") return "中"
                            if (w === "晴") return "强"
                            return "中"
                        }

                        function drivingAdvice(score, weatherStr) {
                            if (score < 0) return "正在加载天气数据…"
                            var w = weatherStr || ""
                            if (score < 30) return "强烈建议推迟出行"
                            if (w.indexOf("暴雨") >= 0 || w.indexOf("大暴雨") >= 0) return "强降水，建议避开积水路段"
                            if (w.indexOf("暴雪") >= 0 || w.indexOf("大雪") >= 0) return "强降雪，建议改用其他出行方式"
                            if (w.indexOf("雷") >= 0) return "雷雨天气，避免高速行驶"
                            if (w.indexOf("中雨") >= 0 || w.indexOf("中雪") >= 0) return "路面湿滑，减速慢行，开启大灯"
                            if (w.indexOf("雨") >= 0 || w.indexOf("雪") >= 0) return "小降水，注意路面湿滑"
                            if (w.indexOf("雾") >= 0 || w.indexOf("霾") >= 0) return "能见度受限，开启雾灯保持车距"
                            if (windPowerInt() >= 6) return "强风预警，避免高速行驶"
                            if (windPowerInt() >= 4) return "适合驾驶，注意侧风"
                            if (weatherService.temperature >= 35) return "高温炎热，注意车内通风降温"
                            if (weatherService.temperature <= 0) return "低温路面易结冰，谨慎慢行"
                            if (score >= 85) return "路况理想，安心驾驶"
                            return "适合驾驶，保持安全车距"
                        }

                        Item {
                            anchors.fill: parent
                            anchors.margins: root.compact ? 16 : 22

                            readonly property int score: weatherPageRoot.drivingScore()
                            readonly property color sColor: weatherPageRoot.scoreColor(score)
                            readonly property string ic: weatherPageRoot.iconType(weatherService.weather, false)

                            RowLayout {
                                id: wTopBar
                                anchors.top: parent.top
                                anchors.left: parent.left
                                anchors.right: parent.right
                                height: root.compact ? 52 : 60
                                spacing: 14

                                Rectangle {
                                    Layout.preferredWidth: root.compact ? 44 : 50
                                    Layout.preferredHeight: root.compact ? 44 : 50
                                    radius: width / 2
                                    color: root.glassPanel
                                    border.width: 1
                                    border.color: root.glassBorder
                                    Text {
                                        anchors.centerIn: parent
                                        text: root.mdi("F0141")
                                        color: root.pageText
                                        font.family: root.iconFamily
                                        font.pixelSize: root.compact ? 26 : 30
                                    }
                                    MouseArea { anchors.fill: parent; onClicked: root.functionPage = "grid" }
                                }

                                Text {
                                    Layout.fillWidth: true
                                    text: {
                                        var name = weatherService.cityName || "等待数据"
                                        var prov = weatherService.province && weatherService.province !== weatherService.cityName
                                                   ? "  ·  " + weatherService.province : ""
                                        return name + prov
                                    }
                                    color: root.pageText
                                    font.family: root.uiFamily
                                    font.pixelSize: root.compact ? 20 : 24
                                    font.bold: true
                                    elide: Text.ElideRight
                                }

                                Text {
                                    visible: !!weatherService.reportTime
                                    text: weatherService.reportTime
                                          ? "更新 " + weatherService.reportTime.substring(11, 16)
                                          : ""
                                    color: root.mutedText
                                    font.family: root.uiFamily
                                    font.pixelSize: root.compact ? 12 : 13
                                }

                                Rectangle {
                                    visible: weatherService.loading
                                    Layout.preferredWidth: 10
                                    Layout.preferredHeight: 10
                                    radius: 5
                                    color: root.accentBlue
                                    SequentialAnimation on opacity {
                                        running: weatherService.loading
                                        loops: Animation.Infinite
                                        NumberAnimation { to: 0.3; duration: 600; easing.type: Easing.InOutSine }
                                        NumberAnimation { to: 1.0; duration: 600; easing.type: Easing.InOutSine }
                                    }
                                }

                                Rectangle {
                                    Layout.preferredWidth: root.compact ? 80 : 92
                                    Layout.preferredHeight: root.compact ? 36 : 42
                                    radius: 14
                                    color: weatherService.loading ? Qt.rgba(38/255, 40/255, 42/255, 0.40) : root.glassPanel
                                    border.width: 1
                                    border.color: root.glassBorder
                                    Text {
                                        anchors.centerIn: parent
                                        text: "刷新"
                                        color: weatherService.loading ? root.mutedText : root.pageText
                                        font.family: root.uiFamily
                                        font.pixelSize: root.compact ? 13 : 14
                                    }
                                    MouseArea {
                                        anchors.fill: parent
                                        enabled: !weatherService.loading
                                        onClicked: weatherService.refresh()
                                    }
                                }
                            }

                            RowLayout {
                                id: wBottomCards
                                anchors.bottom: parent.bottom
                                anchors.left: parent.left
                                anchors.right: parent.right
                                height: root.compact ? 180 : 200
                                spacing: root.compact ? 10 : 14

                                Repeater {
                                    model: weatherService.forecast && weatherService.forecast.length > 0
                                           ? weatherService.forecast
                                           : 4
                                    delegate: Rectangle {
                                        Layout.fillWidth: true
                                        Layout.fillHeight: true
                                        radius: 18
                                        color: root.glassPanel
                                        border.width: 1
                                        border.color: root.glassBorder

                                        readonly property bool hasData: typeof modelData === "object" && modelData
                                        readonly property string dayW: hasData ? (modelData.dayWeather || "—") : "—"
                                        readonly property string nightW: hasData ? (modelData.nightWeather || "—") : "—"
                                        readonly property string dayT: hasData && modelData.dayTemp !== undefined ? String(modelData.dayTemp) : "—"
                                        readonly property string nightT: hasData && modelData.nightTemp !== undefined ? String(modelData.nightTemp) : "—"
                                        readonly property string weekStr: {
                                            if (!hasData || !modelData.week) return "—"
                                            var map = { "1":"周一","2":"周二","3":"周三","4":"周四","5":"周五","6":"周六","7":"周日" }
                                            return map[modelData.week] || ("周" + modelData.week)
                                        }
                                        readonly property string dateStr: hasData ? (modelData.date || "") : ""

                                        Item {
                                            anchors.fill: parent
                                            anchors.margins: root.compact ? 12 : 14

                                            Column {
                                                id: dateHeader
                                                anchors.top: parent.top
                                                anchors.horizontalCenter: parent.horizontalCenter
                                                spacing: 1
                                                Text {
                                                    text: parent.parent.parent.weekStr
                                                    color: root.accentBlue
                                                    font.family: root.uiFamily
                                                    font.pixelSize: root.compact ? 13 : 14
                                                    font.bold: true
                                                    anchors.horizontalCenter: parent.horizontalCenter
                                                }
                                                Text {
                                                    text: parent.parent.parent.dateStr
                                                          ? parent.parent.parent.dateStr.substring(5)
                                                          : ""
                                                    color: root.mutedText
                                                    font.family: root.uiFamily
                                                    font.pixelSize: 11
                                                    anchors.horizontalCenter: parent.horizontalCenter
                                                }
                                            }

                                            Rectangle {
                                                id: dateSep
                                                anchors.top: dateHeader.bottom
                                                anchors.left: parent.left
                                                anchors.right: parent.right
                                                anchors.topMargin: 6
                                                height: 1
                                                color: Qt.rgba(1, 1, 1, 0.10)
                                            }

                                            Row {
                                                id: dayRow
                                                anchors.top: dateSep.bottom
                                                anchors.left: parent.left
                                                anchors.right: parent.right
                                                anchors.topMargin: 8
                                                spacing: 10
                                                Canvas {
                                                    width: root.compact ? 40 : 48
                                                    height: width
                                                    antialiasing: true
                                                    property string wkey: parent.parent.parent.dayW
                                                    onWkeyChanged: requestPaint()
                                                    onPaint: {
                                                        var ctx = getContext("2d")
                                                        ctx.reset()
                                                        weatherPageRoot.drawIcon(
                                                            ctx,
                                                            weatherPageRoot.iconType(wkey, false),
                                                            width / 2, height / 2, width, wkey)
                                                    }
                                                    anchors.verticalCenter: parent.verticalCenter
                                                }
                                                Column {
                                                    anchors.verticalCenter: parent.verticalCenter
                                                    spacing: 2
                                                    Text {
                                                        text: parent.parent.parent.parent.dayT + "°"
                                                        color: root.pageText
                                                        font.family: root.uiFamily
                                                        font.pixelSize: root.compact ? 24 : 28
                                                        font.bold: true
                                                    }
                                                    Text {
                                                        text: parent.parent.parent.parent.dayW
                                                        color: root.mutedText
                                                        font.family: root.uiFamily
                                                        font.pixelSize: 12
                                                        elide: Text.ElideRight
                                                        width: dayRow.width - 60
                                                    }
                                                }
                                            }

                                            Rectangle {
                                                id: midSep
                                                anchors.top: dayRow.bottom
                                                anchors.left: parent.left
                                                anchors.right: parent.right
                                                anchors.topMargin: 8
                                                height: 1
                                                color: Qt.rgba(1, 1, 1, 0.08)
                                            }

                                            Row {
                                                anchors.top: midSep.bottom
                                                anchors.left: parent.left
                                                anchors.right: parent.right
                                                anchors.topMargin: 8
                                                spacing: 10
                                                Canvas {
                                                    width: root.compact ? 30 : 36
                                                    height: width
                                                    antialiasing: true
                                                    property string wkey: parent.parent.parent.nightW
                                                    onWkeyChanged: requestPaint()
                                                    onPaint: {
                                                        var ctx = getContext("2d")
                                                        ctx.reset()
                                                        weatherPageRoot.drawIcon(
                                                            ctx,
                                                            weatherPageRoot.iconType(wkey, true),
                                                            width / 2, height / 2, width, wkey)
                                                    }
                                                    anchors.verticalCenter: parent.verticalCenter
                                                }
                                                Column {
                                                    anchors.verticalCenter: parent.verticalCenter
                                                    spacing: 1
                                                    Text {
                                                        text: parent.parent.parent.parent.nightT + "°"
                                                        color: root.softText
                                                        font.family: root.uiFamily
                                                        font.pixelSize: root.compact ? 20 : 22
                                                        font.bold: true
                                                    }
                                                    Text {
                                                        text: parent.parent.parent.parent.nightW
                                                        color: root.softText
                                                        font.family: root.uiFamily
                                                        font.pixelSize: 11
                                                        elide: Text.ElideRight
                                                        width: parent.parent.width - 50
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }

                            RowLayout {
                                id: wMainArea
                                anchors.top: wTopBar.bottom
                                anchors.bottom: wBottomCards.top
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.topMargin: root.compact ? 14 : 18
                                anchors.bottomMargin: root.compact ? 14 : 18
                                spacing: root.compact ? 12 : 16

                                Rectangle {
                                    id: wCoreCard
                                    Layout.preferredWidth: wMainArea.width * 0.44
                                    Layout.fillHeight: true
                                    radius: 20
                                    color: root.glassPanel
                                    border.width: 1
                                    border.color: root.glassBorder

                                    readonly property color cardScoreColor: wCoreCard.parent.parent.sColor
                                    readonly property int cardScore: wCoreCard.parent.parent.score

                                    Flickable {
                                        anchors.fill: parent
                                        anchors.margins: root.compact ? 16 : 20
                                        contentWidth: width
                                        contentHeight: coreStack.implicitHeight
                                        clip: true
                                        boundsBehavior: Flickable.StopAtBounds
                                        interactive: contentHeight > height
                                        flickableDirection: Flickable.VerticalFlick

                                        Column {
                                            id: coreStack
                                            width: parent.width
                                            spacing: root.compact ? 8 : 10

                                        Item {
                                            id: scoreBlock
                                            width: parent.width
                                            height: root.compact ? 124 : 148

                                            Text {
                                                id: scoreLabel2
                                                anchors.top: parent.top
                                                anchors.horizontalCenter: parent.horizontalCenter
                                                text: "驾驶适宜度"
                                                color: root.mutedText
                                                font.family: root.uiFamily
                                                font.pixelSize: root.compact ? 13 : 14
                                            }

                                            Canvas {
                                                id: drivingRing
                                                anchors.top: scoreLabel2.bottom
                                                anchors.horizontalCenter: parent.horizontalCenter
                                                anchors.topMargin: 8
                                                width: root.compact ? 88 : 100
                                                height: width
                                                antialiasing: true

                                                property real ringScore: wCoreCard.cardScore
                                                property color ringColor: wCoreCard.cardScoreColor
                                                onRingScoreChanged: requestPaint()
                                                onRingColorChanged: requestPaint()

                                                onPaint: {
                                                    var ctx = getContext("2d")
                                                    ctx.reset()
                                                    var cx = width / 2, cy = height / 2
                                                    var R = Math.min(cx, cy) - 4
                                                    ctx.lineWidth = 5
                                                    ctx.strokeStyle = Qt.rgba(1, 1, 1, 0.10)
                                                    ctx.beginPath()
                                                    ctx.arc(cx, cy, R, 0, Math.PI * 2)
                                                    ctx.stroke()
                                                    if (ringScore < 0) return
                                                    ctx.strokeStyle = ringColor
                                                    if (ringScore >= 100) {
                                                        ctx.beginPath()
                                                        ctx.arc(cx, cy, R, 0, Math.PI * 2)
                                                        ctx.stroke()
                                                    } else {
                                                        ctx.lineCap = "round"
                                                        ctx.beginPath()
                                                        ctx.arc(cx, cy, R, -Math.PI / 2, -Math.PI / 2 + Math.PI * 2 * ringScore / 100)
                                                        ctx.stroke()
                                                    }
                                                }

                                                Text {
                                                    anchors.centerIn: parent
                                                    text: drivingRing.ringScore >= 0 ? drivingRing.ringScore : "—"
                                                    color: drivingRing.ringColor
                                                    font.family: root.uiFamily
                                                    font.pixelSize: {
                                                        if (drivingRing.ringScore >= 100) return root.compact ? 28 : 34
                                                        if (drivingRing.ringScore >= 10) return root.compact ? 32 : 40
                                                        return root.compact ? 34 : 44
                                                    }
                                                    font.bold: true
                                                }
                                            }

                                            Text {
                                                anchors.bottom: parent.bottom
                                                anchors.horizontalCenter: parent.horizontalCenter
                                                text: weatherPageRoot.scoreGrade(wCoreCard.cardScore)
                                                color: wCoreCard.cardScoreColor
                                                font.family: root.uiFamily
                                                font.pixelSize: root.compact ? 16 : 18
                                                font.bold: true
                                            }
                                        }

                                        Rectangle {
                                            id: wSep1
                                            width: parent.width
                                            height: 1
                                            color: Qt.rgba(1, 1, 1, 0.08)
                                        }

                                        Item {
                                            id: tempBlock
                                            width: parent.width
                                            height: root.compact ? 72 : 84

                                            Row {
                                                anchors.left: parent.left
                                                anchors.verticalCenter: parent.verticalCenter
                                                spacing: 4
                                                Text {
                                                    text: weatherService.cityName ? weatherService.temperature : "—"
                                                    color: root.accentBlue
                                                    font.family: root.uiFamily
                                                    font.pixelSize: root.compact ? 56 : 72
                                                    font.bold: true
                                                    anchors.verticalCenter: parent.verticalCenter
                                                }
                                                Text {
                                                    text: "°C"
                                                    color: root.mutedText
                                                    font.family: root.uiFamily
                                                    font.pixelSize: root.compact ? 22 : 26
                                                    anchors.verticalCenter: parent.verticalCenter
                                                    anchors.verticalCenterOffset: root.compact ? 8 : 12
                                                }
                                            }

                                            Row {
                                                anchors.right: parent.right
                                                anchors.verticalCenter: parent.verticalCenter
                                                spacing: 8
                                                Rectangle {
                                                    width: 8
                                                    height: 8
                                                    radius: 4
                                                    color: wCoreCard.cardScoreColor
                                                    anchors.verticalCenter: parent.verticalCenter
                                                }
                                                Text {
                                                    text: weatherService.cityName
                                                          ? (weatherService.weather || "—") + "  ·  体感 " + weatherPageRoot.apparentInt() + "°"
                                                          : ""
                                                    color: root.mutedText
                                                    font.family: root.uiFamily
                                                    font.pixelSize: root.compact ? 14 : 16
                                                    anchors.verticalCenter: parent.verticalCenter
                                                }
                                            }
                                        }

                                        Rectangle {
                                            id: wSep2
                                            width: parent.width
                                            height: 1
                                            color: Qt.rgba(1, 1, 1, 0.08)
                                        }

                                        Row {
                                            id: chipsRow
                                            width: parent.width
                                            height: root.compact ? 60 : 70
                                            spacing: 0

                                            Repeater {
                                                model: [
                                                    { label: "风力", primary: weatherService.windPower ? weatherService.windPower + " 级" : "—",
                                                      sub: weatherService.windDirection ? weatherService.windDirection + "风" : "" },
                                                    { label: "湿度", primary: weatherService.humidity > 0 ? weatherService.humidity + "%" : "—",
                                                      sub: "" },
                                                    { label: "能见", primary: weatherService.cityName ? weatherPageRoot.visibilityLevel() : "—",
                                                      sub: "" },
                                                    { label: "紫外", primary: weatherService.cityName ? weatherPageRoot.uvLevel() : "—",
                                                      sub: "" }
                                                ]
                                                delegate: Item {
                                                    width: chipsRow.width / 4
                                                    height: chipsRow.height

                                                    Rectangle {
                                                        visible: index > 0
                                                        anchors.left: parent.left
                                                        anchors.verticalCenter: parent.verticalCenter
                                                        width: 1
                                                        height: parent.height * 0.6
                                                        color: Qt.rgba(1, 1, 1, 0.10)
                                                    }

                                                    Column {
                                                        anchors.centerIn: parent
                                                        spacing: 2

                                                        Text {
                                                            text: modelData.label
                                                            color: root.mutedText
                                                            font.family: root.uiFamily
                                                            font.pixelSize: root.compact ? 12 : 13
                                                            anchors.horizontalCenter: parent.horizontalCenter
                                                        }
                                                        Text {
                                                            text: modelData.primary
                                                            color: root.pageText
                                                            font.family: root.uiFamily
                                                            font.pixelSize: root.compact ? 18 : 22
                                                            font.bold: true
                                                            anchors.horizontalCenter: parent.horizontalCenter
                                                        }
                                                        Text {
                                                            visible: !!modelData.sub
                                                            text: modelData.sub
                                                            color: root.softText
                                                            font.family: root.uiFamily
                                                            font.pixelSize: 11
                                                            anchors.horizontalCenter: parent.horizontalCenter
                                                        }
                                                    }
                                                }
                                            }
                                        }

                                        Rectangle {
                                            width: parent.width
                                            height: 1
                                            color: Qt.rgba(1, 1, 1, 0.08)
                                        }

                                        Item {
                                            id: adviceWrap
                                            width: parent.width
                                            height: root.compact ? 56 : 64

                                            Rectangle {
                                                id: adviceBar2
                                                anchors.left: parent.left
                                                anchors.verticalCenter: parent.verticalCenter
                                                width: 4
                                                height: parent.height * 0.7
                                                radius: 2
                                                color: wCoreCard.cardScoreColor
                                            }
                                            Column {
                                                anchors.left: adviceBar2.right
                                                anchors.right: parent.right
                                                anchors.verticalCenter: parent.verticalCenter
                                                anchors.leftMargin: 10
                                                spacing: 3

                                                Text {
                                                    text: "驾驶建议"
                                                    color: root.mutedText
                                                    font.family: root.uiFamily
                                                    font.pixelSize: 12
                                                }
                                                Text {
                                                    width: parent.width
                                                    text: weatherPageRoot.drivingAdvice(wCoreCard.cardScore, weatherService.weather)
                                                    color: root.pageText
                                                    font.family: root.uiFamily
                                                    font.pixelSize: root.compact ? 13 : 15
                                                    wrapMode: Text.WordWrap
                                                    elide: Text.ElideRight
                                                }
                                            }
                                        }
                                        }
                                    }
                                }

                                Rectangle {
                                    id: wMapCard
                                    Layout.fillWidth: true
                                    Layout.fillHeight: true
                                    radius: 20
                                    color: root.glassPanel
                                    border.width: 1
                                    border.color: root.glassBorder
                                    clip: true

                                    Canvas {
                                        id: moodLayer
                                        anchors.top: parent.top
                                        anchors.left: parent.left
                                        anchors.right: parent.right
                                        height: root.compact ? 100 : 130
                                        antialiasing: true

                                        property string wType: wCoreCard.parent.parent.ic
                                        onWTypeChanged: requestPaint()

                                        onPaint: {
                                            var ctx = getContext("2d")
                                            ctx.reset()
                                            var grad = ctx.createLinearGradient(0, 0, 0, height)
                                            grad.addColorStop(0, weatherPageRoot.moodTopColor(wType))
                                            grad.addColorStop(1, Qt.rgba(0, 0, 0, 0))
                                            ctx.fillStyle = grad
                                            ctx.fillRect(0, 0, width, height)
                                        }
                                    }

                                    Canvas {
                                        id: bigIcon
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        anchors.top: parent.top
                                        anchors.topMargin: root.compact ? 24 : 32
                                        width: root.compact ? 110 : 140
                                        height: width
                                        antialiasing: true

                                        property string wType: wCoreCard.parent.parent.ic
                                        property string wStr: weatherService.weather || ""
                                        onWTypeChanged: requestPaint()
                                        onWStrChanged: requestPaint()

                                        onPaint: {
                                            var ctx = getContext("2d")
                                            ctx.reset()
                                            if (!weatherService.cityName) return
                                            weatherPageRoot.drawIcon(ctx, wType, width / 2, height / 2, width, wStr)
                                        }
                                    }

                                    Column {
                                        anchors.top: bigIcon.bottom
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        anchors.topMargin: root.compact ? 12 : 18
                                        spacing: 6

                                        Text {
                                            text: weatherService.weather || "—"
                                            color: root.pageText
                                            font.family: root.uiFamily
                                            font.pixelSize: root.compact ? 26 : 32
                                            font.bold: true
                                            anchors.horizontalCenter: parent.horizontalCenter
                                        }

                                        Text {
                                            visible: weatherService.forecast && weatherService.forecast.length > 0
                                            text: {
                                                var f = weatherService.forecast
                                                if (!f || f.length === 0) return ""
                                                return "今日 " + f[0].nightTemp + "° / " + f[0].dayTemp + "°"
                                            }
                                            color: root.mutedText
                                            font.family: root.uiFamily
                                            font.pixelSize: root.compact ? 12 : 13
                                            anchors.horizontalCenter: parent.horizontalCenter
                                        }
                                    }

                                    Column {
                                        anchors.bottom: parent.bottom
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        anchors.bottomMargin: root.compact ? 16 : 22
                                        spacing: 4

                                        Text {
                                            text: weatherService.province
                                                  ? (weatherService.province + (weatherService.cityName && weatherService.cityName !== weatherService.province ? " · " + weatherService.cityName : ""))
                                                  : (weatherService.cityName || "")
                                            color: root.pageText
                                            font.family: root.uiFamily
                                            font.pixelSize: root.compact ? 13 : 14
                                            font.bold: true
                                            anchors.horizontalCenter: parent.horizontalCenter
                                        }
                                        Text {
                                            text: weatherService.reportTime
                                                  ? weatherService.reportTime + " 更新"
                                                  : (weatherService.hasError ? weatherService.errorText
                                                                             : "正在加载天气数据…")
                                            color: root.softText
                                            font.family: root.uiFamily
                                            font.pixelSize: 11
                                            anchors.horizontalCenter: parent.horizontalCenter
                                        }
                                    }

                                    Text {
                                        visible: !weatherService.cityName
                                        anchors.centerIn: parent
                                        text: weatherService.hasError ? weatherService.errorText : "正在加载…"
                                        color: root.softText
                                        font.family: root.uiFamily
                                        font.pixelSize: 13
                                    }
                                }
                            }
                        }
                    }
                }

                Component {
                    id: videoPageComponent

                    Item {
                        id: videoPageRoot
                        anchors.fill: parent

                        property bool controlsVisible: true
                        property bool wasMuted: false
                        property string currentTitle: ""
                        property bool pendingPlay: false

                        function formatTime(ms) {
                            if (!ms || ms < 0) return "00:00"
                            var totalSec = Math.floor(ms / 1000)
                            var h = Math.floor(totalSec / 3600)
                            var m = Math.floor((totalSec % 3600) / 60)
                            var s = totalSec % 60
                            function pad(n) { return (n < 10 ? "0" : "") + n }
                            return h > 0
                                ? (h + ":" + pad(m) + ":" + pad(s))
                                : (pad(m) + ":" + pad(s))
                        }

                        function humanSize(bytes) {
                            if (!bytes || bytes <= 0) return "—"
                            var kb = bytes / 1024
                            if (kb < 1024) return kb.toFixed(1) + " KB"
                            var mb = kb / 1024
                            if (mb < 1024) return mb.toFixed(1) + " MB"
                            return (mb / 1024).toFixed(2) + " GB"
                        }

                        Timer {
                            id: hideTimer
                            interval: 3000
                            repeat: false
                            onTriggered: videoPageRoot.controlsVisible = false
                        }

                        MediaPlayer {
                            id: player
                            autoPlay: false
                            notifyInterval: 200
                            onSourceChanged: console.log("[player] sourceChanged:", source)
                            onPlaybackStateChanged: {
                                console.log("[player] playbackState:", playbackState,
                                            "status:", status,
                                            "duration:", duration,
                                            "seekable:", seekable,
                                            "hasVideo:", hasVideo,
                                            "hasAudio:", hasAudio)
                                if (playbackState === MediaPlayer.PlayingState) {
                                    hideTimer.restart()
                                } else {
                                    hideTimer.stop()
                                    videoPageRoot.controlsVisible = true
                                }
                            }
                            onStatusChanged: {
                                console.log("[player] status:", status,
                                            "error:", error,
                                            "seekable:", seekable,
                                            "hasVideo:", hasVideo,
                                            "vo.w:", videoOutput.width,
                                            "vo.h:", videoOutput.height)
                                if (videoPageRoot.pendingPlay
                                    && (status === MediaPlayer.LoadedMedia
                                        || status === MediaPlayer.BufferedMedia)) {
                                    videoPageRoot.pendingPlay = false
                                    player.play()
                                }
                            }
                            onSeekableChanged: console.log("[player] seekable:", seekable)
                            onError: {
                                console.warn("[player] ERROR", error, errorString)
                                hideTimer.stop()
                                videoPageRoot.controlsVisible = true
                            }
                        }

                        Rectangle {
                            anchors.fill: playerPanel
                            anchors.topMargin: 14
                            radius: playerPanel.radius
                            color: root.shadowTint
                            visible: !root.videoFullscreen
                        }

                        Rectangle {
                            id: playerPanel
                            anchors.fill: parent
                            radius: root.videoFullscreen ? 0 : (root.compact ? 30 : 34)
                            color: root.videoFullscreen ? "#000000" : root.glassPanel
                            border.width: root.videoFullscreen ? 0 : 1
                            border.color: root.glassBorder
                            clip: true

                            ColumnLayout {
                                anchors.fill: parent
                                anchors.margins: root.videoFullscreen ? 0 : (root.compact ? 20 : 26)
                                spacing: root.compact ? 14 : 18

                                RowLayout {
                                    Layout.fillWidth: true
                                    Layout.preferredHeight: root.compact ? 52 : 60
                                    spacing: 12
                                    visible: !root.videoFullscreen

                                    Button {
                                        id: videoBackButton
                                        Layout.preferredWidth: root.compact ? 96 : 112
                                        Layout.preferredHeight: root.compact ? 44 : 48
                                        hoverEnabled: true
                                        focusPolicy: Qt.StrongFocus
                                        Accessible.name: "返回功能应用"
                                        onClicked: {
                                            player.stop()
                                            root.functionPage = "grid"
                                        }
                                        background: Rectangle {
                                            radius: 18
                                            color: videoBackButton.down
                                                   ? Qt.rgba(245 / 255, 164 / 255, 0, 0.18)
                                                   : videoBackButton.hovered || videoBackButton.activeFocus
                                                     ? Qt.rgba(1, 1, 1, 0.10)
                                                     : Qt.rgba(38 / 255, 40 / 255, 42 / 255, 0.54)
                                            border.width: 1
                                            border.color: videoBackButton.activeFocus
                                                          ? Qt.rgba(245 / 255, 164 / 255, 0, 0.56)
                                                          : Qt.rgba(1, 1, 1, 0.22)
                                        }
                                        contentItem: Text {
                                            text: "返回"
                                            color: root.pageText
                                            font.family: root.uiFamily
                                            font.pixelSize: root.compact ? 14 : 15
                                            font.bold: true
                                            horizontalAlignment: Text.AlignHCenter
                                            verticalAlignment: Text.AlignVCenter
                                        }
                                    }

                                    ColumnLayout {
                                        Layout.fillWidth: true
                                        spacing: 2

                                        Text {
                                            Layout.fillWidth: true
                                            text: "视频播放器"
                                            color: root.pageText
                                            font.family: root.uiFamily
                                            font.pixelSize: root.compact ? 22 : 28
                                            font.bold: true
                                            elide: Text.ElideRight
                                        }

                                        Text {
                                            Layout.fillWidth: true
                                            text: videoPageRoot.currentTitle || "选择左侧列表中的视频开始播放"
                                            color: root.mutedText
                                            font.family: root.uiFamily
                                            font.pixelSize: root.compact ? 11 : 13
                                            elide: Text.ElideRight
                                        }
                                    }

                                    Button {
                                        id: videoRefreshButton
                                        Layout.preferredWidth: root.compact ? 92 : 108
                                        Layout.preferredHeight: root.compact ? 40 : 44
                                        hoverEnabled: true
                                        focusPolicy: Qt.StrongFocus
                                        Accessible.name: "刷新视频列表"
                                        onClicked: videoLibrary.refresh()
                                        background: Rectangle {
                                            radius: 18
                                            color: videoRefreshButton.down
                                                   ? Qt.rgba(245 / 255, 164 / 255, 0, 0.22)
                                                   : videoRefreshButton.hovered || videoRefreshButton.activeFocus
                                                     ? Qt.rgba(245 / 255, 164 / 255, 0, 0.16)
                                                     : Qt.rgba(38 / 255, 40 / 255, 42 / 255, 0.56)
                                            border.width: 1
                                            border.color: videoRefreshButton.activeFocus
                                                          ? Qt.rgba(245 / 255, 164 / 255, 0, 0.52)
                                                          : Qt.rgba(1, 1, 1, 0.22)
                                        }
                                        contentItem: Text {
                                            text: "刷新"
                                            color: root.pageText
                                            font.family: root.uiFamily
                                            font.pixelSize: root.compact ? 13 : 14
                                            font.bold: true
                                            horizontalAlignment: Text.AlignHCenter
                                            verticalAlignment: Text.AlignVCenter
                                        }
                                    }
                                }

                                RowLayout {
                                    Layout.fillWidth: true
                                    Layout.fillHeight: true
                                    spacing: root.videoFullscreen ? 0 : (root.compact ? 14 : 18)

                                    Rectangle {
                                        id: listPanel
                                        Layout.preferredWidth: Math.max(220, playerPanel.width * 0.30)
                                        Layout.fillHeight: true
                                        Layout.minimumWidth: 200
                                        radius: 22
                                        color: root.glassStrong
                                        border.width: 1
                                        border.color: root.glassBorder
                                        visible: !root.videoFullscreen

                                        ColumnLayout {
                                            anchors.fill: parent
                                            anchors.margins: root.compact ? 14 : 18
                                            spacing: 10

                                            Text {
                                                Layout.fillWidth: true
                                                text: "视频列表"
                                                color: root.pageText
                                                font.family: root.uiFamily
                                                font.pixelSize: root.compact ? 14 : 16
                                                font.bold: true
                                            }

                                            ListView {
                                                id: videoList
                                                Layout.fillWidth: true
                                                Layout.fillHeight: true
                                                clip: true
                                                spacing: 8
                                                boundsBehavior: Flickable.DragOverBounds
                                                model: videoLibrary.items
                                                currentIndex: -1

                                                ScrollBar.vertical: ScrollBar { }

                                                delegate: Rectangle {
                                                    width: ListView.view ? ListView.view.width : 0
                                                    height: root.compact ? 56 : 64
                                                    radius: 14
                                                    color: ListView.isCurrentItem
                                                           ? Qt.rgba(245 / 255, 164 / 255, 0, 0.16)
                                                           : Qt.rgba(38 / 255, 40 / 255, 42 / 255, 0.50)
                                                    border.width: 1
                                                    border.color: ListView.isCurrentItem
                                                                  ? Qt.rgba(245 / 255, 164 / 255, 0, 0.46)
                                                                  : Qt.rgba(1, 1, 1, 0.16)

                                                    MouseArea {
                                                        anchors.fill: parent
                                                        onClicked: {
                                                            videoList.currentIndex = index
                                                            videoPageRoot.currentTitle = modelData.title
                                                            if (player.source === modelData.source) {
                                                                player.seek(0)
                                                                player.play()
                                                            } else {
                                                                player.stop()
                                                                videoPageRoot.pendingPlay = true
                                                                player.source = modelData.source
                                                            }
                                                            videoPageRoot.controlsVisible = true
                                                            hideTimer.restart()
                                                        }
                                                    }

                                                    ColumnLayout {
                                                        anchors.fill: parent
                                                        anchors.leftMargin: 12
                                                        anchors.rightMargin: 12
                                                        anchors.topMargin: 8
                                                        anchors.bottomMargin: 8
                                                        spacing: 2

                                                        Text {
                                                            Layout.fillWidth: true
                                                            text: modelData.title
                                                            color: root.pageText
                                                            font.family: root.uiFamily
                                                            font.pixelSize: root.compact ? 13 : 15
                                                            font.bold: true
                                                            elide: Text.ElideRight
                                                        }

                                                        Text {
                                                            Layout.fillWidth: true
                                                            text: modelData.sizeText
                                                            color: root.mutedText
                                                            font.family: root.uiFamily
                                                            font.pixelSize: root.compact ? 10 : 12
                                                            elide: Text.ElideRight
                                                        }
                                                    }
                                                }
                                            }

                                            Text {
                                                Layout.fillWidth: true
                                                visible: !videoLibrary.items || videoLibrary.items.length === 0
                                                text: videoLibrary.directory
                                                      ? ("此目录为空：\n" + videoLibrary.directory + "\n\n把 mp4/mkv 视频文件放进去，点击右上角『刷新』。")
                                                      : "找不到 assets/videos/ 目录"
                                                color: root.mutedText
                                                font.family: root.uiFamily
                                                font.pixelSize: root.compact ? 11 : 12
                                                wrapMode: Text.WordWrap
                                                horizontalAlignment: Text.AlignHCenter
                                            }
                                        }
                                    }

                                    Item {
                                        id: playerArea
                                        Layout.fillWidth: true
                                        Layout.fillHeight: true

                                        Rectangle {
                                            anchors.fill: parent
                                            radius: root.videoFullscreen ? 0 : 22
                                            color: "#000000"
                                            border.width: root.videoFullscreen ? 0 : 1
                                            border.color: root.glassBorder
                                        }

                                        VideoOutput {
                                            id: videoOutput
                                            anchors.fill: parent
                                            anchors.margins: root.videoFullscreen ? 0 : 2
                                            source: player
                                            fillMode: VideoOutput.PreserveAspectFit
                                        }

                                        Text {
                                            anchors.centerIn: parent
                                            visible: player.playbackState !== MediaPlayer.PlayingState
                                                     && (!videoPageRoot.currentTitle || player.playbackState === MediaPlayer.StoppedState)
                                            text: videoPageRoot.currentTitle
                                                  ? "已停止"
                                                  : (videoLibrary.items && videoLibrary.items.length > 0
                                                     ? "请从左侧列表选择视频"
                                                     : "把视频放入 assets/videos/ 后刷新")
                                            color: root.mutedText
                                            font.family: root.uiFamily
                                            font.pixelSize: 16
                                        }

                                        MouseArea {
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            acceptedButtons: Qt.LeftButton
                                            onPositionChanged: {
                                                videoPageRoot.controlsVisible = true
                                                if (player.playbackState === MediaPlayer.PlayingState)
                                                    hideTimer.restart()
                                            }
                                            onPressed: {
                                                videoPageRoot.controlsVisible = true
                                                if (player.playbackState === MediaPlayer.PlayingState)
                                                    hideTimer.restart()
                                            }
                                            onDoubleClicked: root.videoFullscreen = !root.videoFullscreen
                                        }

                                        Rectangle {
                                            id: controlBar
                                            anchors.left: parent.left
                                            anchors.right: parent.right
                                            anchors.bottom: parent.bottom
                                            anchors.leftMargin: root.videoFullscreen ? 18 : 14
                                            anchors.rightMargin: root.videoFullscreen ? 18 : 14
                                            anchors.bottomMargin: root.videoFullscreen ? 18 : 14
                                            height: root.compact ? 70 : 80
                                            radius: 18
                                            color: Qt.rgba(0, 0, 0, 0.60)
                                            border.width: 1
                                            border.color: Qt.rgba(1, 1, 1, 0.18)
                                            visible: videoPageRoot.controlsVisible
                                            opacity: videoPageRoot.controlsVisible ? 1.0 : 0.0
                                            Behavior on opacity { NumberAnimation { duration: 160 } }

                                            RowLayout {
                                                anchors.fill: parent
                                                anchors.leftMargin: 16
                                                anchors.rightMargin: 16
                                                spacing: 12

                                                Button {
                                                    id: playPauseButton
                                                    Layout.preferredWidth: root.compact ? 48 : 56
                                                    Layout.preferredHeight: root.compact ? 48 : 56
                                                    hoverEnabled: true
                                                    Accessible.name: player.playbackState === MediaPlayer.PlayingState ? "暂停" : "播放"
                                                    enabled: player.source !== ""
                                                    onClicked: {
                                                        if (player.playbackState === MediaPlayer.PlayingState)
                                                            player.pause()
                                                        else
                                                            player.play()
                                                    }
                                                    background: Rectangle {
                                                        radius: width / 2
                                                        color: playPauseButton.down
                                                               ? Qt.rgba(245 / 255, 164 / 255, 0, 0.30)
                                                               : Qt.rgba(245 / 255, 164 / 255, 0, 0.18)
                                                        border.width: 1
                                                        border.color: Qt.rgba(245 / 255, 164 / 255, 0, 0.55)
                                                    }
                                                    contentItem: Text {
                                                        text: player.playbackState === MediaPlayer.PlayingState ? "⏸" : "▶"
                                                        color: root.accentBlue
                                                        font.family: root.uiFamily
                                                        font.pixelSize: root.compact ? 22 : 26
                                                        font.bold: true
                                                        horizontalAlignment: Text.AlignHCenter
                                                        verticalAlignment: Text.AlignVCenter
                                                    }
                                                }

                                                Text {
                                                    Layout.preferredWidth: root.compact ? 54 : 64
                                                    text: videoPageRoot.formatTime(player.position)
                                                    color: root.pageText
                                                    font.family: root.uiFamily
                                                    font.pixelSize: root.compact ? 12 : 14
                                                    horizontalAlignment: Text.AlignRight
                                                }

                                                Slider {
                                                    id: seekSlider
                                                    Layout.fillWidth: true
                                                    from: 0
                                                    to: Math.max(1, player.duration)
                                                    stepSize: 1
                                                    enabled: player.duration > 0

                                                    property bool seeking: false

                                                    Timer {
                                                        id: seekResetTimer
                                                        interval: 500
                                                        onTriggered: seekSlider.seeking = false
                                                    }

                                                    Connections {
                                                        target: player
                                                        function onPositionChanged() {
                                                            if (!seekSlider.pressed && !seekSlider.seeking)
                                                                seekSlider.value = player.position
                                                        }
                                                        function onDurationChanged() {
                                                            if (!seekSlider.pressed && !seekSlider.seeking)
                                                                seekSlider.value = player.position
                                                        }
                                                    }

                                                    onPressedChanged: {
                                                        if (!pressed) {
                                                            var target = Math.round(value)
                                                            console.log("[seek] commit", target,
                                                                        "seekable:", player.seekable)
                                                            seekSlider.seeking = true
                                                            seekResetTimer.restart()
                                                            player.seek(target)
                                                        }
                                                    }
                                                }

                                                Text {
                                                    Layout.preferredWidth: root.compact ? 54 : 64
                                                    text: videoPageRoot.formatTime(player.duration)
                                                    color: root.mutedText
                                                    font.family: root.uiFamily
                                                    font.pixelSize: root.compact ? 12 : 14
                                                }

                                                Button {
                                                    id: muteButton
                                                    Layout.preferredWidth: root.compact ? 40 : 46
                                                    Layout.preferredHeight: root.compact ? 40 : 46
                                                    hoverEnabled: true
                                                    Accessible.name: player.muted ? "取消静音" : "静音"
                                                    onClicked: player.muted = !player.muted
                                                    background: Rectangle {
                                                        radius: 14
                                                        color: muteButton.down
                                                               ? Qt.rgba(1, 1, 1, 0.18)
                                                               : Qt.rgba(38 / 255, 40 / 255, 42 / 255, 0.62)
                                                        border.width: 1
                                                        border.color: Qt.rgba(1, 1, 1, 0.22)
                                                    }
                                                    contentItem: Text {
                                                        text: player.muted ? "🔇" : "🔊"
                                                        color: root.pageText
                                                        font.family: root.uiFamily
                                                        font.pixelSize: root.compact ? 16 : 18
                                                        horizontalAlignment: Text.AlignHCenter
                                                        verticalAlignment: Text.AlignVCenter
                                                    }
                                                }

                                                Slider {
                                                    id: volumeSlider
                                                    Layout.preferredWidth: root.compact ? 96 : 130
                                                    from: 0.0
                                                    to: 1.0
                                                    stepSize: 0.01
                                                    value: player.volume
                                                    onMoved: {
                                                        player.volume = value
                                                        if (player.muted && value > 0)
                                                            player.muted = false
                                                    }
                                                }

                                                Button {
                                                    id: fullscreenButton
                                                    Layout.preferredWidth: root.compact ? 40 : 46
                                                    Layout.preferredHeight: root.compact ? 40 : 46
                                                    hoverEnabled: true
                                                    Accessible.name: root.videoFullscreen ? "退出全屏" : "全屏"
                                                    onClicked: root.videoFullscreen = !root.videoFullscreen
                                                    background: Rectangle {
                                                        radius: 14
                                                        color: fullscreenButton.down
                                                               ? Qt.rgba(1, 1, 1, 0.18)
                                                               : Qt.rgba(38 / 255, 40 / 255, 42 / 255, 0.62)
                                                        border.width: 1
                                                        border.color: Qt.rgba(1, 1, 1, 0.22)
                                                    }
                                                    contentItem: Text {
                                                        text: root.videoFullscreen ? "⤡" : "⛶"
                                                        color: root.pageText
                                                        font.family: root.uiFamily
                                                        font.pixelSize: root.compact ? 18 : 22
                                                        font.bold: true
                                                        horizontalAlignment: Text.AlignHCenter
                                                        verticalAlignment: Text.AlignVCenter
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        Component.onDestruction: {
                            player.stop()
                            if (root.videoFullscreen)
                                root.videoFullscreen = false
                        }
                    }
                }

                Component {
                    id: musicPageComponent

                    Item {
                        id: musicPageRoot
                        anchors.fill: parent

                        property string currentTitle: ""
                        property string currentCoverUrl: ""
                        property var lyrics: []
                        property int currentLyricIndex: -1
                        property int currentIndex: -1
                        property int playMode: 0
                        property bool pendingPlay: false

                        readonly property var playModeIcons: ["↕", "↺", "⇄"]
                        readonly property var playModeNames: ["顺序", "单曲", "随机"]

                        function formatTime(ms) {
                            if (!ms || ms < 0) return "00:00"
                            var totalSec = Math.floor(ms / 1000)
                            var m = Math.floor(totalSec / 60)
                            var s = totalSec % 60
                            function pad(n) { return (n < 10 ? "0" : "") + n }
                            return pad(m) + ":" + pad(s)
                        }

                        function locateLyric(positionMs) {
                            var arr = musicPageRoot.lyrics
                            if (!arr || arr.length === 0) return -1
                            var lo = 0, hi = arr.length - 1, ans = -1
                            while (lo <= hi) {
                                var mid = (lo + hi) >> 1
                                if (arr[mid].timeMs <= positionMs) {
                                    ans = mid
                                    lo = mid + 1
                                } else {
                                    hi = mid - 1
                                }
                            }
                            return ans
                        }

                        function playAt(idx) {
                            var items = musicLibrary.items
                            if (idx < 0 || idx >= items.length) return
                            musicPageRoot.currentIndex = idx
                            var item = items[idx]
                            musicPageRoot.currentTitle = item.title || ""
                            musicPageRoot.currentCoverUrl =
                                (item.coverUrl && String(item.coverUrl).length > 0)
                                    ? String(item.coverUrl) : ""
                            musicPageRoot.lyrics =
                                item.lrcPath && item.lrcPath.length > 0
                                    ? musicLibrary.parseLrc(item.lrcPath) : []
                            musicPageRoot.currentLyricIndex = -1
                            audioPlayer.stop()
                            audioPlayer.muted = false
                            if (audioPlayer.volume < 0.05)
                                audioPlayer.volume = 1.0
                            musicPageRoot.pendingPlay = true
                            audioPlayer.source = item.source
                            console.log("[music] playAt", idx, "vol", audioPlayer.volume,
                                        "muted", audioPlayer.muted,
                                        "source", item.source)
                        }

                        function nextTrack(autoFromEnd) {
                            var len = musicLibrary.items.length
                            if (len === 0) return
                            if (musicPageRoot.playMode === 1 && autoFromEnd) {
                                audioPlayer.seek(0)
                                audioPlayer.play()
                                return
                            }
                            if (musicPageRoot.playMode === 2) {
                                var next
                                do { next = Math.floor(Math.random() * len) }
                                while (len > 1 && next === musicPageRoot.currentIndex)
                                musicPageRoot.playAt(next)
                                return
                            }
                            if (musicPageRoot.currentIndex + 1 < len) {
                                musicPageRoot.playAt(musicPageRoot.currentIndex + 1)
                            } else if (autoFromEnd) {
                                audioPlayer.stop()
                            } else {
                                musicPageRoot.playAt(0)
                            }
                        }

                        function prevTrack() {
                            var len = musicLibrary.items.length
                            if (len === 0) return
                            if (musicPageRoot.currentIndex - 1 >= 0) {
                                musicPageRoot.playAt(musicPageRoot.currentIndex - 1)
                            } else {
                                musicPageRoot.playAt(len - 1)
                            }
                        }

                        Connections {
                            target: root
                            function onMusicPageDeactivated() {
                                audioPlayer.stop()
                            }
                        }

                        Timer {
                            id: musicSeekResetTimer
                            interval: 500
                            onTriggered: musicSeekSlider.seeking = false
                        }

                        MediaPlayer {
                            id: audioPlayer
                            autoPlay: false
                            notifyInterval: 200
                            volume: 1.0

                            onStatusChanged: {
                                console.log("[music] status", status, "err", error, errorString,
                                            "hasAudio", hasAudio, "duration", duration,
                                            "vol", volume, "muted", muted)
                                if (musicPageRoot.pendingPlay
                                    && (status === MediaPlayer.LoadedMedia
                                        || status === MediaPlayer.BufferedMedia)) {
                                    musicPageRoot.pendingPlay = false
                                    audioPlayer.play()
                                }
                                if (status === MediaPlayer.EndOfMedia) {
                                    musicPageRoot.nextTrack(true)
                                }
                            }

                            onPlaybackStateChanged: console.log("[music] state",
                                                                playbackState,
                                                                "pos", position)

                            onError: console.warn("[music] ERROR", error, errorString)
                        }

                        Connections {
                            target: audioPlayer
                            function onPositionChanged() {
                                var idx = musicPageRoot.locateLyric(audioPlayer.position)
                                if (idx !== musicPageRoot.currentLyricIndex) {
                                    musicPageRoot.currentLyricIndex = idx
                                    if (idx >= 0 && lyricsView.count > 0)
                                        lyricsView.positionViewAtIndex(idx, ListView.Center)
                                }
                            }
                        }

                        Rectangle {
                            anchors.fill: musicPanel
                            anchors.topMargin: 14
                            radius: musicPanel.radius
                            color: root.shadowTint
                        }

                        Rectangle {
                            id: musicPanel
                            anchors.fill: parent
                            radius: root.compact ? 30 : 34
                            color: root.glassPanel
                            border.width: 1
                            border.color: root.glassBorder
                            clip: true

                            ColumnLayout {
                                anchors.fill: parent
                                anchors.margins: root.compact ? 20 : 26
                                spacing: root.compact ? 14 : 18

                                RowLayout {
                                    Layout.fillWidth: true
                                    Layout.preferredHeight: root.compact ? 52 : 60
                                    spacing: 12

                                    Button {
                                        id: musicBackButton
                                        Layout.preferredWidth: root.compact ? 96 : 112
                                        Layout.preferredHeight: root.compact ? 44 : 48
                                        hoverEnabled: true
                                        focusPolicy: Qt.StrongFocus
                                        Accessible.name: "返回功能应用"
                                        onClicked: root.functionPage = "grid"
                                        background: Rectangle {
                                            radius: 18
                                            color: musicBackButton.down
                                                   ? Qt.rgba(245 / 255, 164 / 255, 0, 0.18)
                                                   : musicBackButton.hovered || musicBackButton.activeFocus
                                                     ? Qt.rgba(1, 1, 1, 0.10)
                                                     : Qt.rgba(38 / 255, 40 / 255, 42 / 255, 0.54)
                                            border.width: 1
                                            border.color: musicBackButton.activeFocus
                                                          ? Qt.rgba(245 / 255, 164 / 255, 0, 0.56)
                                                          : Qt.rgba(1, 1, 1, 0.22)
                                        }
                                        contentItem: Text {
                                            text: "返回"
                                            color: root.pageText
                                            font.family: root.uiFamily
                                            font.pixelSize: root.compact ? 14 : 15
                                            font.bold: true
                                            horizontalAlignment: Text.AlignHCenter
                                            verticalAlignment: Text.AlignVCenter
                                        }
                                    }

                                    ColumnLayout {
                                        Layout.fillWidth: true
                                        spacing: 2

                                        Text {
                                            Layout.fillWidth: true
                                            text: "音乐播放器"
                                            color: root.pageText
                                            font.family: root.uiFamily
                                            font.pixelSize: root.compact ? 22 : 28
                                            font.bold: true
                                            elide: Text.ElideRight
                                        }

                                        Text {
                                            Layout.fillWidth: true
                                            text: musicPageRoot.currentTitle || "选择左侧列表中的歌曲开始播放"
                                            color: root.mutedText
                                            font.family: root.uiFamily
                                            font.pixelSize: root.compact ? 11 : 13
                                            elide: Text.ElideRight
                                        }
                                    }

                                    Button {
                                        id: musicRefreshButton
                                        Layout.preferredWidth: root.compact ? 92 : 108
                                        Layout.preferredHeight: root.compact ? 40 : 44
                                        hoverEnabled: true
                                        focusPolicy: Qt.StrongFocus
                                        Accessible.name: "刷新音乐列表"
                                        onClicked: musicLibrary.refresh()
                                        background: Rectangle {
                                            radius: 18
                                            color: musicRefreshButton.down
                                                   ? Qt.rgba(245 / 255, 164 / 255, 0, 0.22)
                                                   : musicRefreshButton.hovered || musicRefreshButton.activeFocus
                                                     ? Qt.rgba(245 / 255, 164 / 255, 0, 0.16)
                                                     : Qt.rgba(38 / 255, 40 / 255, 42 / 255, 0.56)
                                            border.width: 1
                                            border.color: musicRefreshButton.activeFocus
                                                          ? Qt.rgba(245 / 255, 164 / 255, 0, 0.52)
                                                          : Qt.rgba(1, 1, 1, 0.22)
                                        }
                                        contentItem: Text {
                                            text: "刷新"
                                            color: root.pageText
                                            font.family: root.uiFamily
                                            font.pixelSize: root.compact ? 13 : 14
                                            font.bold: true
                                            horizontalAlignment: Text.AlignHCenter
                                            verticalAlignment: Text.AlignVCenter
                                        }
                                    }
                                }

                                RowLayout {
                                    Layout.fillWidth: true
                                    Layout.fillHeight: true
                                    spacing: root.compact ? 12 : 18

                                    Rectangle {
                                        Layout.preferredWidth: parent.width * 0.30
                                        Layout.fillHeight: true
                                        radius: 22
                                        color: Qt.rgba(0, 0, 0, 0.28)
                                        border.width: 1
                                        border.color: Qt.rgba(1, 1, 1, 0.10)
                                        clip: true

                                        ColumnLayout {
                                            anchors.fill: parent
                                            anchors.margins: 14
                                            spacing: 8

                                            RowLayout {
                                                Layout.fillWidth: true
                                                spacing: 8

                                                Text {
                                                    text: "本地歌单"
                                                    color: root.pageText
                                                    font.family: root.uiFamily
                                                    font.pixelSize: 14
                                                    font.bold: true
                                                }

                                                Item { Layout.fillWidth: true }

                                                Text {
                                                    text: musicLibrary.items.length + " 首"
                                                    color: root.mutedText
                                                    font.family: root.uiFamily
                                                    font.pixelSize: 11
                                                }
                                            }

                                            ListView {
                                                id: musicList
                                                Layout.fillWidth: true
                                                Layout.fillHeight: true
                                                clip: true
                                                model: musicLibrary.items
                                                spacing: 4
                                                boundsBehavior: Flickable.StopAtBounds

                                                ScrollBar.vertical: ScrollBar {
                                                    policy: ScrollBar.AsNeeded
                                                }

                                                delegate: Rectangle {
                                                    width: ListView.view ? ListView.view.width : 0
                                                    height: 52
                                                    radius: 12
                                                    color: index === musicPageRoot.currentIndex
                                                           ? Qt.rgba(245/255, 164/255, 0, 0.16)
                                                           : (rowHover.containsMouse
                                                              ? Qt.rgba(1, 1, 1, 0.06)
                                                              : "transparent")
                                                    border.width: index === musicPageRoot.currentIndex ? 1 : 0
                                                    border.color: Qt.rgba(245/255, 164/255, 0, 0.42)

                                                    RowLayout {
                                                        anchors.fill: parent
                                                        anchors.leftMargin: 10
                                                        anchors.rightMargin: 12
                                                        spacing: 10

                                                        Rectangle {
                                                            Layout.preferredWidth: 34
                                                            Layout.preferredHeight: 34
                                                            radius: 8
                                                            color: Qt.rgba(1, 1, 1, 0.06)
                                                            border.width: 1
                                                            border.color: Qt.rgba(1, 1, 1, 0.14)
                                                            clip: true

                                                            Image {
                                                                id: thumbCover
                                                                anchors.fill: parent
                                                                source: modelData.coverUrl || ""
                                                                fillMode: Image.PreserveAspectCrop
                                                                asynchronous: true
                                                                cache: true
                                                                visible: status === Image.Ready
                                                            }

                                                            Text {
                                                                anchors.centerIn: parent
                                                                visible: !thumbCover.visible
                                                                text: root.mdi("F0F74")
                                                                color: root.accentBlue
                                                                font.family: root.iconFamily
                                                                font.pixelSize: 18
                                                            }
                                                        }

                                                        Text {
                                                            Layout.fillWidth: true
                                                            text: modelData.title || ""
                                                            color: index === musicPageRoot.currentIndex
                                                                   ? root.accentBlue
                                                                   : root.pageText
                                                            font.family: root.uiFamily
                                                            font.pixelSize: 13
                                                            font.bold: index === musicPageRoot.currentIndex
                                                            elide: Text.ElideRight
                                                        }

                                                        Text {
                                                            text: modelData.sizeText || ""
                                                            color: root.softText
                                                            font.family: root.uiFamily
                                                            font.pixelSize: 10
                                                        }
                                                    }

                                                    MouseArea {
                                                        id: rowHover
                                                        anchors.fill: parent
                                                        hoverEnabled: true
                                                        onClicked: musicPageRoot.playAt(index)
                                                    }
                                                }

                                                Text {
                                                    anchors.centerIn: parent
                                                    visible: musicList.count === 0
                                                    text: "歌单为空\n把 mp3 / lrc / jpg 放到\nassets/music/"
                                                    color: root.mutedText
                                                    font.family: root.uiFamily
                                                    font.pixelSize: 12
                                                    horizontalAlignment: Text.AlignHCenter
                                                }
                                            }
                                        }
                                    }

                                    Item {
                                        Layout.fillWidth: true
                                        Layout.fillHeight: true

                                        Item {
                                            id: discWrapper
                                            width: Math.min(parent.width, parent.height - 60) * 0.88
                                            height: width
                                            anchors.centerIn: parent

                                            Item {
                                                id: tonearm
                                                width: 4
                                                height: parent.height * 0.52
                                                anchors.right: parent.right
                                                anchors.rightMargin: parent.width * 0.04
                                                anchors.top: parent.top
                                                anchors.topMargin: -parent.height * 0.06
                                                rotation: audioPlayer.playbackState === MediaPlayer.PlayingState ? 24 : 14
                                                transformOrigin: Item.Top
                                                z: 5

                                                Behavior on rotation {
                                                    NumberAnimation { duration: 500; easing.type: Easing.OutCubic }
                                                }

                                                Rectangle {
                                                    anchors.fill: parent
                                                    radius: width / 2
                                                    gradient: Gradient {
                                                        orientation: Gradient.Horizontal
                                                        GradientStop { position: 0.0; color: "#B6B2A6" }
                                                        GradientStop { position: 0.45; color: "#FAF6E8" }
                                                        GradientStop { position: 1.0; color: "#A9A599" }
                                                    }
                                                }

                                                Rectangle {
                                                    id: tonearmPivot
                                                    anchors.horizontalCenter: parent.horizontalCenter
                                                    anchors.top: parent.top
                                                    anchors.topMargin: -15
                                                    width: 30
                                                    height: 30
                                                    radius: 15
                                                    gradient: Gradient {
                                                        GradientStop { position: 0.0; color: "#FAF6E8" }
                                                        GradientStop { position: 1.0; color: "#9C9789" }
                                                    }
                                                    border.width: 1
                                                    border.color: Qt.rgba(0, 0, 0, 0.32)

                                                    Rectangle {
                                                        anchors.centerIn: parent
                                                        width: 8
                                                        height: 8
                                                        radius: 4
                                                        color: "#1A1B1D"
                                                        border.width: 1
                                                        border.color: Qt.rgba(255, 255, 255, 0.20)
                                                    }
                                                }

                                                Rectangle {
                                                    id: tonearmHead
                                                    anchors.horizontalCenter: parent.horizontalCenter
                                                    anchors.bottom: parent.bottom
                                                    anchors.bottomMargin: -10
                                                    width: 22
                                                    height: 22
                                                    radius: 11
                                                    gradient: Gradient {
                                                        GradientStop { position: 0.0; color: "#FAF6E8" }
                                                        GradientStop { position: 1.0; color: "#9C9789" }
                                                    }
                                                    border.width: 1
                                                    border.color: Qt.rgba(0, 0, 0, 0.34)

                                                    Rectangle {
                                                        anchors.centerIn: parent
                                                        width: 4
                                                        height: 4
                                                        radius: 2
                                                        color: "#1A1B1D"
                                                    }
                                                }
                                            }

                                            Rectangle {
                                                id: disc
                                                anchors.fill: parent
                                                radius: width / 2
                                                color: "#0B0C0E"
                                                border.width: 2
                                                border.color: Qt.rgba(1, 1, 1, 0.10)

                                                RotationAnimator on rotation {
                                                    id: discSpin
                                                    from: 0
                                                    to: 360
                                                    duration: 16000
                                                    loops: Animation.Infinite
                                                    running: audioPlayer.playbackState === MediaPlayer.PlayingState
                                                }

                                                Rectangle {
                                                    anchors.centerIn: parent
                                                    width: parent.width * 0.985
                                                    height: width
                                                    radius: width / 2
                                                    color: "transparent"
                                                    border.width: 1
                                                    border.color: Qt.rgba(1, 1, 1, 0.18)
                                                }

                                                Repeater {
                                                    model: 14
                                                    Rectangle {
                                                        anchors.centerIn: parent
                                                        property real ratio: 0.965 - index * (0.965 - 0.705) / 13
                                                        width: parent.width * ratio
                                                        height: width
                                                        radius: width / 2
                                                        color: "transparent"
                                                        border.width: 1
                                                        border.color: index % 3 === 0
                                                            ? Qt.rgba(1, 1, 1, 0.07)
                                                            : Qt.rgba(1, 1, 1, 0.025)
                                                    }
                                                }

                                                Rectangle {
                                                    anchors.centerIn: parent
                                                    width: parent.width * 0.685
                                                    height: width
                                                    radius: width / 2
                                                    color: "transparent"
                                                    border.width: 2
                                                    border.color: Qt.rgba(1, 1, 1, 0.10)
                                                }

                                                Item {
                                                    id: coverHolder
                                                    anchors.centerIn: parent
                                                    width: parent.width * 0.66
                                                    height: width

                                                    Rectangle {
                                                        id: coverBackdrop
                                                        anchors.fill: parent
                                                        radius: width / 2
                                                        color: "#1A1B1D"
                                                    }

                                                    Item {
                                                        id: coverContent
                                                        anchors.fill: parent
                                                        visible: false

                                                        Image {
                                                            id: coverImage
                                                            anchors.fill: parent
                                                            source: musicPageRoot.currentCoverUrl
                                                            fillMode: Image.PreserveAspectCrop
                                                            asynchronous: true
                                                            cache: true
                                                            smooth: true
                                                            mipmap: true
                                                        }

                                                        Text {
                                                            anchors.centerIn: parent
                                                            visible: coverImage.status !== Image.Ready
                                                            text: root.mdi("F0F74")
                                                            color: root.accentBlue
                                                            font.family: root.iconFamily
                                                            font.pixelSize: parent.width * 0.34
                                                        }
                                                    }

                                                    Rectangle {
                                                        id: coverMask
                                                        anchors.fill: parent
                                                        radius: width / 2
                                                        visible: false
                                                    }

                                                    OpacityMask {
                                                        anchors.fill: parent
                                                        source: coverContent
                                                        maskSource: coverMask
                                                        antialiasing: true
                                                    }

                                                    Rectangle {
                                                        anchors.fill: parent
                                                        radius: width / 2
                                                        color: "transparent"
                                                        border.width: 2
                                                        border.color: Qt.rgba(1, 1, 1, 0.22)
                                                    }

                                                    Rectangle {
                                                        anchors.centerIn: parent
                                                        width: 9
                                                        height: 9
                                                        radius: 4.5
                                                        color: "#0A0B0D"
                                                        border.width: 1
                                                        border.color: Qt.rgba(1, 1, 1, 0.32)
                                                        z: 10
                                                    }
                                                }
                                            }
                                        }

                                        ColumnLayout {
                                            anchors.bottom: parent.bottom
                                            anchors.left: parent.left
                                            anchors.right: parent.right
                                            anchors.bottomMargin: 4
                                            spacing: 2

                                            Text {
                                                Layout.fillWidth: true
                                                text: musicPageRoot.currentTitle || "尚未播放"
                                                color: root.pageText
                                                font.family: root.uiFamily
                                                font.pixelSize: 18
                                                font.bold: true
                                                horizontalAlignment: Text.AlignHCenter
                                                elide: Text.ElideRight
                                            }
                                            Text {
                                                Layout.fillWidth: true
                                                text: audioPlayer.playbackState === MediaPlayer.PlayingState
                                                      ? "正在播放 · " + musicPageRoot.playModeNames[musicPageRoot.playMode]
                                                      : audioPlayer.playbackState === MediaPlayer.PausedState
                                                        ? "已暂停"
                                                        : "本地音乐 · " + musicLibrary.items.length + " 首"
                                                color: root.mutedText
                                                font.family: root.uiFamily
                                                font.pixelSize: 12
                                                horizontalAlignment: Text.AlignHCenter
                                            }
                                        }
                                    }

                                    Rectangle {
                                        Layout.preferredWidth: parent.width * 0.32
                                        Layout.fillHeight: true
                                        radius: 22
                                        color: Qt.rgba(0, 0, 0, 0.22)
                                        border.width: 1
                                        border.color: Qt.rgba(1, 1, 1, 0.08)
                                        clip: true

                                        Rectangle {
                                            anchors.left: parent.left
                                            anchors.right: parent.right
                                            anchors.top: parent.top
                                            height: 28
                                            radius: parent.radius
                                            gradient: Gradient {
                                                GradientStop { position: 0.0; color: Qt.rgba(0, 0, 0, 0.55) }
                                                GradientStop { position: 1.0; color: Qt.rgba(0, 0, 0, 0.0) }
                                            }
                                            z: 2
                                        }
                                        Rectangle {
                                            anchors.left: parent.left
                                            anchors.right: parent.right
                                            anchors.bottom: parent.bottom
                                            height: 28
                                            radius: parent.radius
                                            gradient: Gradient {
                                                GradientStop { position: 0.0; color: Qt.rgba(0, 0, 0, 0.0) }
                                                GradientStop { position: 1.0; color: Qt.rgba(0, 0, 0, 0.55) }
                                            }
                                            z: 2
                                        }

                                        ListView {
                                            id: lyricsView
                                            anchors.fill: parent
                                            anchors.topMargin: 18
                                            anchors.bottomMargin: 18
                                            anchors.leftMargin: 8
                                            anchors.rightMargin: 8
                                            model: musicPageRoot.lyrics
                                            spacing: 12
                                            interactive: true
                                            clip: true
                                            boundsBehavior: Flickable.StopAtBounds

                                            preferredHighlightBegin: height / 2 - 20
                                            preferredHighlightEnd: height / 2 + 20
                                            highlightRangeMode: ListView.ApplyRange
                                            highlightMoveDuration: 380
                                            highlightMoveVelocity: -1

                                            delegate: Item {
                                                width: ListView.view ? ListView.view.width : 0
                                                height: Math.max(20, lyricText.implicitHeight + 6)

                                                Text {
                                                    id: lyricText
                                                    anchors.left: parent.left
                                                    anchors.right: parent.right
                                                    anchors.leftMargin: 12
                                                    anchors.rightMargin: 12
                                                    anchors.verticalCenter: parent.verticalCenter
                                                    text: modelData.text || ""
                                                    color: index === musicPageRoot.currentLyricIndex
                                                           ? root.accentBlue
                                                           : root.mutedText
                                                    font.family: root.uiFamily
                                                    font.pixelSize: index === musicPageRoot.currentLyricIndex ? 18 : 14
                                                    font.bold: index === musicPageRoot.currentLyricIndex
                                                    horizontalAlignment: Text.AlignHCenter
                                                    wrapMode: Text.WordWrap
                                                    Behavior on font.pixelSize {
                                                        NumberAnimation { duration: 200 }
                                                    }
                                                    Behavior on color {
                                                        ColorAnimation { duration: 200 }
                                                    }
                                                }
                                            }

                                            Text {
                                                anchors.centerIn: parent
                                                visible: lyricsView.count === 0
                                                text: musicPageRoot.currentTitle === ""
                                                      ? "选择歌曲开始播放"
                                                      : "暂无歌词"
                                                color: root.mutedText
                                                font.family: root.uiFamily
                                                font.pixelSize: 14
                                                horizontalAlignment: Text.AlignHCenter
                                            }
                                        }
                                    }
                                }

                                Rectangle {
                                    Layout.fillWidth: true
                                    Layout.preferredHeight: root.compact ? 96 : 108
                                    radius: 22
                                    color: Qt.rgba(0, 0, 0, 0.30)
                                    border.width: 1
                                    border.color: Qt.rgba(1, 1, 1, 0.10)

                                    ColumnLayout {
                                        anchors.fill: parent
                                        anchors.leftMargin: 18
                                        anchors.rightMargin: 18
                                        anchors.topMargin: 10
                                        anchors.bottomMargin: 10
                                        spacing: 4

                                        RowLayout {
                                            Layout.fillWidth: true
                                            spacing: 10

                                            Text {
                                                text: musicPageRoot.formatTime(audioPlayer.position)
                                                color: root.mutedText
                                                font.family: root.uiFamily
                                                font.pixelSize: 11
                                                Layout.preferredWidth: 44
                                            }

                                            Slider {
                                                id: musicSeekSlider
                                                Layout.fillWidth: true
                                                from: 0
                                                to: Math.max(1, audioPlayer.duration)
                                                stepSize: 1
                                                enabled: audioPlayer.duration > 0

                                                property bool seeking: false

                                                Connections {
                                                    target: audioPlayer
                                                    function onPositionChanged() {
                                                        if (!musicSeekSlider.pressed && !musicSeekSlider.seeking)
                                                            musicSeekSlider.value = audioPlayer.position
                                                    }
                                                    function onDurationChanged() {
                                                        if (!musicSeekSlider.pressed && !musicSeekSlider.seeking)
                                                            musicSeekSlider.value = audioPlayer.position
                                                    }
                                                }

                                                onPressedChanged: {
                                                    if (!pressed) {
                                                        var target = Math.round(value)
                                                        musicSeekSlider.seeking = true
                                                        musicSeekResetTimer.restart()
                                                        audioPlayer.seek(target)
                                                    }
                                                }

                                                background: Rectangle {
                                                    x: musicSeekSlider.leftPadding
                                                    y: musicSeekSlider.topPadding + musicSeekSlider.availableHeight / 2 - 2
                                                    width: musicSeekSlider.availableWidth
                                                    height: 4
                                                    radius: 2
                                                    color: Qt.rgba(1, 1, 1, 0.10)

                                                    Rectangle {
                                                        width: musicSeekSlider.visualPosition * parent.width
                                                        height: parent.height
                                                        color: root.accentBlue
                                                        radius: 2
                                                    }
                                                }

                                                handle: Rectangle {
                                                    x: musicSeekSlider.leftPadding + musicSeekSlider.visualPosition * (musicSeekSlider.availableWidth - width)
                                                    y: musicSeekSlider.topPadding + musicSeekSlider.availableHeight / 2 - height / 2
                                                    width: 14
                                                    height: 14
                                                    radius: 7
                                                    color: root.accentBlue
                                                    border.color: Qt.rgba(0, 0, 0, 0.40)
                                                    border.width: 1
                                                }
                                            }

                                            Text {
                                                text: musicPageRoot.formatTime(audioPlayer.duration)
                                                color: root.mutedText
                                                font.family: root.uiFamily
                                                font.pixelSize: 11
                                                Layout.preferredWidth: 44
                                                horizontalAlignment: Text.AlignRight
                                            }
                                        }

                                        RowLayout {
                                            Layout.fillWidth: true
                                            spacing: 12

                                            Button {
                                                id: modeButton
                                                Layout.preferredWidth: 84
                                                Layout.preferredHeight: 36
                                                hoverEnabled: true
                                                Accessible.name: "切换播放模式：" + musicPageRoot.playModeNames[musicPageRoot.playMode]
                                                onClicked: musicPageRoot.playMode = (musicPageRoot.playMode + 1) % 3
                                                background: Rectangle {
                                                    radius: 14
                                                    color: modeButton.down
                                                           ? Qt.rgba(245/255, 164/255, 0, 0.20)
                                                           : modeButton.hovered
                                                             ? Qt.rgba(1, 1, 1, 0.08)
                                                             : "transparent"
                                                    border.width: 1
                                                    border.color: Qt.rgba(1, 1, 1, 0.18)
                                                }
                                                contentItem: RowLayout {
                                                    spacing: 6
                                                    Text {
                                                        text: musicPageRoot.playModeIcons[musicPageRoot.playMode]
                                                        color: root.accentBlue
                                                        font.family: root.uiFamily
                                                        font.pixelSize: 18
                                                        font.bold: true
                                                        Layout.alignment: Qt.AlignVCenter
                                                    }
                                                    Text {
                                                        text: musicPageRoot.playModeNames[musicPageRoot.playMode]
                                                        color: root.pageText
                                                        font.family: root.uiFamily
                                                        font.pixelSize: 12
                                                        Layout.alignment: Qt.AlignVCenter
                                                    }
                                                }
                                            }

                                            Item { Layout.fillWidth: true }

                                            Button {
                                                id: prevButton
                                                Layout.preferredWidth: 44
                                                Layout.preferredHeight: 44
                                                hoverEnabled: true
                                                Accessible.name: "上一首"
                                                onClicked: musicPageRoot.prevTrack()
                                                background: Rectangle {
                                                    radius: 22
                                                    color: prevButton.down
                                                           ? Qt.rgba(1, 1, 1, 0.14)
                                                           : prevButton.hovered
                                                             ? Qt.rgba(1, 1, 1, 0.08)
                                                             : "transparent"
                                                }
                                                contentItem: Text {
                                                    text: "⏮"
                                                    color: root.pageText
                                                    font.pixelSize: 20
                                                    horizontalAlignment: Text.AlignHCenter
                                                    verticalAlignment: Text.AlignVCenter
                                                }
                                            }

                                            Button {
                                                id: playButton
                                                Layout.preferredWidth: 56
                                                Layout.preferredHeight: 56
                                                hoverEnabled: true
                                                Accessible.name: audioPlayer.playbackState === MediaPlayer.PlayingState ? "暂停" : "播放"
                                                onClicked: {
                                                    if (audioPlayer.playbackState === MediaPlayer.PlayingState) {
                                                        audioPlayer.pause()
                                                    } else if (audioPlayer.source && String(audioPlayer.source).length > 0) {
                                                        audioPlayer.play()
                                                    } else if (musicLibrary.items.length > 0) {
                                                        musicPageRoot.playAt(0)
                                                    }
                                                }
                                                background: Rectangle {
                                                    radius: 28
                                                    color: playButton.down
                                                           ? Qt.rgba(245/255, 164/255, 0, 0.80)
                                                           : Qt.rgba(245/255, 164/255, 0, 0.95)
                                                    border.width: 1
                                                    border.color: Qt.rgba(245/255, 164/255, 0, 1.0)
                                                }
                                                contentItem: Text {
                                                    text: audioPlayer.playbackState === MediaPlayer.PlayingState ? "⏸" : "▶"
                                                    color: "#1A1B1D"
                                                    font.pixelSize: 22
                                                    font.bold: true
                                                    horizontalAlignment: Text.AlignHCenter
                                                    verticalAlignment: Text.AlignVCenter
                                                }
                                            }

                                            Button {
                                                id: nextButton
                                                Layout.preferredWidth: 44
                                                Layout.preferredHeight: 44
                                                hoverEnabled: true
                                                Accessible.name: "下一首"
                                                onClicked: musicPageRoot.nextTrack(false)
                                                background: Rectangle {
                                                    radius: 22
                                                    color: nextButton.down
                                                           ? Qt.rgba(1, 1, 1, 0.14)
                                                           : nextButton.hovered
                                                             ? Qt.rgba(1, 1, 1, 0.08)
                                                             : "transparent"
                                                }
                                                contentItem: Text {
                                                    text: "⏭"
                                                    color: root.pageText
                                                    font.pixelSize: 20
                                                    horizontalAlignment: Text.AlignHCenter
                                                    verticalAlignment: Text.AlignVCenter
                                                }
                                            }

                                            Item { Layout.fillWidth: true }

                                            Button {
                                                id: muteButton
                                                Layout.preferredWidth: 38
                                                Layout.preferredHeight: 36
                                                hoverEnabled: true
                                                Accessible.name: audioPlayer.muted ? "取消静音" : "静音"
                                                onClicked: audioPlayer.muted = !audioPlayer.muted
                                                background: Rectangle {
                                                    radius: 14
                                                    color: muteButton.down
                                                           ? Qt.rgba(1, 1, 1, 0.14)
                                                           : muteButton.hovered
                                                             ? Qt.rgba(1, 1, 1, 0.08)
                                                             : "transparent"
                                                }
                                                contentItem: Text {
                                                    text: audioPlayer.muted ? "🔇" : "🔊"
                                                    color: audioPlayer.muted ? root.softText : root.pageText
                                                    font.pixelSize: 16
                                                    horizontalAlignment: Text.AlignHCenter
                                                    verticalAlignment: Text.AlignVCenter
                                                }
                                            }

                                            Slider {
                                                id: volumeSlider
                                                Layout.preferredWidth: 120
                                                from: 0
                                                to: 1
                                                stepSize: 0.01
                                                value: 1.0
                                                onValueChanged: audioPlayer.volume = value

                                                background: Rectangle {
                                                    x: volumeSlider.leftPadding
                                                    y: volumeSlider.topPadding + volumeSlider.availableHeight / 2 - 2
                                                    width: volumeSlider.availableWidth
                                                    height: 4
                                                    radius: 2
                                                    color: Qt.rgba(1, 1, 1, 0.10)

                                                    Rectangle {
                                                        width: volumeSlider.visualPosition * parent.width
                                                        height: parent.height
                                                        color: root.accentBlue
                                                        radius: 2
                                                    }
                                                }

                                                handle: Rectangle {
                                                    x: volumeSlider.leftPadding + volumeSlider.visualPosition * (volumeSlider.availableWidth - width)
                                                    y: volumeSlider.topPadding + volumeSlider.availableHeight / 2 - height / 2
                                                    width: 12
                                                    height: 12
                                                    radius: 6
                                                    color: root.accentBlue
                                                    border.color: Qt.rgba(0, 0, 0, 0.40)
                                                    border.width: 1
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        Component.onDestruction: {
                            audioPlayer.stop()
                        }
                    }
                }

                Component {
                    id: aiPageComponent

                    Item {
                        id: aiPageRoot
                        anchors.fill: parent

                        property var levelHistory: [0, 0, 0, 0, 0, 0, 0]
                        property bool keyboardExpanded: false

                        readonly property bool vcAvailable: typeof voiceController !== "undefined" && voiceController.available
                        readonly property bool vcRecording: typeof voiceController !== "undefined" && voiceController.recording
                        readonly property real vcLevel: typeof voiceController !== "undefined" ? voiceController.level : 0
                        readonly property string vcStatus: typeof voiceController !== "undefined" ? voiceController.statusText : ""

                        readonly property int msgCount: aiAssistant.messages ? aiAssistant.messages.rowCount() : 0
                        readonly property bool waitingFirstToken: {
                            if (!aiAssistant.streaming || msgCount === 0) return false
                            var idx = msgCount - 1
                            var role = aiAssistant.messages.data(aiAssistant.messages.index(idx, 0), 257)
                            var content = aiAssistant.messages.data(aiAssistant.messages.index(idx, 0), 258)
                            return role === "assistant" && (!content || content.length === 0)
                        }

                        readonly property string orbState: {
                            if (vcRecording) return "listening"
                            if (waitingFirstToken) return "thinking"
                            if (aiAssistant.streaming) return "speaking"
                            return "idle"
                        }

                        readonly property color orbColor: {
                            if (orbState === "listening") return root.accentDanger
                            if (orbState === "thinking") return root.accentBlue
                            if (orbState === "speaking") return root.accentGreen
                            if (!vcAvailable) return root.mutedText
                            return root.accentBlue
                        }

                        readonly property string orbHint: {
                            if (orbState === "listening") return "正在聆听…"
                            if (orbState === "thinking") return "AI 正在思考…"
                            if (orbState === "speaking") return "AI 正在回答"
                            if (!vcAvailable) return vcStatus !== "" ? vcStatus : "语音未就绪"
                            return "按住说话"
                        }

                        Timer {
                            id: waveformTick
                            interval: 80
                            running: aiPageRoot.vcRecording
                            repeat: true
                            onTriggered: {
                                var arr = aiPageRoot.levelHistory.slice()
                                arr.push(aiPageRoot.vcLevel)
                                if (arr.length > 7) arr.shift()
                                aiPageRoot.levelHistory = arr
                            }
                            onRunningChanged: if (!running) aiPageRoot.levelHistory = [0,0,0,0,0,0,0]
                        }

                        Connections {
                            target: typeof voiceController !== "undefined" ? voiceController : null
                            function onRecognized(text) {
                                var t = (text || "").trim()
                                if (t === "") return
                                if (aiAssistant.streaming) return
                                aiAssistant.sendMessage(t)
                            }
                        }

                        Item {
                            anchors.fill: parent
                            anchors.margins: root.compact ? 16 : 22

                            Item {
                                id: aiTopBar
                                anchors.top: parent.top
                                anchors.left: parent.left
                                anchors.right: parent.right
                                height: root.compact ? 70 : 84

                                Rectangle {
                                    id: backBtn
                                    anchors.left: parent.left
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: root.compact ? 44 : 50
                                    height: width
                                    radius: width / 2
                                    color: root.glassPanel
                                    border.width: 1
                                    border.color: root.glassBorder
                                    Text {
                                        anchors.centerIn: parent
                                        text: root.mdi("F0141")
                                        color: root.pageText
                                        font.family: root.iconFamily
                                        font.pixelSize: root.compact ? 26 : 30
                                    }
                                    MouseArea { anchors.fill: parent; onClicked: root.functionPage = "grid" }
                                }

                                Column {
                                    anchors.left: backBtn.right
                                    anchors.verticalCenter: parent.verticalCenter
                                    anchors.leftMargin: 14
                                    spacing: 2

                                    Text {
                                        text: "AI 智能助手"
                                        color: root.pageText
                                        font.family: root.uiFamily
                                        font.pixelSize: root.compact ? 20 : 24
                                        font.bold: true
                                    }
                                    Row {
                                        spacing: 6
                                        Rectangle {
                                            width: 8
                                            height: 8
                                            radius: 4
                                            color: root.accentBlue
                                            anchors.verticalCenter: parent.verticalCenter
                                        }
                                        Text {
                                            text: "云端 · DeepSeek API"
                                            color: root.accentBlue
                                            font.family: root.uiFamily
                                            font.pixelSize: root.compact ? 11 : 12
                                            font.bold: true
                                            anchors.verticalCenter: parent.verticalCenter
                                        }
                                    }
                                }

                                Rectangle {
                                    id: clearBtn
                                    anchors.right: parent.right
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: root.compact ? 96 : 112
                                    height: root.compact ? 36 : 42
                                    radius: 14
                                    color: root.glassPanel
                                    border.width: 1
                                    border.color: root.glassBorder
                                    Text {
                                        anchors.centerIn: parent
                                        text: "清除历史"
                                        color: root.pageText
                                        font.family: root.uiFamily
                                        font.pixelSize: root.compact ? 13 : 14
                                    }
                                    MouseArea {
                                        anchors.fill: parent
                                        onClicked: aiAssistant.clearConversation()
                                    }
                                }
                            }

                            Item {
                                id: voiceConsole
                                anchors.bottom: parent.bottom
                                anchors.left: parent.left
                                anchors.right: parent.right
                                height: root.compact ? 180 : 210

                                Rectangle {
                                    id: kbInputBar
                                    anchors.bottom: voiceConsole.top
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    anchors.bottomMargin: root.compact ? 8 : 10
                                    height: aiPageRoot.keyboardExpanded ? (root.compact ? 64 : 72) : 0
                                    radius: 16
                                    clip: true
                                    color: Qt.rgba(0, 0, 0, 0.40)
                                    border.width: 1
                                    border.color: Qt.rgba(245/255, 164/255, 0, 0.36)
                                    visible: height > 0

                                    Behavior on height { NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }

                                    RowLayout {
                                        anchors.fill: parent
                                        anchors.leftMargin: 14
                                        anchors.rightMargin: 12
                                        anchors.topMargin: 8
                                        anchors.bottomMargin: 8
                                        spacing: 10

                                        ScrollView {
                                            Layout.fillWidth: true
                                            Layout.fillHeight: true
                                            clip: true
                                            TextArea {
                                                id: inputArea
                                                placeholderText: aiAssistant.streaming
                                                                 ? "AI 正在回答..."
                                                                 : "输入消息，Ctrl+Enter 发送"
                                                placeholderTextColor: root.softText
                                                wrapMode: TextEdit.Wrap
                                                font.family: root.uiFamily
                                                font.pixelSize: 14
                                                color: root.pageText
                                                selectByMouse: true
                                                background: Rectangle { color: "transparent" }
                                                Keys.onPressed: {
                                                    if (event.key === Qt.Key_Return && (event.modifiers & Qt.ControlModifier)) {
                                                        var t = inputArea.text.trim()
                                                        if (t !== "" && !aiAssistant.streaming) {
                                                            aiAssistant.sendMessage(t)
                                                            inputArea.text = ""
                                                        }
                                                        event.accepted = true
                                                    }
                                                }
                                            }
                                        }

                                        Rectangle {
                                            Layout.preferredWidth: 76
                                            Layout.fillHeight: true
                                            radius: 14
                                            color: inputArea.text.trim() !== "" && !aiAssistant.streaming
                                                   ? Qt.rgba(245/255, 164/255, 0, 0.95)
                                                   : Qt.rgba(245/255, 164/255, 0, 0.28)
                                            Text {
                                                anchors.centerIn: parent
                                                text: aiAssistant.streaming ? "回答中" : "发送"
                                                color: "#1A1B1D"
                                                font.family: root.uiFamily
                                                font.pixelSize: 14
                                                font.bold: true
                                            }
                                            MouseArea {
                                                anchors.fill: parent
                                                enabled: inputArea.text.trim() !== "" && !aiAssistant.streaming
                                                onClicked: {
                                                    aiAssistant.sendMessage(inputArea.text.trim())
                                                    inputArea.text = ""
                                                }
                                            }
                                        }
                                    }
                                }

                                Item {
                                    id: orbCenter
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: root.compact ? 180 : 220
                                    height: width

                                    readonly property int orbSize: root.compact ? 110 : 130

                                    Rectangle {
                                        id: ripple1
                                        anchors.centerIn: parent
                                        width: orbCenter.orbSize + 18 + aiPageRoot.vcLevel * 30
                                        height: width
                                        radius: width / 2
                                        color: "transparent"
                                        border.width: 2
                                        border.color: aiPageRoot.orbColor
                                        visible: aiPageRoot.vcRecording
                                        opacity: 0.0
                                        SequentialAnimation on opacity {
                                            running: aiPageRoot.vcRecording
                                            loops: Animation.Infinite
                                            NumberAnimation { to: 0.65; duration: 700; easing.type: Easing.OutQuad }
                                            NumberAnimation { to: 0.0; duration: 700; easing.type: Easing.InQuad }
                                        }
                                    }
                                    Rectangle {
                                        id: ripple2
                                        anchors.centerIn: parent
                                        width: orbCenter.orbSize + 38 + aiPageRoot.vcLevel * 50
                                        height: width
                                        radius: width / 2
                                        color: "transparent"
                                        border.width: 2
                                        border.color: aiPageRoot.orbColor
                                        visible: aiPageRoot.vcRecording
                                        opacity: 0.0
                                        SequentialAnimation on opacity {
                                            running: aiPageRoot.vcRecording
                                            loops: Animation.Infinite
                                            PauseAnimation { duration: 350 }
                                            NumberAnimation { to: 0.45; duration: 700; easing.type: Easing.OutQuad }
                                            NumberAnimation { to: 0.0; duration: 700; easing.type: Easing.InQuad }
                                        }
                                    }

                                    Canvas {
                                        id: scanArc
                                        anchors.centerIn: parent
                                        width: orbCenter.orbSize + 16
                                        height: width
                                        antialiasing: true
                                        visible: aiPageRoot.orbState === "thinking"
                                        property real rotAng: 0
                                        rotation: rotAng

                                        property color arcColor: aiPageRoot.orbColor
                                        onArcColorChanged: requestPaint()

                                        NumberAnimation on rotAng {
                                            running: scanArc.visible
                                            loops: Animation.Infinite
                                            from: 0
                                            to: 360
                                            duration: 1500
                                        }

                                        onPaint: {
                                            var ctx = getContext("2d")
                                            ctx.reset()
                                            var cx = width / 2, cy = height / 2
                                            var R = Math.min(cx, cy) - 3
                                            ctx.lineWidth = 3
                                            ctx.lineCap = "round"
                                            ctx.strokeStyle = arcColor
                                            ctx.beginPath()
                                            ctx.arc(cx, cy, R, -Math.PI / 2, -Math.PI / 2 + Math.PI / 2)
                                            ctx.stroke()
                                        }
                                    }

                                    Rectangle {
                                        id: heartGlow
                                        anchors.centerIn: parent
                                        width: orbCenter.orbSize + 24
                                        height: width
                                        radius: width / 2
                                        color: aiPageRoot.orbColor
                                        opacity: 0.0
                                        visible: aiPageRoot.orbState === "speaking"
                                        SequentialAnimation on opacity {
                                            running: aiPageRoot.orbState === "speaking"
                                            loops: Animation.Infinite
                                            NumberAnimation { to: 0.40; duration: 200; easing.type: Easing.OutQuad }
                                            NumberAnimation { to: 0.10; duration: 200; easing.type: Easing.InQuad }
                                            NumberAnimation { to: 0.35; duration: 200; easing.type: Easing.OutQuad }
                                            NumberAnimation { to: 0.0; duration: 200; easing.type: Easing.InQuad }
                                            PauseAnimation { duration: 200 }
                                        }
                                    }

                                    Rectangle {
                                        id: orbIdleBreath
                                        anchors.centerIn: parent
                                        width: orbCenter.orbSize + 14
                                        height: width
                                        radius: width / 2
                                        color: "transparent"
                                        border.width: 1
                                        border.color: aiPageRoot.orbColor
                                        visible: aiPageRoot.orbState === "idle"
                                        opacity: 0.0
                                        SequentialAnimation on opacity {
                                            running: aiPageRoot.orbState === "idle"
                                            loops: Animation.Infinite
                                            NumberAnimation { to: 0.45; duration: 2000; easing.type: Easing.InOutSine }
                                            NumberAnimation { to: 0.10; duration: 2000; easing.type: Easing.InOutSine }
                                        }
                                    }

                                    Rectangle {
                                        id: orb
                                        anchors.centerIn: parent
                                        width: orbCenter.orbSize
                                        height: width
                                        radius: width / 2
                                        color: {
                                            if (aiPageRoot.orbState === "listening") return Qt.rgba(0.84, 0.33, 0.31, 0.32)
                                            if (aiPageRoot.orbState === "speaking") return Qt.rgba(0.84, 0.83, 0.78, 0.22)
                                            if (aiPageRoot.orbState === "thinking") return Qt.rgba(0.96, 0.64, 0.0, 0.16)
                                            return Qt.rgba(38/255, 40/255, 42/255, 0.55)
                                        }
                                        border.width: aiPageRoot.orbState === "listening" || aiPageRoot.orbState === "speaking" ? 3 : 2
                                        border.color: aiPageRoot.orbColor
                                        Behavior on color { ColorAnimation { duration: 250 } }
                                        Behavior on border.color { ColorAnimation { duration: 250 } }

                                        Canvas {
                                            id: orbIcon
                                            anchors.centerIn: parent
                                            width: 44
                                            height: 44
                                            antialiasing: true
                                            property string stt: aiPageRoot.orbState
                                            property color tint: aiPageRoot.orbState === "listening" ? "#FFFFFF" : aiPageRoot.orbColor
                                            onSttChanged: requestPaint()
                                            onTintChanged: requestPaint()

                                            onPaint: {
                                                var ctx = getContext("2d")
                                                ctx.reset()
                                                ctx.lineCap = "round"
                                                ctx.lineJoin = "round"
                                                ctx.fillStyle = tint
                                                ctx.strokeStyle = tint
                                                ctx.lineWidth = 3
                                                var cx = width / 2, cy = height / 2

                                                if (stt === "thinking") {
                                                    ctx.beginPath()
                                                    ctx.arc(cx, cy, 14, 0, Math.PI * 2)
                                                    ctx.stroke()
                                                    for (var i = 0; i < 6; ++i) {
                                                        var a = i * Math.PI / 3
                                                        var r1 = 14, r2 = 20
                                                        ctx.beginPath()
                                                        ctx.moveTo(cx + Math.cos(a) * r1, cy + Math.sin(a) * r1)
                                                        ctx.lineTo(cx + Math.cos(a) * r2, cy + Math.sin(a) * r2)
                                                        ctx.stroke()
                                                    }
                                                    ctx.beginPath()
                                                    ctx.arc(cx, cy, 5, 0, Math.PI * 2)
                                                    ctx.fill()
                                                } else if (stt === "speaking") {
                                                    ctx.lineWidth = 4
                                                    for (var j = 0; j < 3; ++j) {
                                                        var off = (j - 1) * 8
                                                        var h = j === 1 ? 18 : 12
                                                        ctx.beginPath()
                                                        ctx.moveTo(cx + off, cy - h / 2)
                                                        ctx.lineTo(cx + off, cy + h / 2)
                                                        ctx.stroke()
                                                    }
                                                } else {
                                                    var capW = 14, capH = 18
                                                    var topY = cy - 14
                                                    ctx.beginPath()
                                                    ctx.moveTo(cx - capW / 2, topY + capW / 2)
                                                    ctx.arc(cx, topY + capW / 2, capW / 2, Math.PI, 2 * Math.PI)
                                                    ctx.lineTo(cx + capW / 2, topY + capH)
                                                    ctx.arc(cx, topY + capH, capW / 2, 0, Math.PI)
                                                    ctx.closePath()
                                                    ctx.fill()
                                                    ctx.lineWidth = 3
                                                    ctx.beginPath()
                                                    ctx.arc(cx, topY + capH - 2, capW / 2 + 6, 0, Math.PI)
                                                    ctx.stroke()
                                                    ctx.beginPath()
                                                    ctx.moveTo(cx, topY + capH + capW / 2 + 4)
                                                    ctx.lineTo(cx, topY + capH + capW / 2 + 12)
                                                    ctx.stroke()
                                                    ctx.beginPath()
                                                    ctx.moveTo(cx - 7, topY + capH + capW / 2 + 12)
                                                    ctx.lineTo(cx + 7, topY + capH + capW / 2 + 12)
                                                    ctx.stroke()
                                                }
                                            }

                                            Connections {
                                                target: aiPageRoot
                                                function onOrbStateChanged() { orbIcon.requestPaint() }
                                            }
                                        }
                                    }

                                    Text {
                                        anchors.top: orb.bottom
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        anchors.topMargin: 12
                                        text: aiPageRoot.orbHint
                                        color: aiPageRoot.orbColor
                                        font.family: root.uiFamily
                                        font.pixelSize: root.compact ? 13 : 14
                                        font.bold: true
                                        Behavior on color { ColorAnimation { duration: 200 } }
                                    }

                                    MouseArea {
                                        anchors.fill: parent
                                        enabled: !aiAssistant.streaming
                                        onPressed: {
                                            if (typeof voiceController === "undefined") return
                                            if (!voiceController.available) {
                                                console.log("VoiceController not available:", voiceController.statusText)
                                                return
                                            }
                                            voiceController.startRecording()
                                        }
                                        onReleased: {
                                            if (typeof voiceController === "undefined") return
                                            if (voiceController.recording) voiceController.stopRecording()
                                        }
                                        onCanceled: {
                                            if (typeof voiceController === "undefined") return
                                            if (voiceController.recording) voiceController.stopRecording()
                                        }
                                    }
                                }

                                Rectangle {
                                    id: kbCard
                                    anchors.right: parent.right
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: root.compact ? 110 : 130
                                    height: root.compact ? 150 : 170
                                    radius: 20
                                    color: aiPageRoot.keyboardExpanded
                                           ? Qt.rgba(245/255, 164/255, 0, 0.18)
                                           : root.glassPanel
                                    border.width: 1
                                    border.color: aiPageRoot.keyboardExpanded
                                                  ? Qt.rgba(245/255, 164/255, 0, 0.85)
                                                  : root.glassBorder
                                    Behavior on color { ColorAnimation { duration: 200 } }
                                    Behavior on border.color { ColorAnimation { duration: 200 } }

                                    Item {
                                        anchors.fill: parent
                                        anchors.margins: 14

                                        Canvas {
                                            id: kbIcon
                                            anchors.top: parent.top
                                            anchors.topMargin: 10
                                            anchors.horizontalCenter: parent.horizontalCenter
                                            width: 40
                                            height: 32
                                            antialiasing: true
                                            property color tint: aiPageRoot.keyboardExpanded ? root.accentBlue : root.pageText
                                            onTintChanged: requestPaint()
                                            onPaint: {
                                                var ctx = getContext("2d")
                                                ctx.reset()
                                                ctx.strokeStyle = tint
                                                ctx.fillStyle = tint
                                                ctx.lineWidth = 2
                                                ctx.lineCap = "round"
                                                var pad = 2
                                                ctx.beginPath()
                                                ctx.rect(pad, pad + 4, width - pad * 2, height - pad * 2 - 4)
                                                ctx.stroke()
                                                for (var r = 0; r < 2; ++r) {
                                                    for (var c = 0; c < 5; ++c) {
                                                        var bx = pad + 4 + c * ((width - pad * 2 - 8) / 5)
                                                        var by = pad + 4 + 4 + r * 7
                                                        ctx.fillRect(bx, by, 4, 3)
                                                    }
                                                }
                                                var lbx = pad + 6
                                                var lby = pad + 4 + 4 + 14
                                                ctx.fillRect(lbx, lby, width - pad * 2 - 12, 4)
                                            }
                                        }

                                        Column {
                                            anchors.bottom: parent.bottom
                                            anchors.bottomMargin: 6
                                            anchors.horizontalCenter: parent.horizontalCenter
                                            spacing: 2
                                            Text {
                                                text: aiPageRoot.keyboardExpanded ? "收起键盘" : "键盘输入"
                                                color: root.pageText
                                                font.family: root.uiFamily
                                                font.pixelSize: root.compact ? 12 : 13
                                                font.bold: true
                                                anchors.horizontalCenter: parent.horizontalCenter
                                            }
                                            Text {
                                                text: aiPageRoot.keyboardExpanded ? "点击收起" : "点击展开"
                                                color: root.softText
                                                font.family: root.uiFamily
                                                font.pixelSize: 11
                                                anchors.horizontalCenter: parent.horizontalCenter
                                            }
                                        }
                                    }

                                    MouseArea {
                                        anchors.fill: parent
                                        onClicked: aiPageRoot.keyboardExpanded = !aiPageRoot.keyboardExpanded
                                    }
                                }
                            }

                            Rectangle {
                                id: errorBar
                                anchors.bottom: voiceConsole.top
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.bottomMargin: aiPageRoot.keyboardExpanded ? (root.compact ? 80 : 90) : 6
                                Behavior on anchors.bottomMargin { NumberAnimation { duration: 240 } }
                                height: aiAssistant.hasError ? 40 : 0
                                visible: aiAssistant.hasError
                                radius: 12
                                color: Qt.rgba(215/255, 84/255, 80/255, 0.16)
                                border.width: 1
                                border.color: root.accentDanger
                                Behavior on height { NumberAnimation { duration: 200 } }

                                Row {
                                    anchors.fill: parent
                                    anchors.leftMargin: 12
                                    anchors.rightMargin: 12
                                    spacing: 10
                                    Text {
                                        text: "⚠"
                                        color: root.accentDanger
                                        font.pixelSize: 16
                                        anchors.verticalCenter: parent.verticalCenter
                                    }
                                    Text {
                                        text: aiAssistant.errorText
                                        color: root.pageText
                                        font.family: root.uiFamily
                                        font.pixelSize: 13
                                        elide: Text.ElideRight
                                        width: errorBar.width - 80
                                        anchors.verticalCenter: parent.verticalCenter
                                    }
                                }
                            }

                            ListView {
                                id: chatList
                                anchors.top: aiTopBar.bottom
                                anchors.bottom: errorBar.top
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.topMargin: root.compact ? 10 : 14
                                anchors.bottomMargin: 8
                                clip: true
                                spacing: root.compact ? 10 : 12
                                model: aiAssistant.messages
                                cacheBuffer: 200
                                boundsBehavior: Flickable.StopAtBounds

                                Component.onCompleted: chatList.positionViewAtEnd()
                                onCountChanged: {
                                    if (count > 0) chatList.positionViewAtEnd()
                                }

                                Connections {
                                    target: aiAssistant.messages
                                    function onDataChanged() {
                                        chatList.positionViewAtEnd()
                                    }
                                }

                                delegate: Item {
                                    id: msgDelegate
                                    width: chatList.width
                                    height: (isThinkingNow ? 44 : bubbleText.contentHeight + (root.compact ? 22 : 28)) + (root.compact ? 4 : 6)

                                    readonly property bool isUser: model.role === "user"
                                    readonly property bool isAssistant: model.role === "assistant"
                                    readonly property bool isErr: !!model.error
                                    readonly property bool isStreamingThisOne: isAssistant && aiAssistant.streaming && index === chatList.count - 1
                                    readonly property bool isThinkingNow: isStreamingThisOne && (!model.content || model.content.length === 0)
                                    readonly property real maxTextWidth: chatList.width * 0.65

                                    Canvas {
                                        id: assistantIcon
                                        visible: isAssistant && !isThinkingNow
                                        anchors.left: parent.left
                                        anchors.top: parent.top
                                        anchors.topMargin: 8
                                        width: 22
                                        height: 22
                                        antialiasing: true
                                        onPaint: {
                                            var ctx = getContext("2d")
                                            ctx.reset()
                                            ctx.strokeStyle = root.accentBlue
                                            ctx.fillStyle = root.accentBlue
                                            ctx.lineWidth = 1.5
                                            var cx = width / 2, cy = height / 2
                                            ctx.beginPath()
                                            ctx.arc(cx, cy, 8, 0, Math.PI * 2)
                                            ctx.stroke()
                                            for (var i = 0; i < 6; ++i) {
                                                var a = i * Math.PI / 3 + Math.PI / 6
                                                var r1 = 8, r2 = 10
                                                ctx.beginPath()
                                                ctx.moveTo(cx + Math.cos(a) * r1, cy + Math.sin(a) * r1)
                                                ctx.lineTo(cx + Math.cos(a) * r2, cy + Math.sin(a) * r2)
                                                ctx.stroke()
                                            }
                                            ctx.beginPath()
                                            ctx.arc(cx, cy, 2.5, 0, Math.PI * 2)
                                            ctx.fill()
                                        }
                                    }

                                    Rectangle {
                                        id: bubbleBg
                                        anchors.top: parent.top
                                        anchors.left: isUser ? undefined : assistantIcon.right
                                        anchors.leftMargin: isUser ? 0 : 6
                                        anchors.right: isUser ? parent.right : undefined
                                        width: isThinkingNow
                                               ? 76
                                               : bubbleText.width + (root.compact ? 24 : 32) + (isStreamingThisOne ? 14 : 0)
                                        height: isThinkingNow
                                                ? 40
                                                : bubbleText.contentHeight + (root.compact ? 18 : 22)
                                        radius: root.compact ? 14 : 16
                                        color: isErr ? Qt.rgba(215/255, 84/255, 80/255, 0.16)
                                              : isUser ? root.accentBlue
                                              : root.glassPanel
                                        border.width: 1
                                        border.color: isErr ? root.accentDanger
                                                     : isUser ? Qt.rgba(245/255, 164/255, 0, 1.0)
                                                     : root.glassBorder

                                        Item {
                                            id: thinkingDots
                                            visible: isThinkingNow
                                            anchors.centerIn: parent
                                            width: 56
                                            height: 14
                                            Row {
                                                anchors.centerIn: parent
                                                spacing: 8
                                                Repeater {
                                                    model: 3
                                                    delegate: Rectangle {
                                                        width: 8
                                                        height: 8
                                                        radius: 4
                                                        color: root.accentBlue
                                                        opacity: 0.3
                                                        SequentialAnimation on opacity {
                                                            running: thinkingDots.visible
                                                            loops: Animation.Infinite
                                                            PauseAnimation { duration: index * 200 }
                                                            NumberAnimation { to: 1.0; duration: 400; easing.type: Easing.InOutSine }
                                                            NumberAnimation { to: 0.3; duration: 400; easing.type: Easing.InOutSine }
                                                            PauseAnimation { duration: (2 - index) * 200 }
                                                        }
                                                    }
                                                }
                                            }
                                        }

                                        Text {
                                            id: bubbleText
                                            visible: !isThinkingNow
                                            anchors.left: parent.left
                                            anchors.top: parent.top
                                            anchors.leftMargin: root.compact ? 12 : 16
                                            anchors.topMargin: root.compact ? 9 : 11
                                            text: model.content || ""
                                            color: isErr ? root.accentDanger
                                                  : isUser ? "#1A1B1D"
                                                  : root.pageText
                                            font.family: root.uiFamily
                                            font.pixelSize: root.compact ? 14 : 16
                                            wrapMode: Text.Wrap
                                            width: Math.min(implicitWidth + 2, msgDelegate.maxTextWidth)
                                        }

                                        Text {
                                            visible: isStreamingThisOne && !isThinkingNow
                                            anchors.left: bubbleText.right
                                            anchors.baseline: bubbleText.baseline
                                            anchors.baselineOffset: 0
                                            text: "▎"
                                            color: root.accentBlue
                                            font.family: root.uiFamily
                                            font.pixelSize: root.compact ? 14 : 16
                                            font.bold: true
                                            SequentialAnimation on opacity {
                                                running: isStreamingThisOne
                                                loops: Animation.Infinite
                                                NumberAnimation { to: 0.0; duration: 500 }
                                                NumberAnimation { to: 1.0; duration: 500 }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

            }
        }

        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true

            RowLayout {
                anchors.fill: parent
                spacing: root.compact ? 14 : 18
                visible: root.activeNavIndex !== 1
                enabled: visible

                Item {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    Layout.minimumWidth: 640

                    Rectangle {
                        anchors.fill: carPanel
                        anchors.topMargin: 14
                        radius: carPanel.radius
                        color: root.shadowTint
                    }

                    Rectangle {
                        id: carPanel
                        anchors.fill: parent
                        radius: root.compact ? 30 : 34
                        color: root.glassPanel
                        border.width: 1
                        border.color: root.glassBorder
                        clip: true

                        Rectangle {
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.top: parent.top
                            height: parent.height * 0.46
                            radius: parent.radius
                            gradient: Gradient {
                                GradientStop { position: 0.0; color: Qt.rgba(1, 1, 1, 0.16) }
                                GradientStop { position: 1.0; color: Qt.rgba(245 / 255, 164 / 255, 0, 0.035) }
                            }
                        }

                        Item {
                            id: car3DHolder
                            anchors.fill: parent
                            anchors.margins: root.compact ? 14 : 22

                            property real manualYaw: -25
                            property real manualPitch: -8
                            property real displayYaw: root.homePageActive && root.imu3DLinked && imuService.available
                                                      ? -25 + imuService.yawCue : manualYaw
                            property real displayPitch: root.homePageActive && root.imu3DLinked && imuService.available
                                                        ? -8 + imuService.pitch : manualPitch
                            property real displayRoll: root.homePageActive && root.imu3DLinked && imuService.available
                                                       ? imuService.roll : 0

                            Behavior on displayYaw { NumberAnimation { duration: 90; easing.type: Easing.OutQuad } }
                            Behavior on displayPitch { NumberAnimation { duration: 90; easing.type: Easing.OutQuad } }
                            Behavior on displayRoll { NumberAnimation { duration: 90; easing.type: Easing.OutQuad } }

                            // Mali blob 对 size 还是 0 / 负值的 framebuffer 创建会留下损坏状态，
                            // 之后 size 变正也不会刷新——SceneLoader 加载的几何就静默不显示。
                            // 用 Loader 守一下，等父 Item size 稳定再实例化 Scene3D。阈值取 100。
                            Loader {
                                anchors.fill: parent
                                active: parent.width > 100 && parent.height > 100
                                sourceComponent: scene3dComponent
                            }

                            Component {
                                id: scene3dComponent

                                Scene3D {
                                    id: carScene3D
                                    anchors.fill: parent
                                    focus: false
                                    aspects: ["input", "logic"]
                                    cameraAspectRatioMode: Scene3D.AutomaticAspectRatio
                                    // Mali blob 对 MSAA framebuffer 渲染有 bug，Scene3D 内部
                                    // 开 multisample 会让车模型静默不显示。关掉之后能正常出图。
                                    multisample: false

                                    Entity {
                                        id: carSceneRoot

                                        Camera {
                                            id: carCamera
                                            projectionType: CameraLens.PerspectiveProjection
                                            fieldOfView: 30
                                            nearPlane: 0.1
                                            farPlane: 1000.0
                                            position: Qt.vector3d(0.0, 1.6, 6.0)
                                            upVector: Qt.vector3d(0, 1, 0)
                                            viewCenter: Qt.vector3d(0, 0.3, 0)
                                        }

                                        components: [
                                            RenderSettings {
                                                activeFrameGraph: ForwardRenderer {
                                                    camera: carCamera
                                                    clearColor: Qt.rgba(0, 0, 0, 0)
                                                }
                                                renderPolicy: RenderSettings.OnDemand
                                            },
                                            InputSettings { }
                                        ]

                                        Entity {
                                            components: [
                                                DirectionalLight {
                                                    worldDirection: Qt.vector3d(-0.35, -0.8, -0.55)
                                                    color: "#FFE4A8"
                                                    intensity: 1.0
                                                }
                                            ]
                                        }

                                        Entity {
                                            components: [
                                                DirectionalLight {
                                                    worldDirection: Qt.vector3d(0.6, -0.3, 0.45)
                                                    color: "#A8C8F0"
                                                    intensity: 0.55
                                                }
                                            ]
                                        }

                                        Entity {
                                            id: carEntity
                                            components: [
                                                SceneLoader {
                                                    id: carLoader
                                                    source: carModelUrl
                                                },
                                                Transform {
                                                    id: carTransform
                                                    scale: 1.6
                                                    rotation: carTransform.fromAxesAndAngles(
                                                        Qt.vector3d(0, 1, 0), car3DHolder.displayYaw,
                                                        Qt.vector3d(1, 0, 0), car3DHolder.displayPitch,
                                                        Qt.vector3d(0, 0, 1), car3DHolder.displayRoll)
                                                    translation: Qt.vector3d(0, -1.0, 0)
                                                }
                                            ]
                                        }
                                    }
                                }
                            }

                            MouseArea {
                                anchors.fill: parent
                                property real lastX: 0
                                property real lastY: 0
                                preventStealing: true
                                enabled: !(root.imu3DLinked && imuService.available)
                                cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
                                onPressed: {
                                    lastX = mouseX
                                    lastY = mouseY
                                }
                                onPositionChanged: {
                                    car3DHolder.manualYaw += (mouseX - lastX) * 0.5
                                    car3DHolder.manualPitch = Math.max(-25, Math.min(20, car3DHolder.manualPitch + (mouseY - lastY) * 0.3))
                                    lastX = mouseX
                                    lastY = mouseY
                                }
                                onDoubleClicked: {
                                    car3DHolder.manualYaw = -25
                                    car3DHolder.manualPitch = -8
                                }
                            }
                        }

                    ColumnLayout {
                        anchors.left: parent.left
                        anchors.top: parent.top
                        anchors.leftMargin: root.compact ? 22 : 28
                        anchors.topMargin: root.compact ? 20 : 26
                        width: parent.width * 0.42
                        spacing: 6

                        Text {
                            Layout.fillWidth: true
                            text: "智能座舱首页"
                            color: root.pageText
                            font.family: root.uiFamily
                            font.pixelSize: root.compact ? 22 : 28
                            font.bold: true
                            elide: Text.ElideRight
                        }

                        Text {
                            Layout.fillWidth: true
                            text: "车辆状态 · 疲劳监测 · 环境感知"
                            color: root.mutedText
                            font.family: root.uiFamily
                            font.pixelSize: root.compact ? 12 : 14
                            elide: Text.ElideRight
                        }
                    }

                }
            }

            Item {
                Layout.preferredWidth: root.compact ? 300 : 338
                Layout.maximumWidth: root.compact ? 300 : 338
                Layout.fillHeight: true

                Rectangle {
                    anchors.fill: rightPanel
                    anchors.topMargin: 12
                    radius: rightPanel.radius
                    color: root.shadowTint
                }

                Rectangle {
                    id: rightPanel
                    anchors.fill: parent
                    radius: root.compact ? 28 : 32
                    color: root.glassPanel
                    border.width: 1
                    border.color: root.glassBorder

                    Flickable {
                        id: rightScroll
                        anchors.fill: parent
                        anchors.margins: root.compact ? 14 : 18
                        contentWidth: width
                        contentHeight: rightColumn.implicitHeight
                        clip: true
                        boundsBehavior: Flickable.StopAtBounds
                        flickableDirection: Flickable.VerticalFlick
                        ScrollBar.vertical: ScrollBar {
                            policy: ScrollBar.AsNeeded
                        }

                        ColumnLayout {
                            id: rightColumn
                            width: rightScroll.width
                            spacing: root.compact ? 10 : 12

                        Rectangle {
                            Layout.fillWidth: true
                            Layout.preferredHeight: root.compact ? 130 : 148
                            radius: 22
                            color: root.glassStrong
                            border.width: 1
                            border.color: root.glassBorder

                            RowLayout {
                                anchors.fill: parent
                                anchors.margins: root.compact ? 14 : 16
                                spacing: 14

                                Item {
                                    Layout.preferredWidth: root.compact ? 96 : 112
                                    Layout.fillHeight: true

                                    Canvas {
                                        id: miniRiskCanvas
                                        anchors.fill: parent
                                        antialiasing: true
                                        renderStrategy: Canvas.Threaded

                                        property real frac: root.fatigueFrac
                                        property color arcColor: root.fatigueColor(root.fatigueStatusKey)
                                        property bool live: fatigueService.connected && fatigueService.cameraEnabled
                                        onFracChanged: requestPaint()
                                        onArcColorChanged: requestPaint()
                                        onLiveChanged: requestPaint()

                                        onPaint: {
                                            var ctx = getContext("2d")
                                            var w = width
                                            var h = height
                                            var cx = w / 2
                                            var cy = h / 2
                                            var r = Math.min(w, h) * 0.42
                                            var start = Math.PI * 0.78
                                            var end = Math.PI * 2.22
                                            var progress = start + (end - start) * frac
                                            ctx.clearRect(0, 0, w, h)
                                            ctx.lineWidth = Math.max(10, r * 0.22)
                                            ctx.lineCap = "round"
                                            ctx.beginPath()
                                            ctx.arc(cx, cy, r, start, end)
                                            ctx.strokeStyle = "rgba(255,255,255,0.14)"
                                            ctx.stroke()
                                            if (live && frac > 0) {
                                                ctx.beginPath()
                                                ctx.arc(cx, cy, r, start, progress)
                                                ctx.strokeStyle = arcColor
                                                ctx.stroke()
                                            }
                                        }

                                        Component.onCompleted: requestPaint()
                                        onWidthChanged: requestPaint()
                                        onHeightChanged: requestPaint()
                                    }

                                    Text {
                                        anchors.centerIn: parent
                                        text: fatigueService.connected && fatigueService.cameraEnabled
                                              ? Math.round(fatigueService.perclos * 100) + "%"
                                              : "—"
                                        color: root.fatigueColor(root.fatigueStatusKey)
                                        font.family: root.uiFamily
                                        font.pixelSize: fatigueService.connected && fatigueService.cameraEnabled
                                                        ? (root.compact ? 24 : 30)
                                                        : (root.compact ? 30 : 38)
                                        font.bold: true
                                    }
                                }

                                ColumnLayout {
                                    Layout.fillWidth: true
                                    Layout.alignment: Qt.AlignVCenter
                                    spacing: 6

                                    RowLayout {
                                        Layout.fillWidth: true
                                        spacing: 6
                                        Text {
                                            text: "实时疲劳监测"
                                            color: root.pageText
                                            font.family: root.uiFamily
                                            font.pixelSize: root.compact ? 15 : 17
                                            font.bold: true
                                            elide: Text.ElideRight
                                            Layout.fillWidth: true
                                        }
                                        Rectangle {
                                            width: 8; height: 8; radius: 4
                                            Layout.alignment: Qt.AlignVCenter
                                            color: !fatigueService.connected ? root.accentDanger
                                                   : (fatigueService.cameraEnabled
                                                      ? root.accentGreen : root.softText)
                                        }
                                    }

                                    Text {
                                        Layout.fillWidth: true
                                        text: fatigueService.cameraState === "error"
                                              && fatigueService.cameraError.length > 0
                                              ? fatigueService.cameraError
                                              : fatigueService.fatigueAlarm && fatigueService.fatigueReason.length > 0
                                              ? fatigueService.fatigueReason
                                              : root.fatigueText(root.fatigueStatusKey)
                                        color: root.fatigueColor(root.fatigueStatusKey)
                                        font.family: root.uiFamily
                                        font.pixelSize: root.compact ? 11 : 13
                                        elide: Text.ElideRight
                                    }

                                    ProgressBar {
                                        id: riskBar
                                        Layout.fillWidth: true
                                        Layout.preferredHeight: 10
                                        from: 0
                                        to: 100
                                        value: fatigueService.cameraEnabled ? root.fatigueFrac * 100 : 0

                                        background: Rectangle {
                                            implicitHeight: 10
                                            radius: 5
                                            color: Qt.rgba(1, 1, 1, 0.12)
                                        }

                                        contentItem: Item {
                                            implicitHeight: 10

                                            Rectangle {
                                                width: riskBar.visualPosition * parent.width
                                                height: parent.height
                                                radius: height / 2
                                                gradient: Gradient {
                                                    orientation: Gradient.Horizontal
                                                    GradientStop { position: 0.0; color: root.accentCyan }
                                                    GradientStop { position: 0.50; color: root.accentBlue }
                                                    GradientStop { position: 1.0; color: root.accentOrange }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        Rectangle {
                            id: imuOverviewCard
                            Layout.fillWidth: true
                            Layout.preferredHeight: root.compact ? 112 : 126
                            radius: 22
                            color: Qt.rgba(38 / 255, 40 / 255, 42 / 255, 0.64)
                            border.width: 1
                            border.color: imuService.available
                                          ? Qt.rgba(245 / 255, 164 / 255, 0, 0.42)
                                          : root.glassBorder

                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    root.activeNavIndex = 1
                                    root.functionPage = "imu"
                                }
                            }

                            ColumnLayout {
                                anchors.fill: parent
                                anchors.margins: root.compact ? 13 : 15
                                spacing: 8

                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 8
                                    Text {
                                        text: root.mdi("F0D91")
                                        color: root.accentBlue
                                        font.family: root.iconFamily
                                        font.pixelSize: root.compact ? 22 : 25
                                    }
                                    Text {
                                        Layout.fillWidth: true
                                        text: "车辆姿态与行驶质量"
                                        color: root.pageText
                                        font.family: root.uiFamily
                                        font.pixelSize: root.compact ? 14 : 16
                                        font.bold: true
                                        elide: Text.ElideRight
                                    }
                                    Rectangle {
                                        id: imuCardLinkSwitch
                                        Layout.preferredWidth: root.compact ? 82 : 92
                                        Layout.preferredHeight: root.compact ? 32 : 34
                                        Layout.alignment: Qt.AlignVCenter
                                        radius: height / 2
                                        color: root.imu3DLinked
                                               ? Qt.rgba(245 / 255, 164 / 255, 0, 0.18)
                                               : Qt.rgba(1, 1, 1, 0.055)
                                        border.width: 1
                                        border.color: root.imu3DLinked
                                                      ? Qt.rgba(245 / 255, 164 / 255, 0, 0.72)
                                                      : root.glassBorder

                                        Text {
                                            anchors.centerIn: parent
                                            text: root.imu3DLinked ? "联动" : "自由"
                                            color: root.imu3DLinked ? root.accentOrange : root.mutedText
                                            font.family: root.uiFamily
                                            font.pixelSize: root.compact ? 10 : 11
                                            font.bold: true
                                        }

                                        Rectangle {
                                            width: root.compact ? 20 : 22
                                            height: width
                                            radius: width / 2
                                            anchors.verticalCenter: parent.verticalCenter
                                            x: root.imu3DLinked ? parent.width - width - 6 : 6
                                            color: root.imu3DLinked ? root.accentOrange : Qt.rgba(1, 1, 1, 0.34)
                                            border.width: 1
                                            border.color: root.imu3DLinked
                                                          ? Qt.rgba(1, 1, 1, 0.32)
                                                          : Qt.rgba(1, 1, 1, 0.16)
                                            Behavior on x { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
                                            Behavior on color { ColorAnimation { duration: 160 } }
                                        }

                                        MouseArea {
                                            anchors.fill: parent
                                            anchors.margins: -6
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: root.imu3DLinked = !root.imu3DLinked
                                        }
                                    }
                                }

                                RowLayout {
                                    Layout.fillWidth: true
                                    Layout.fillHeight: true
                                    spacing: 8
                                    Repeater {
                                        model: [
                                            { label: "驾驶评分", value: imuService.available ? imuService.drivingScore : "—" },
                                            { label: "平稳度", value: imuService.available ? imuService.smoothnessScore : "—" },
                                            { label: "状态", value: imuService.available ? imuService.motionState : "离线" }
                                        ]
                                        delegate: Column {
                                            Layout.fillWidth: true
                                            Layout.alignment: Qt.AlignVCenter
                                            spacing: 2
                                            Text {
                                                anchors.horizontalCenter: parent.horizontalCenter
                                                text: modelData.value
                                                color: root.pageText
                                                font.family: root.uiFamily
                                                font.pixelSize: modelData.label === "状态"
                                                                ? (root.compact ? 13 : 15)
                                                                : (root.compact ? 20 : 23)
                                                font.bold: true
                                            }
                                            Text {
                                                anchors.horizontalCenter: parent.horizontalCenter
                                                text: modelData.label
                                                color: root.mutedText
                                                font.family: root.uiFamily
                                                font.pixelSize: root.compact ? 10 : 11
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        Rectangle {
                            Layout.fillWidth: true
                            Layout.preferredHeight: root.compact ? 118 : 132
                            radius: 22
                            color: Qt.rgba(38 / 255, 40 / 255, 42 / 255, 0.60)
                            border.width: 1
                            border.color: root.glassBorder
                            clip: true

                            Rectangle {
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.bottom: parent.bottom
                                height: parent.height * 0.52
                                radius: parent.radius
                                gradient: Gradient {
                                    GradientStop { position: 0.0; color: Qt.rgba(245 / 255, 164 / 255, 0, 0.02) }
                                    GradientStop { position: 1.0; color: Qt.rgba(1, 1, 1, 0.12) }
                                }
                            }

                            Canvas {
                                anchors.fill: parent
                                anchors.margins: 1
                                antialiasing: true
                                renderStrategy: Canvas.Threaded

                                onPaint: {
                                    var ctx = getContext("2d")
                                    var w = width
                                    var h = height
                                    ctx.clearRect(0, 0, w, h)
                                    ctx.beginPath()
                                    ctx.moveTo(0, h * 0.66)
                                    ctx.bezierCurveTo(w * 0.20, h * 0.52, w * 0.36, h * 0.82, w * 0.52, h * 0.66)
                                    ctx.bezierCurveTo(w * 0.68, h * 0.50, w * 0.82, h * 0.76, w, h * 0.58)
                                    ctx.lineTo(w, h)
                                    ctx.lineTo(0, h)
                                    ctx.closePath()
                                    var g = ctx.createLinearGradient(0, h * 0.48, w, h)
                                    g.addColorStop(0, "rgba(245,164,0,0.08)")
                                    g.addColorStop(0.55, "rgba(255,255,255,0.11)")
                                    g.addColorStop(1, "rgba(255,255,255,0.18)")
                                    ctx.fillStyle = g
                                    ctx.fill()
                                }

                                Component.onCompleted: requestPaint()
                                onWidthChanged: requestPaint()
                                onHeightChanged: requestPaint()
                            }

                            ColumnLayout {
                                anchors.fill: parent
                                anchors.margins: root.compact ? 14 : 16
                                spacing: 8

                                Text {
                                    Layout.fillWidth: true
                                    text: "座舱环境"
                                    color: root.pageText
                                    font.family: root.uiFamily
                                    font.pixelSize: root.compact ? 14 : 16
                                    font.bold: true
                                    elide: Text.ElideRight
                                }

                                RowLayout {
                                    Layout.fillWidth: true
                                    Layout.fillHeight: true
                                    spacing: 10

                                    Repeater {
                                        model: [
                                            { label: "温度", kind: "temp", tone: root.accentBlue },
                                            { label: "湿度", kind: "humid", tone: root.accentCyan }
                                        ]

                                        delegate: Rectangle {
                                            Layout.fillWidth: true
                                            Layout.fillHeight: true
                                            radius: 16
                                            color: Qt.rgba(38 / 255, 40 / 255, 42 / 255, 0.46)
                                            border.width: 1
                                            border.color: Qt.rgba(1, 1, 1, 0.22)

                                            Column {
                                                anchors.centerIn: parent
                                                spacing: 2

                                                Text {
                                                    anchors.horizontalCenter: parent.horizontalCenter
                                                    text: modelData.label
                                                    color: modelData.tone
                                                    font.family: root.uiFamily
                                                    font.pixelSize: root.compact ? 12 : 14
                                                    font.bold: true
                                                }

                                                Text {
                                                    anchors.horizontalCenter: parent.horizontalCenter
                                                    text: {
                                                        if (!sensorService.cabinValid) return "—"
                                                        if (modelData.kind === "temp")
                                                            return sensorService.cabinTemperature.toFixed(1) + "°C"
                                                        return sensorService.cabinHumidity.toFixed(0) + "%"
                                                    }
                                                    color: root.pageText
                                                    font.family: root.uiFamily
                                                    font.pixelSize: root.compact ? 22 : 26
                                                    font.bold: true
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        Repeater {
                            model: [
                                { glyph: "F05A8", label: "环境光照", kind: "lux", tone: root.accentOrange },
                                { glyph: "F050F", label: "驾驶员体温", kind: "bodyTemp", tone: root.accentGreen }
                            ]

                            delegate: Rectangle {
                                Layout.fillWidth: true
                                // 环境光照卡片底部多一行"自动调节亮度"开关，所以更高。
                                Layout.preferredHeight: modelData.kind === "lux"
                                                        ? (root.compact ? 128 : 146)
                                                        : (root.compact ? 80 : 92)
                                radius: 20
                                color: Qt.rgba(38 / 255, 40 / 255, 42 / 255, 0.58)
                                border.width: 1
                                border.color: root.glassBorder

                                ColumnLayout {
                                    anchors.fill: parent
                                    anchors.margins: root.compact ? 12 : 14
                                    spacing: root.compact ? 8 : 10

                                    RowLayout {
                                        Layout.fillWidth: true
                                        Layout.fillHeight: true
                                        spacing: 14

                                        Rectangle {
                                            Layout.preferredWidth: root.compact ? 48 : 56
                                            Layout.preferredHeight: root.compact ? 48 : 56
                                            radius: 14
                                            color: Qt.rgba(1, 1, 1, 0.08)
                                            border.width: 1
                                            border.color: Qt.rgba(1, 1, 1, 0.22)

                                            Text {
                                                anchors.centerIn: parent
                                                text: root.mdi(modelData.glyph)
                                                color: modelData.tone
                                                font.family: root.iconFamily
                                                font.pixelSize: root.compact ? 24 : 28
                                            }
                                        }

                                        ColumnLayout {
                                            Layout.fillWidth: true
                                            Layout.alignment: Qt.AlignVCenter
                                            spacing: 2

                                            Text {
                                                Layout.fillWidth: true
                                                text: modelData.label
                                                color: root.mutedText
                                                font.family: root.uiFamily
                                                font.pixelSize: root.compact ? 12 : 14
                                                elide: Text.ElideRight
                                            }

                                            Text {
                                                Layout.fillWidth: true
                                                text: {
                                                    if (modelData.kind === "lux") {
                                                        if (!sensorService.ambientValid) return "—"
                                                        return Math.round(sensorService.ambientLux) + " lx"
                                                    }
                                                    if (!sensorService.driverValid) return "—"
                                                    return sensorService.driverTemperature.toFixed(1) + "°C"
                                                }
                                                color: root.pageText
                                                font.family: root.uiFamily
                                                font.pixelSize: root.compact ? 22 : 26
                                                font.bold: true
                                                elide: Text.ElideRight
                                            }
                                        }
                                    }

                                    // 仅环境光照卡片：独占一行的"自动调节亮度"开关，醒目可点。
                                    RowLayout {
                                        visible: modelData.kind === "lux"
                                        Layout.fillWidth: true
                                        spacing: 10

                                        Text {
                                            Layout.fillWidth: true
                                            text: "自动调节亮度"
                                            color: root.pageText
                                            font.family: root.uiFamily
                                            font.pixelSize: root.compact ? 13 : 15
                                            elide: Text.ElideRight
                                        }

                                        Text {
                                            visible: !brightnessController.available
                                            text: "不可用"
                                            color: root.softText
                                            font.family: root.uiFamily
                                            font.pixelSize: root.compact ? 11 : 12
                                        }

                                        Switch {
                                            id: autoLuxSwitch
                                            Layout.preferredWidth: root.compact ? 46 : 52
                                            Layout.preferredHeight: root.compact ? 26 : 28
                                            padding: 0
                                            enabled: brightnessController.available
                                            opacity: brightnessController.available ? 1.0 : 0.45
                                            checked: brightnessController.autoMode
                                            onToggled: brightnessController.autoMode = checked
                                            Accessible.name: "自动调节亮度"

                                            indicator: Rectangle {
                                                anchors.fill: parent
                                                radius: height / 2
                                                color: autoLuxSwitch.checked
                                                       ? Qt.rgba(245 / 255, 164 / 255, 0, 0.28)
                                                       : Qt.rgba(1, 1, 1, 0.10)
                                                border.width: 1
                                                border.color: autoLuxSwitch.checked
                                                              ? root.accentBlue
                                                              : root.glassBorder
                                                Behavior on color { ColorAnimation { duration: 140 } }

                                                Rectangle {
                                                    x: autoLuxSwitch.checked ? parent.width - width - 3 : 3
                                                    anchors.verticalCenter: parent.verticalCenter
                                                    width: parent.height - 6
                                                    height: parent.height - 6
                                                    radius: height / 2
                                                    color: autoLuxSwitch.checked ? root.accentBlue : root.mutedText
                                                    Behavior on x { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
                                                    Behavior on color { ColorAnimation { duration: 140 } }
                                                }
                                            }
                                            contentItem: Item {}
                                        }
                                    }
                                }
                            }
                        }

                        }
                    }
                }
            }

            }

            Item {
                anchors.fill: parent
                visible: root.activeNavIndex === 1
                enabled: visible

                Rectangle {
                    anchors.fill: functionPanel
                    anchors.topMargin: 14
                    radius: functionPanel.radius
                    color: root.shadowTint
                    visible: root.functionPage === "grid"
                }

                Rectangle {
                    id: functionPanel
                    anchors.fill: parent
                    radius: root.compact ? 30 : 34
                    color: root.glassPanel
                    border.width: 1
                    border.color: root.glassBorder
                    clip: true
                    visible: root.functionPage === "grid"

                    ColumnLayout {
                        anchors.fill: parent
                        anchors.margins: root.compact ? 28 : 36
                        spacing: root.compact ? 22 : 30

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 6

                            Text {
                                Layout.fillWidth: true
                                text: "功能应用"
                                color: root.pageText
                                font.family: root.uiFamily
                                font.pixelSize: root.compact ? 24 : 30
                                font.bold: true
                                elide: Text.ElideRight
                            }

                        }

                        Flickable {
                            id: functionGridFlickable
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            clip: true
                            contentWidth: width
                            contentHeight: functionGridContent.implicitHeight + root.navReserve
                            boundsBehavior: Flickable.DragOverBounds
                            flickableDirection: Flickable.VerticalFlick
                            interactive: contentHeight > height
                            readonly property int bottomPadding: root.navReserve

                            ScrollBar.vertical: ScrollBar {
                                policy: functionGridFlickable.contentHeight > functionGridFlickable.height
                                        ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
                            }

                            Item {
                                id: functionGridContent
                                width: functionGridFlickable.width
                                implicitHeight: functionGrid.implicitHeight

                                GridLayout {
                                    id: functionGrid
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    columns: root.width < 1120 ? 4 : 7
                                    columnSpacing: root.compact ? 18 : 26
                                    rowSpacing: root.compact ? 22 : 30

                                    Repeater {
                                        model: functionApps

                                        delegate: Button {
                                            id: appButton
                                            Layout.preferredWidth: root.compact ? 118 : 132
                                            Layout.preferredHeight: root.compact ? 144 : 164
                                            hoverEnabled: true
                                            focusPolicy: Qt.StrongFocus
                                            Accessible.name: model.label + "软件入口"
                                            ToolTip.visible: hovered
                                            ToolTip.delay: 500
                                            ToolTip.text: model.label
                                            onClicked: {
                                                if (model.label === "摄像头") {
                                                    root.functionPage = "camera"
                                                } else if (model.label === "天气") {
                                                    root.functionPage = "weather"
                                                } else if (model.label === "视频播放器") {
                                                    root.functionPage = "video"
                                                } else if (model.label === "音乐播放器") {
                                                    root.functionPage = "music"
                                                } else if (model.label === "AI智能助手") {
                                                    root.functionPage = "ai"
                                                } else if (model.label === "温度湿度") {
                                                    root.functionPage = "thermo"
                                                } else if (model.label === "人体体温") {
                                                    root.functionPage = "bodytemp"
                                                } else if (model.label === "屏幕亮度") {
                                                    root.functionPage = "brightness"
                                                } else if (model.label === "车辆姿态") {
                                                    root.functionPage = "imu"
                                                }
                                            }

                                            background: Rectangle {
                                                radius: 24
                                                color: appButton.down
                                                       ? Qt.rgba(245 / 255, 164 / 255, 0, 0.12)
                                                       : appButton.hovered || appButton.activeFocus
                                                         ? Qt.rgba(1, 1, 1, 0.08)
                                                         : "transparent"
                                                border.width: appButton.activeFocus ? 1 : 0
                                                border.color: Qt.rgba(245 / 255, 164 / 255, 0, 0.50)

                                                Behavior on color {
                                                    ColorAnimation { duration: 120 }
                                                }
                                            }

                                            contentItem: ColumnLayout {
                                                spacing: root.compact ? 10 : 12

                                                Item {
                                                    Layout.alignment: Qt.AlignHCenter
                                                    Layout.preferredWidth: root.compact ? 74 : 86
                                                    Layout.preferredHeight: root.compact ? 74 : 86

                                                    Rectangle {
                                                        anchors.fill: iconFace
                                                        anchors.topMargin: appButton.down ? 5 : 8
                                                        radius: iconFace.radius
                                                        color: Qt.rgba(0, 0, 0, 0.34)
                                                    }

                                                    Rectangle {
                                                        id: iconFace
                                                        anchors.fill: parent
                                                        anchors.margins: appButton.down ? 3 : 0
                                                        radius: root.compact ? 21 : 24
                                                        border.width: 1
                                                        border.color: appButton.hovered || appButton.down
                                                                      ? Qt.rgba(245 / 255, 164 / 255, 0, 0.42)
                                                                      : Qt.rgba(1, 1, 1, 0.20)
                                                        gradient: Gradient {
                                                            GradientStop { position: 0.0; color: model.top }
                                                            GradientStop { position: 1.0; color: model.bottom }
                                                        }

                                                        Rectangle {
                                                            anchors.left: parent.left
                                                            anchors.right: parent.right
                                                            anchors.top: parent.top
                                                            anchors.margins: 10
                                                            height: 1
                                                            color: Qt.rgba(1, 1, 1, 0.24)
                                                        }

                                                        Text {
                                                            anchors.centerIn: parent
                                                            text: root.mdi(model.glyph)
                                                            color: model.accent
                                                            font.family: root.iconFamily
                                                            font.pixelSize: root.compact ? 28 : 32
                                                        }
                                                    }
                                                }

                                                Text {
                                                    Layout.fillWidth: true
                                                    text: model.label
                                                    color: root.pageText
                                                    font.family: root.uiFamily
                                                    font.pixelSize: root.compact ? 13 : 15
                                                    font.bold: true
                                                    horizontalAlignment: Text.AlignHCenter
                                                    elide: Text.ElideRight
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                Component {
                    id: thermoPageComponent

                    Item {
                        id: thermoPageRoot
                        anchors.fill: parent

                        readonly property real currentTemp: sensorService.cabinValid ? sensorService.cabinTemperature : NaN
                        readonly property real currentHumidity: sensorService.cabinValid ? sensorService.cabinHumidity : NaN

                        function dewPoint(T, RH) {
                            var b = 17.625, c = 243.04
                            var gamma = Math.log(RH / 100) + b * T / (c + T)
                            return c * gamma / (b - gamma)
                        }
                        function apparentTemp(T, RH) {
                            return T - (0.55 - 0.0055 * RH) * (T - 14.5)
                        }
                        function comfortScore(T, RH) {
                            var tp = Math.abs(T - 22) * 3
                            var hp = Math.max(0, Math.abs(RH - 50) - 10) * 0.6
                            return Math.max(0, Math.min(100, Math.round(100 - tp - hp)))
                        }
                        function comfortGrade(s) {
                            if (s >= 85) return "优秀"
                            if (s >= 70) return "良好"
                            if (s >= 50) return "一般"
                            return "较差"
                        }
                        function advice(T, RH) {
                            if (T < 16) return "温度偏低，建议提高空调温度"
                            if (T > 30) return "温度偏高，建议开启制冷"
                            if (RH > 80) return "湿度过高，建议除湿"
                            if (RH < 30) return "空气干燥，建议补水通风"
                            if (T >= 20 && T <= 26 && RH >= 40 && RH <= 65) return "环境舒适，注意安全驾驶"
                            return "环境适中"
                        }
                        function trendDelta(field) {
                            var h = root.thermoHistory
                            if (h.length < 6) return 0
                            return h[h.length - 1][field] - h[h.length - 6][field]
                        }
                        function rangeOf(field) {
                            var h = root.thermoHistory
                            if (h.length === 0) return null
                            var lo = h[0][field], hi = h[0][field]
                            for (var i = 1; i < h.length; ++i) {
                                if (h[i][field] < lo) lo = h[i][field]
                                if (h[i][field] > hi) hi = h[i][field]
                            }
                            return { min: lo, max: hi }
                        }
                        function fmtTrend(d, unit) {
                            if (root.thermoHistory.length < 6) return "—"
                            var abs = Math.abs(d)
                            var threshold = unit === "°C" ? 0.2 : 1
                            if (abs < threshold) return "→ 平稳"
                            var sign = d > 0 ? "↑+" : "↓"
                            var digits = unit === "°C" ? 1 : 0
                            return sign + abs.toFixed(digits) + unit
                        }

                        Item {
                            anchors.fill: parent
                            anchors.margins: root.compact ? 16 : 22

                            readonly property real safeTemp: isNaN(thermoPageRoot.currentTemp) ? 22 : thermoPageRoot.currentTemp
                            readonly property real safeHumidity: isNaN(thermoPageRoot.currentHumidity) ? 50 : thermoPageRoot.currentHumidity
                            readonly property int compactScore: thermoPageRoot.comfortScore(safeTemp, safeHumidity)
                            readonly property color scoreColor: {
                                if (!sensorService.cabinValid) return root.mutedText
                                if (compactScore >= 85) return root.accentGreen
                                if (compactScore >= 70) return root.accentBlue
                                if (compactScore >= 50) return root.accentOrange
                                return root.accentDanger
                            }

                            RowLayout {
                                id: tbTopBar
                                anchors.top: parent.top
                                anchors.left: parent.left
                                anchors.right: parent.right
                                height: root.compact ? 52 : 60
                                spacing: 14

                                Rectangle {
                                    Layout.preferredWidth: root.compact ? 44 : 50
                                    Layout.preferredHeight: root.compact ? 44 : 50
                                    radius: width / 2
                                    color: root.glassPanel
                                    border.width: 1
                                    border.color: root.glassBorder
                                    Text {
                                        anchors.centerIn: parent
                                        text: root.mdi("F0141")
                                        color: root.pageText
                                        font.family: root.iconFamily
                                        font.pixelSize: root.compact ? 26 : 30
                                    }
                                    MouseArea { anchors.fill: parent; onClicked: root.functionPage = "grid" }
                                }

                                Text {
                                    Layout.fillWidth: true
                                    text: "座舱温湿度监测"
                                    color: root.pageText
                                    font.family: root.uiFamily
                                    font.pixelSize: root.compact ? 20 : 24
                                    font.bold: true
                                    elide: Text.ElideRight
                                }

                                Rectangle {
                                    Layout.preferredWidth: root.compact ? 96 : 112
                                    Layout.preferredHeight: root.compact ? 36 : 42
                                    radius: 14
                                    color: root.glassPanel
                                    border.width: 1
                                    border.color: root.glassBorder
                                    Text {
                                        anchors.centerIn: parent
                                        text: "清除历史"
                                        color: root.pageText
                                        font.family: root.uiFamily
                                        font.pixelSize: root.compact ? 13 : 14
                                    }
                                    MouseArea { anchors.fill: parent; onClicked: root.thermoHistory = [] }
                                }
                            }

                            RowLayout {
                                id: tbBottomCards
                                anchors.bottom: parent.bottom
                                anchors.left: parent.left
                                anchors.right: parent.right
                                height: root.compact ? 130 : 150
                                spacing: root.compact ? 10 : 14

                                Repeater {
                                    model: [
                                        { kind: "temp", title: "温度趋势", unit: "°C", accent: root.accentBlue },
                                        { kind: "humidity", title: "湿度趋势", unit: "%RH", accent: root.accentCyan }
                                    ]
                                    delegate: Rectangle {
                                        Layout.fillWidth: true
                                        Layout.fillHeight: true
                                        radius: 18
                                        color: root.glassPanel
                                        border.width: 1
                                        border.color: root.glassBorder

                                        Item {
                                            anchors.fill: parent
                                            anchors.margins: root.compact ? 10 : 12

                                            Row {
                                                id: miniHeader
                                                anchors.top: parent.top
                                                anchors.left: parent.left
                                                anchors.right: parent.right
                                                spacing: 6
                                                Rectangle {
                                                    width: 4
                                                    height: 14
                                                    radius: 2
                                                    color: modelData.accent
                                                    anchors.verticalCenter: parent.verticalCenter
                                                }
                                                Text {
                                                    text: modelData.title
                                                    color: root.pageText
                                                    font.family: root.uiFamily
                                                    font.pixelSize: root.compact ? 12 : 13
                                                    font.bold: true
                                                    anchors.verticalCenter: parent.verticalCenter
                                                }
                                                Text {
                                                    text: {
                                                        if (!sensorService.cabinValid) return "—"
                                                        var v = modelData.kind === "temp"
                                                                ? sensorService.cabinTemperature.toFixed(1) + " °C"
                                                                : sensorService.cabinHumidity.toFixed(0) + " %"
                                                        return v
                                                    }
                                                    color: modelData.accent
                                                    font.family: root.uiFamily
                                                    font.pixelSize: root.compact ? 13 : 14
                                                    font.bold: true
                                                    anchors.verticalCenter: parent.verticalCenter
                                                }
                                            }

                                            Text {
                                                id: miniRange
                                                anchors.bottom: parent.bottom
                                                anchors.left: parent.left
                                                anchors.right: parent.right
                                                text: {
                                                    root.thermoHistory.length
                                                    var f = modelData.kind === "temp" ? "temp" : "humidity"
                                                    var r = thermoPageRoot.rangeOf(f)
                                                    if (!r) return "区间 — / —"
                                                    var lo = modelData.kind === "temp" ? r.min.toFixed(1) : Math.round(r.min)
                                                    var hi = modelData.kind === "temp" ? r.max.toFixed(1) : Math.round(r.max)
                                                    return "区间 " + lo + " / " + hi + " " + modelData.unit
                                                }
                                                color: root.softText
                                                font.family: root.uiFamily
                                                font.pixelSize: 10
                                            }

                                            Canvas {
                                                id: miniChart
                                                anchors.top: miniHeader.bottom
                                                anchors.bottom: miniRange.top
                                                anchors.left: parent.left
                                                anchors.right: parent.right
                                                anchors.topMargin: 6
                                                anchors.bottomMargin: 4
                                                renderTarget: Canvas.Image
                                                antialiasing: true

                                                property string field: modelData.kind === "temp" ? "temp" : "humidity"
                                                property color accent: modelData.accent

                                                onPaint: {
                                                    var ctx = getContext("2d")
                                                    var W = width, H = height
                                                    ctx.reset()
                                                    ctx.clearRect(0, 0, W, H)
                                                    var pts = root.thermoHistory
                                                    if (pts.length < 2) {
                                                        ctx.fillStyle = "#74746F"
                                                        ctx.font = "10px " + root.uiFamily
                                                        ctx.textAlign = "center"
                                                        ctx.textBaseline = "middle"
                                                        ctx.fillText("等待数据中…", W / 2, H / 2)
                                                        return
                                                    }
                                                    var lo = pts[0][field], hi = pts[0][field]
                                                    for (var i = 1; i < pts.length; ++i) {
                                                        if (pts[i][field] < lo) lo = pts[i][field]
                                                        if (pts[i][field] > hi) hi = pts[i][field]
                                                    }
                                                    var minSpan = field === "temp" ? 1.5 : 4
                                                    if (hi - lo < minSpan) {
                                                        var mid = (hi + lo) / 2
                                                        lo = mid - minSpan / 2
                                                        hi = mid + minSpan / 2
                                                    }
                                                    var padY = (hi - lo) * 0.10
                                                    var yMin = lo - padY, yMax = hi + padY

                                                    ctx.strokeStyle = accent
                                                    ctx.lineWidth = 2
                                                    ctx.beginPath()
                                                    for (var j = 0; j < pts.length; ++j) {
                                                        var x = W * j / (pts.length - 1)
                                                        var v = pts[j][field]
                                                        var y = H * (1 - (v - yMin) / (yMax - yMin))
                                                        if (j === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y)
                                                    }
                                                    ctx.stroke()

                                                    var lastV = pts[pts.length - 1][field]
                                                    var lastY = H * (1 - (lastV - yMin) / (yMax - yMin))
                                                    ctx.fillStyle = Qt.rgba(accent.r, accent.g, accent.b, 0.30)
                                                    ctx.beginPath()
                                                    ctx.arc(W, lastY, 7, 0, Math.PI * 2)
                                                    ctx.fill()
                                                    ctx.fillStyle = accent
                                                    ctx.beginPath()
                                                    ctx.arc(W, lastY, 3, 0, Math.PI * 2)
                                                    ctx.fill()
                                                }

                                                Connections {
                                                    target: root
                                                    function onThermoHistoryChanged() { miniChart.requestPaint() }
                                                }
                                                Component.onCompleted: requestPaint()
                                                onWidthChanged: requestPaint()
                                                onHeightChanged: requestPaint()
                                            }
                                        }
                                    }
                                }

                                Rectangle {
                                    Layout.fillWidth: true
                                    Layout.fillHeight: true
                                    radius: 18
                                    color: root.glassPanel
                                    border.width: 1
                                    border.color: root.glassBorder

                                    Item {
                                        anchors.fill: parent
                                        anchors.margins: root.compact ? 10 : 14

                                        Row {
                                            id: derivedHeader
                                            anchors.top: parent.top
                                            anchors.left: parent.left
                                            spacing: 6
                                            Rectangle {
                                                width: 4
                                                height: 14
                                                radius: 2
                                                color: root.accentOrange
                                                anchors.verticalCenter: parent.verticalCenter
                                            }
                                            Text {
                                                text: "衍生指标"
                                                color: root.pageText
                                                font.family: root.uiFamily
                                                font.pixelSize: root.compact ? 12 : 13
                                                font.bold: true
                                                anchors.verticalCenter: parent.verticalCenter
                                            }
                                        }

                                        Column {
                                            anchors.top: derivedHeader.bottom
                                            anchors.left: parent.left
                                            anchors.right: parent.right
                                            anchors.topMargin: 8
                                            spacing: 4

                                            Row {
                                                spacing: 8
                                                Text {
                                                    text: "体感"
                                                    color: root.softText
                                                    font.family: root.uiFamily
                                                    font.pixelSize: 12
                                                    anchors.verticalCenter: parent.verticalCenter
                                                }
                                                Text {
                                                    text: sensorService.cabinValid
                                                          ? thermoPageRoot.apparentTemp(sensorService.cabinTemperature, sensorService.cabinHumidity).toFixed(1) + " °C"
                                                          : "—"
                                                    color: root.pageText
                                                    font.family: root.uiFamily
                                                    font.pixelSize: root.compact ? 18 : 20
                                                    font.bold: true
                                                    anchors.verticalCenter: parent.verticalCenter
                                                }
                                            }
                                            Row {
                                                spacing: 8
                                                Text {
                                                    text: "露点"
                                                    color: root.softText
                                                    font.family: root.uiFamily
                                                    font.pixelSize: 12
                                                    anchors.verticalCenter: parent.verticalCenter
                                                }
                                                Text {
                                                    text: sensorService.cabinValid
                                                          ? thermoPageRoot.dewPoint(sensorService.cabinTemperature, sensorService.cabinHumidity).toFixed(1) + " °C"
                                                          : "—"
                                                    color: root.pageText
                                                    font.family: root.uiFamily
                                                    font.pixelSize: root.compact ? 18 : 20
                                                    font.bold: true
                                                    anchors.verticalCenter: parent.verticalCenter
                                                }
                                            }
                                            Row {
                                                spacing: 8
                                                Text {
                                                    text: "采样"
                                                    color: root.softText
                                                    font.family: root.uiFamily
                                                    font.pixelSize: 12
                                                    anchors.verticalCenter: parent.verticalCenter
                                                }
                                                Text {
                                                    text: root.thermoHistory.length + " 点"
                                                    color: root.pageText
                                                    font.family: root.uiFamily
                                                    font.pixelSize: root.compact ? 16 : 18
                                                    font.bold: true
                                                    anchors.verticalCenter: parent.verticalCenter
                                                }
                                            }
                                        }
                                    }
                                }
                            }

                            RowLayout {
                                id: tbMainArea
                                anchors.top: tbTopBar.bottom
                                anchors.bottom: tbBottomCards.top
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.topMargin: root.compact ? 14 : 18
                                anchors.bottomMargin: root.compact ? 14 : 18
                                spacing: root.compact ? 12 : 16

                                Rectangle {
                                    id: coreCard
                                    Layout.preferredWidth: tbMainArea.width * 0.38
                                    Layout.fillHeight: true
                                    radius: 20
                                    color: root.glassPanel
                                    border.width: 1
                                    border.color: root.glassBorder

                                    readonly property color cardScoreColor: coreCard.parent.parent.scoreColor

                                    Item {
                                        anchors.fill: parent
                                        anchors.margins: root.compact ? 16 : 22

                                        Item {
                                            id: scoreBlock
                                            anchors.top: parent.top
                                            anchors.left: parent.left
                                            anchors.right: parent.right
                                            height: root.compact ? 120 : 140

                                            Text {
                                                id: scoreLabel
                                                anchors.top: parent.top
                                                anchors.horizontalCenter: parent.horizontalCenter
                                                text: "舒适度"
                                                color: root.mutedText
                                                font.family: root.uiFamily
                                                font.pixelSize: root.compact ? 12 : 13
                                            }

                                            Canvas {
                                                id: scoreRing
                                                anchors.top: scoreLabel.bottom
                                                anchors.horizontalCenter: parent.horizontalCenter
                                                anchors.topMargin: 6
                                                width: root.compact ? 76 : 86
                                                height: width
                                                antialiasing: true

                                                property real score: coreCard.parent.parent.compactScore
                                                property color ringColor: coreCard.cardScoreColor
                                                onScoreChanged: requestPaint()
                                                onRingColorChanged: requestPaint()

                                                onPaint: {
                                                    var ctx = getContext("2d")
                                                    ctx.reset()
                                                    var cx = width / 2, cy = height / 2
                                                    var R = Math.min(cx, cy) - 5
                                                    ctx.lineWidth = 8
                                                    ctx.lineCap = "round"
                                                    ctx.strokeStyle = Qt.rgba(1, 1, 1, 0.08)
                                                    ctx.beginPath()
                                                    ctx.arc(cx, cy, R, 0, Math.PI * 2)
                                                    ctx.stroke()
                                                    if (!sensorService.cabinValid) return
                                                    ctx.strokeStyle = ringColor
                                                    ctx.beginPath()
                                                    ctx.arc(cx, cy, R, -Math.PI / 2, -Math.PI / 2 + Math.PI * 2 * score / 100)
                                                    ctx.stroke()
                                                }

                                                Text {
                                                    anchors.centerIn: parent
                                                    text: sensorService.cabinValid ? scoreRing.score : "—"
                                                    color: scoreRing.ringColor
                                                    font.family: root.uiFamily
                                                    font.pixelSize: root.compact ? 30 : 38
                                                    font.bold: true
                                                }
                                            }

                                            Text {
                                                anchors.bottom: parent.bottom
                                                anchors.horizontalCenter: parent.horizontalCenter
                                                text: sensorService.cabinValid
                                                      ? thermoPageRoot.comfortGrade(coreCard.parent.parent.compactScore)
                                                      : "等待数据"
                                                color: coreCard.cardScoreColor
                                                font.family: root.uiFamily
                                                font.pixelSize: root.compact ? 16 : 18
                                                font.bold: true
                                            }
                                        }

                                        Rectangle {
                                            id: sep1
                                            anchors.top: scoreBlock.bottom
                                            anchors.left: parent.left
                                            anchors.right: parent.right
                                            anchors.topMargin: 10
                                            height: 1
                                            color: Qt.rgba(1, 1, 1, 0.08)
                                        }

                                        Column {
                                            id: metricsCol
                                            anchors.top: sep1.bottom
                                            anchors.left: parent.left
                                            anchors.right: parent.right
                                            anchors.topMargin: 10
                                            spacing: root.compact ? 8 : 12

                                            Item {
                                                width: parent.width
                                                height: root.compact ? 42 : 50
                                                Text {
                                                    id: tempLabel
                                                    anchors.top: parent.top
                                                    anchors.left: parent.left
                                                    text: "温度"
                                                    color: root.mutedText
                                                    font.family: root.uiFamily
                                                    font.pixelSize: 13
                                                }
                                                Row {
                                                    anchors.top: tempLabel.bottom
                                                    anchors.left: parent.left
                                                    anchors.topMargin: 2
                                                    spacing: 10
                                                    Text {
                                                        text: sensorService.cabinValid
                                                              ? sensorService.cabinTemperature.toFixed(1) + " °C"
                                                              : "—"
                                                        color: root.pageText
                                                        font.family: root.uiFamily
                                                        font.pixelSize: root.compact ? 26 : 30
                                                        font.bold: true
                                                        anchors.verticalCenter: parent.verticalCenter
                                                    }
                                                    Text {
                                                        text: {
                                                            root.thermoHistory.length
                                                            return thermoPageRoot.fmtTrend(thermoPageRoot.trendDelta("temp"), "°C")
                                                        }
                                                        color: root.accentBlue
                                                        font.family: root.uiFamily
                                                        font.pixelSize: 12
                                                        anchors.verticalCenter: parent.verticalCenter
                                                    }
                                                }
                                            }

                                            Item {
                                                width: parent.width
                                                height: root.compact ? 42 : 50
                                                Text {
                                                    id: humidLabel
                                                    anchors.top: parent.top
                                                    anchors.left: parent.left
                                                    text: "湿度"
                                                    color: root.mutedText
                                                    font.family: root.uiFamily
                                                    font.pixelSize: 13
                                                }
                                                Row {
                                                    anchors.top: humidLabel.bottom
                                                    anchors.left: parent.left
                                                    anchors.topMargin: 2
                                                    spacing: 10
                                                    Text {
                                                        text: sensorService.cabinValid
                                                              ? sensorService.cabinHumidity.toFixed(0) + " %RH"
                                                              : "—"
                                                        color: root.pageText
                                                        font.family: root.uiFamily
                                                        font.pixelSize: root.compact ? 26 : 30
                                                        font.bold: true
                                                        anchors.verticalCenter: parent.verticalCenter
                                                    }
                                                    Text {
                                                        text: {
                                                            root.thermoHistory.length
                                                            return thermoPageRoot.fmtTrend(thermoPageRoot.trendDelta("humidity"), "%")
                                                        }
                                                        color: root.accentCyan
                                                        font.family: root.uiFamily
                                                        font.pixelSize: 12
                                                        anchors.verticalCenter: parent.verticalCenter
                                                    }
                                                }
                                            }
                                        }

                                        Item {
                                            anchors.bottom: parent.bottom
                                            anchors.left: parent.left
                                            anchors.right: parent.right
                                            height: root.compact ? 64 : 76

                                            Rectangle {
                                                id: adviceBar
                                                anchors.left: parent.left
                                                anchors.verticalCenter: parent.verticalCenter
                                                width: 4
                                                height: parent.height * 0.7
                                                radius: 2
                                                color: coreCard.cardScoreColor
                                            }
                                            Column {
                                                anchors.left: adviceBar.right
                                                anchors.right: parent.right
                                                anchors.verticalCenter: parent.verticalCenter
                                                anchors.leftMargin: 10
                                                spacing: 3

                                                Text {
                                                    text: "环境建议"
                                                    color: root.mutedText
                                                    font.family: root.uiFamily
                                                    font.pixelSize: 12
                                                }
                                                Text {
                                                    width: parent.width
                                                    text: sensorService.cabinValid
                                                          ? thermoPageRoot.advice(sensorService.cabinTemperature, sensorService.cabinHumidity)
                                                          : "等待传感器数据…"
                                                    color: root.pageText
                                                    font.family: root.uiFamily
                                                    font.pixelSize: root.compact ? 13 : 15
                                                    wrapMode: Text.WordWrap
                                                }
                                            }
                                        }
                                    }
                                }

                                Rectangle {
                                    id: mapCard
                                    Layout.fillWidth: true
                                    Layout.fillHeight: true
                                    radius: 20
                                    color: root.glassPanel
                                    border.width: 1
                                    border.color: root.glassBorder

                                    Item {
                                        anchors.fill: parent
                                        anchors.margins: root.compact ? 14 : 18

                                        Row {
                                            id: mapHeader
                                            anchors.top: parent.top
                                            anchors.left: parent.left
                                            spacing: 6
                                            Rectangle {
                                                width: 6
                                                height: 18
                                                radius: 3
                                                color: root.accentGreen
                                                anchors.verticalCenter: parent.verticalCenter
                                            }
                                            Text {
                                                text: "舒适度地图"
                                                color: root.pageText
                                                font.family: root.uiFamily
                                                font.pixelSize: root.compact ? 14 : 16
                                                font.bold: true
                                                anchors.verticalCenter: parent.verticalCenter
                                            }
                                            Text {
                                                text: "  温度 × 湿度 二维舒适区"
                                                color: root.softText
                                                font.family: root.uiFamily
                                                font.pixelSize: 11
                                                anchors.verticalCenter: parent.verticalCenter
                                            }
                                        }

                                        Item {
                                            id: mapArea
                                            anchors.top: mapHeader.bottom
                                            anchors.bottom: parent.bottom
                                            anchors.left: parent.left
                                            anchors.right: parent.right
                                            anchors.topMargin: 10

                                            readonly property real tMin: 16
                                            readonly property real tMax: 32
                                            readonly property real hMin: 20
                                            readonly property real hMax: 80
                                            readonly property real plotX: 36
                                            readonly property real plotY: 4
                                            readonly property real plotW: width - plotX - 12
                                            readonly property real plotH: height - plotY - 24

                                            function mapX(t) {
                                                var clamped = Math.max(tMin, Math.min(tMax, t))
                                                return plotX + plotW * (clamped - tMin) / (tMax - tMin)
                                            }
                                            function mapY(h) {
                                                var clamped = Math.max(hMin, Math.min(hMax, h))
                                                return plotY + plotH * (1 - (clamped - hMin) / (hMax - hMin))
                                            }

                                            Canvas {
                                                id: comfortHeat
                                                anchors.fill: parent
                                                antialiasing: true
                                                renderTarget: Canvas.Image

                                                onPaint: {
                                                    var ctx = getContext("2d")
                                                    ctx.reset()
                                                    ctx.clearRect(0, 0, width, height)
                                                    var pX = mapArea.plotX, pY = mapArea.plotY
                                                    var pW = mapArea.plotW, pH = mapArea.plotH

                                                    var nx = 32, ny = 16
                                                    for (var ix = 0; ix < nx; ++ix) {
                                                        for (var iy = 0; iy < ny; ++iy) {
                                                            var t = mapArea.tMin + (mapArea.tMax - mapArea.tMin) * (ix + 0.5) / nx
                                                            var h = mapArea.hMin + (mapArea.hMax - mapArea.hMin) * (iy + 0.5) / ny
                                                            var s = thermoPageRoot.comfortScore(t, h)
                                                            var fill
                                                            if (s >= 85) fill = Qt.rgba(0.84, 0.83, 0.78, 0.35)
                                                            else if (s >= 70) fill = Qt.rgba(0.96, 0.64, 0.0, 0.16)
                                                            else if (s >= 50) fill = Qt.rgba(0.78, 0.46, 0.13, 0.14)
                                                            else fill = Qt.rgba(0.84, 0.33, 0.31, 0.10)
                                                            ctx.fillStyle = fill
                                                            ctx.fillRect(pX + pW * ix / nx, pY + pH * (1 - (iy + 1) / ny), pW / nx + 1, pH / ny + 1)
                                                        }
                                                    }

                                                    ctx.strokeStyle = Qt.rgba(1, 1, 1, 0.08)
                                                    ctx.lineWidth = 1
                                                    for (var gx = 0; gx <= 4; ++gx) {
                                                        var x = pX + pW * gx / 4
                                                        ctx.beginPath(); ctx.moveTo(x, pY); ctx.lineTo(x, pY + pH); ctx.stroke()
                                                    }
                                                    for (var gy = 0; gy <= 4; ++gy) {
                                                        var y = pY + pH * gy / 4
                                                        ctx.beginPath(); ctx.moveTo(pX, y); ctx.lineTo(pX + pW, y); ctx.stroke()
                                                    }

                                                    ctx.strokeStyle = Qt.rgba(1, 1, 1, 0.20)
                                                    ctx.lineWidth = 1
                                                    ctx.beginPath()
                                                    ctx.rect(pX, pY, pW, pH)
                                                    ctx.stroke()

                                                    ctx.fillStyle = "#A8A8A2"
                                                    ctx.font = "10px " + root.uiFamily
                                                    ctx.textAlign = "right"
                                                    ctx.textBaseline = "middle"
                                                    for (var hy = 0; hy <= 4; ++hy) {
                                                        var hv = mapArea.hMax - (mapArea.hMax - mapArea.hMin) * hy / 4
                                                        var ly = pY + pH * hy / 4
                                                        ctx.fillText(Math.round(hv) + "%", pX - 4, ly)
                                                    }
                                                    ctx.textAlign = "center"
                                                    ctx.textBaseline = "top"
                                                    for (var tx = 0; tx <= 4; ++tx) {
                                                        var tv = mapArea.tMin + (mapArea.tMax - mapArea.tMin) * tx / 4
                                                        var lx = pX + pW * tx / 4
                                                        ctx.fillText(Math.round(tv) + "°", lx, pY + pH + 4)
                                                    }
                                                }
                                                onWidthChanged: requestPaint()
                                                onHeightChanged: requestPaint()
                                                Component.onCompleted: requestPaint()
                                            }

                                            Rectangle {
                                                id: idealMark
                                                width: 8
                                                height: 8
                                                radius: 4
                                                color: "transparent"
                                                border.width: 1
                                                border.color: Qt.rgba(0.84, 0.83, 0.78, 0.7)
                                                x: mapArea.mapX(22) - width / 2
                                                y: mapArea.mapY(50) - height / 2
                                            }

                                            Repeater {
                                                id: trail
                                                model: {
                                                    var h = root.thermoHistory
                                                    var n = Math.min(30, h.length)
                                                    return h.slice(h.length - n, h.length - 1)
                                                }
                                                delegate: Rectangle {
                                                    readonly property real prog: index / Math.max(1, trail.count - 1)
                                                    width: 2 + prog * 3
                                                    height: width
                                                    radius: width / 2
                                                    color: root.accentBlue
                                                    opacity: 0.15 + prog * 0.40
                                                    x: mapArea.mapX(modelData.temp) - width / 2
                                                    y: mapArea.mapY(modelData.humidity) - height / 2
                                                }
                                            }

                                            Rectangle {
                                                id: currentHalo
                                                visible: sensorService.cabinValid
                                                width: 28
                                                height: 28
                                                radius: 14
                                                color: coreCard.cardScoreColor
                                                opacity: 0.30
                                                x: mapArea.mapX(sensorService.cabinTemperature) - width / 2
                                                y: mapArea.mapY(sensorService.cabinHumidity) - height / 2

                                                SequentialAnimation on opacity {
                                                    running: sensorService.cabinValid
                                                    loops: Animation.Infinite
                                                    NumberAnimation { to: 0.45; duration: 1000; easing.type: Easing.InOutSine }
                                                    NumberAnimation { to: 0.20; duration: 1000; easing.type: Easing.InOutSine }
                                                }
                                                Behavior on x { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }
                                                Behavior on y { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }
                                            }

                                            Rectangle {
                                                id: currentDot
                                                visible: sensorService.cabinValid
                                                width: 14
                                                height: 14
                                                radius: 7
                                                color: coreCard.cardScoreColor
                                                border.width: 2
                                                border.color: Qt.rgba(0, 0, 0, 0.4)
                                                x: mapArea.mapX(sensorService.cabinTemperature) - width / 2
                                                y: mapArea.mapY(sensorService.cabinHumidity) - height / 2

                                                Behavior on x { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }
                                                Behavior on y { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }
                                            }

                                            Text {
                                                visible: !sensorService.cabinValid
                                                anchors.centerIn: parent
                                                text: "等待传感器数据…"
                                                color: root.softText
                                                font.family: root.uiFamily
                                                font.pixelSize: 13
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                Component {
                    id: bodyTempPageComponent

                    Item {
                        id: bodyTempPageRoot
                        anchors.fill: parent

                        readonly property real currentTemp: sensorService.driverValid ? sensorService.driverTemperature : NaN

                        function classifyIndex(t) {
                            if (isNaN(t)) return -1
                            if (t < 36.0) return 0
                            if (t < 37.3) return 1
                            if (t < 38.0) return 2
                            if (t < 39.0) return 3
                            return 4
                        }
                        function statusColor(idx) {
                            if (idx === 0) return root.accentCold
                            if (idx === 1) return root.accentGreen
                            if (idx === 2) return root.accentBlue
                            if (idx === 3) return root.accentOrange
                            if (idx === 4) return root.accentDanger
                            return root.mutedText
                        }
                        function statusText(idx) {
                            return ["偏低", "正常", "低烧", "中等发热", "高热"][idx] || "—"
                        }
                        function advice(idx) {
                            if (idx === 0) return "体温偏低，注意保暖，必要时停车休息"
                            if (idx === 1) return "体温正常，可继续驾驶\n注意保持适当休息"
                            if (idx === 2) return "出现低烧迹象\n建议停车休息观察"
                            if (idx === 3) return "中度发热\n请立即停车并就医检查"
                            if (idx === 4) return "高热\n请立即停车并寻求医疗帮助"
                            return "等待传感器数据…"
                        }
                        function trendDelta() {
                            var h = root.bodyTempHistory
                            if (h.length < 11) return NaN
                            return h[h.length - 1].temp - h[h.length - 11].temp
                        }
                        function fmtTrend() {
                            var d = trendDelta()
                            if (isNaN(d)) return "—"
                            if (Math.abs(d) < 0.1) return "→ 平稳"
                            var sign = d > 0 ? "↑+" : "↓"
                            return sign + Math.abs(d).toFixed(1) + " °C 近10s"
                        }
                        function rangeOf() {
                            var h = root.bodyTempHistory
                            if (h.length === 0) return null
                            var lo = h[0].temp, hi = h[0].temp, sum = 0
                            for (var i = 0; i < h.length; ++i) {
                                if (h[i].temp < lo) lo = h[i].temp
                                if (h[i].temp > hi) hi = h[i].temp
                                sum += h[i].temp
                            }
                            return { min: lo, max: hi, avg: sum / h.length }
                        }
                        function fmtAgo(ms) {
                            if (isNaN(ms) || ms < 0) return "—"
                            var s = Math.floor(ms / 1000)
                            if (s < 5) return "刚刚"
                            if (s < 60) return s + " 秒前"
                            return Math.floor(s / 60) + " 分前"
                        }

                        Item {
                            anchors.fill: parent
                            anchors.margins: root.compact ? 16 : 22

                            RowLayout {
                                id: btTopBar
                                anchors.top: parent.top
                                anchors.left: parent.left
                                anchors.right: parent.right
                                height: root.compact ? 52 : 60
                                spacing: 14

                                Rectangle {
                                    Layout.preferredWidth: root.compact ? 44 : 50
                                    Layout.preferredHeight: root.compact ? 44 : 50
                                    radius: width / 2
                                    color: root.glassPanel
                                    border.width: 1
                                    border.color: root.glassBorder
                                    Text {
                                        anchors.centerIn: parent
                                        text: root.mdi("F0141")
                                        color: root.pageText
                                        font.family: root.iconFamily
                                        font.pixelSize: root.compact ? 26 : 30
                                    }
                                    MouseArea { anchors.fill: parent; onClicked: root.functionPage = "grid" }
                                }

                                Text {
                                    Layout.fillWidth: true
                                    text: "人体体温监测"
                                    color: root.pageText
                                    font.family: root.uiFamily
                                    font.pixelSize: root.compact ? 20 : 24
                                    font.bold: true
                                    elide: Text.ElideRight
                                }

                                Rectangle {
                                    Layout.preferredWidth: root.compact ? 96 : 112
                                    Layout.preferredHeight: root.compact ? 36 : 42
                                    radius: 14
                                    color: root.glassPanel
                                    border.width: 1
                                    border.color: root.glassBorder
                                    Text {
                                        anchors.centerIn: parent
                                        text: "清除历史"
                                        color: root.pageText
                                        font.family: root.uiFamily
                                        font.pixelSize: root.compact ? 13 : 14
                                    }
                                    MouseArea { anchors.fill: parent; onClicked: root.bodyTempHistory = [] }
                                }
                            }

                            RowLayout {
                                id: btBottomCards
                                anchors.bottom: parent.bottom
                                anchors.left: parent.left
                                anchors.right: parent.right
                                height: root.compact ? 100 : 116
                                spacing: root.compact ? 10 : 14

                                Rectangle {
                                    Layout.preferredWidth: bodyTempPageRoot.width * 0.22
                                    Layout.fillHeight: true
                                    radius: 18
                                    color: root.glassPanel
                                    border.width: 1
                                    border.color: root.glassBorder

                                    Column {
                                        anchors.fill: parent
                                        anchors.margins: root.compact ? 12 : 14
                                        spacing: 3

                                        Text {
                                            text: "本次区间"
                                            color: root.mutedText
                                            font.family: root.uiFamily
                                            font.pixelSize: root.compact ? 12 : 13
                                        }
                                        Row {
                                            spacing: 8
                                            Text {
                                                text: "最高"
                                                color: root.softText
                                                font.family: root.uiFamily
                                                font.pixelSize: root.compact ? 11 : 12
                                                anchors.verticalCenter: parent.verticalCenter
                                            }
                                            Text {
                                                text: {
                                                    root.bodyTempHistory.length
                                                    var r = bodyTempPageRoot.rangeOf()
                                                    return r ? r.max.toFixed(1) + " °C" : "—"
                                                }
                                                color: root.pageText
                                                font.family: root.uiFamily
                                                font.pixelSize: root.compact ? 16 : 18
                                                font.bold: true
                                                anchors.verticalCenter: parent.verticalCenter
                                            }
                                        }
                                        Row {
                                            spacing: 8
                                            Text {
                                                text: "最低"
                                                color: root.softText
                                                font.family: root.uiFamily
                                                font.pixelSize: root.compact ? 11 : 12
                                                anchors.verticalCenter: parent.verticalCenter
                                            }
                                            Text {
                                                text: {
                                                    root.bodyTempHistory.length
                                                    var r = bodyTempPageRoot.rangeOf()
                                                    return r ? r.min.toFixed(1) + " °C" : "—"
                                                }
                                                color: root.pageText
                                                font.family: root.uiFamily
                                                font.pixelSize: root.compact ? 16 : 18
                                                font.bold: true
                                                anchors.verticalCenter: parent.verticalCenter
                                            }
                                        }
                                        Row {
                                            spacing: 8
                                            Text {
                                                text: "平均"
                                                color: root.softText
                                                font.family: root.uiFamily
                                                font.pixelSize: root.compact ? 11 : 12
                                                anchors.verticalCenter: parent.verticalCenter
                                            }
                                            Text {
                                                text: {
                                                    root.bodyTempHistory.length
                                                    var r = bodyTempPageRoot.rangeOf()
                                                    return r ? r.avg.toFixed(1) + " °C" : "—"
                                                }
                                                color: root.pageText
                                                font.family: root.uiFamily
                                                font.pixelSize: root.compact ? 16 : 18
                                                font.bold: true
                                                anchors.verticalCenter: parent.verticalCenter
                                            }
                                        }
                                    }
                                }

                                Rectangle {
                                    Layout.preferredWidth: bodyTempPageRoot.width * 0.22
                                    Layout.fillHeight: true
                                    radius: 18
                                    color: root.glassPanel
                                    border.width: 1
                                    border.color: root.glassBorder

                                    Column {
                                        anchors.fill: parent
                                        anchors.margins: root.compact ? 12 : 14
                                        spacing: 6

                                        Text {
                                            text: "采样情况"
                                            color: root.mutedText
                                            font.family: root.uiFamily
                                            font.pixelSize: root.compact ? 12 : 13
                                        }
                                        Row {
                                            spacing: 8
                                            Text {
                                                text: "采样数"
                                                color: root.softText
                                                font.family: root.uiFamily
                                                font.pixelSize: root.compact ? 11 : 12
                                                anchors.verticalCenter: parent.verticalCenter
                                            }
                                            Text {
                                                text: root.bodyTempHistory.length
                                                color: root.pageText
                                                font.family: root.uiFamily
                                                font.pixelSize: root.compact ? 18 : 20
                                                font.bold: true
                                                anchors.verticalCenter: parent.verticalCenter
                                            }
                                        }
                                        Row {
                                            spacing: 8
                                            Text {
                                                text: "最近"
                                                color: root.softText
                                                font.family: root.uiFamily
                                                font.pixelSize: root.compact ? 11 : 12
                                                anchors.verticalCenter: parent.verticalCenter
                                            }
                                            Text {
                                                text: {
                                                    agoTick.tick
                                                    var h = root.bodyTempHistory
                                                    if (h.length === 0) return "—"
                                                    return bodyTempPageRoot.fmtAgo(Date.now() - h[h.length - 1].t)
                                                }
                                                color: root.pageText
                                                font.family: root.uiFamily
                                                font.pixelSize: root.compact ? 14 : 16
                                                font.bold: true
                                                anchors.verticalCenter: parent.verticalCenter
                                            }
                                        }
                                    }
                                }

                                Rectangle {
                                    Layout.fillWidth: true
                                    Layout.fillHeight: true
                                    radius: 18
                                    color: root.glassPanel
                                    border.width: 1
                                    border.color: root.glassBorder

                                    Item {
                                        anchors.fill: parent
                                        anchors.margins: root.compact ? 12 : 14

                                        Rectangle {
                                            id: adviceAccentBar
                                            anchors.left: parent.left
                                            anchors.verticalCenter: parent.verticalCenter
                                            width: 6
                                            height: parent.height * 0.7
                                            radius: 3
                                            color: bodyTempPageRoot.statusColor(bodyTempPageRoot.classifyIndex(bodyTempPageRoot.currentTemp))
                                        }

                                        Column {
                                            anchors.left: adviceAccentBar.right
                                            anchors.leftMargin: 12
                                            anchors.right: parent.right
                                            anchors.verticalCenter: parent.verticalCenter
                                            spacing: 4

                                            Text {
                                                text: "驾驶建议"
                                                color: root.mutedText
                                                font.family: root.uiFamily
                                                font.pixelSize: root.compact ? 12 : 13
                                            }
                                            Text {
                                                width: parent.width
                                                text: bodyTempPageRoot.advice(bodyTempPageRoot.classifyIndex(bodyTempPageRoot.currentTemp))
                                                color: root.pageText
                                                font.family: root.uiFamily
                                                font.pixelSize: root.compact ? 14 : 16
                                                wrapMode: Text.WordWrap
                                            }
                                        }
                                    }
                                }
                            }

                            RowLayout {
                                id: btMainArea
                                anchors.top: btTopBar.bottom
                                anchors.bottom: btBottomCards.top
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.topMargin: root.compact ? 14 : 18
                                anchors.bottomMargin: root.compact ? 14 : 18
                                spacing: root.compact ? 12 : 16

                                Rectangle {
                                    Layout.preferredWidth: bodyTempPageRoot.width * 0.4
                                    Layout.fillHeight: true
                                    radius: 20
                                    color: root.glassPanel
                                    border.width: 1
                                    border.color: root.glassBorder

                                    Item {
                                        anchors.fill: parent
                                        anchors.margins: root.compact ? 18 : 24

                                        readonly property int idx: bodyTempPageRoot.classifyIndex(bodyTempPageRoot.currentTemp)
                                        readonly property color stColor: bodyTempPageRoot.statusColor(idx)

                                        Text {
                                            id: tempLabel
                                            anchors.top: parent.top
                                            text: "当前体温"
                                            color: root.mutedText
                                            font.family: root.uiFamily
                                            font.pixelSize: root.compact ? 13 : 14
                                        }

                                        Row {
                                            id: tempRow
                                            anchors.top: tempLabel.bottom
                                            anchors.topMargin: 6
                                            spacing: 8
                                            Text {
                                                text: sensorService.driverValid
                                                      ? sensorService.driverTemperature.toFixed(1)
                                                      : "—"
                                                color: parent.parent.stColor
                                                font.family: root.uiFamily
                                                font.pixelSize: root.compact ? 56 : 72
                                                font.bold: true
                                                anchors.verticalCenter: parent.verticalCenter
                                            }
                                            Text {
                                                text: "°C"
                                                color: root.mutedText
                                                font.family: root.uiFamily
                                                font.pixelSize: root.compact ? 22 : 28
                                                anchors.verticalCenter: parent.verticalCenter
                                                anchors.verticalCenterOffset: root.compact ? 6 : 10
                                            }
                                        }

                                        Row {
                                            id: badgeRow
                                            anchors.top: tempRow.bottom
                                            anchors.topMargin: 12
                                            spacing: 8

                                            Rectangle {
                                                width: 10
                                                height: 10
                                                radius: 5
                                                color: parent.parent.stColor
                                                anchors.verticalCenter: parent.verticalCenter
                                            }
                                            Text {
                                                text: sensorService.driverValid
                                                      ? bodyTempPageRoot.statusText(parent.parent.idx)
                                                      : "等待数据"
                                                color: parent.parent.stColor
                                                font.family: root.uiFamily
                                                font.pixelSize: root.compact ? 18 : 20
                                                font.bold: true
                                                anchors.verticalCenter: parent.verticalCenter
                                            }
                                        }

                                        Text {
                                            id: trendText
                                            anchors.top: badgeRow.bottom
                                            anchors.topMargin: 6
                                            text: {
                                                root.bodyTempHistory.length
                                                return bodyTempPageRoot.fmtTrend()
                                            }
                                            color: root.mutedText
                                            font.family: root.uiFamily
                                            font.pixelSize: root.compact ? 13 : 14
                                        }

                                        Item {
                                            id: statusBar
                                            anchors.left: parent.left
                                            anchors.right: parent.right
                                            anchors.bottom: parent.bottom
                                            height: 38

                                            readonly property real tMin: 35.0
                                            readonly property real tMax: 40.5
                                            readonly property var segments: [
                                                { from: 35.0, to: 36.0, color: root.accentCold },
                                                { from: 36.0, to: 37.3, color: root.accentGreen },
                                                { from: 37.3, to: 38.0, color: root.accentBlue },
                                                { from: 38.0, to: 39.0, color: root.accentOrange },
                                                { from: 39.0, to: 40.5, color: root.accentDanger }
                                            ]

                                            Item {
                                                id: barTrack
                                                anchors.left: parent.left
                                                anchors.right: parent.right
                                                anchors.bottom: parent.bottom
                                                height: 14

                                                Row {
                                                    anchors.fill: parent
                                                    spacing: 0
                                                    Repeater {
                                                        model: statusBar.segments
                                                        delegate: Rectangle {
                                                            width: barTrack.width * (modelData.to - modelData.from) / (statusBar.tMax - statusBar.tMin)
                                                            height: barTrack.height
                                                            color: modelData.color
                                                            opacity: (sensorService.driverValid && bodyTempPageRoot.classifyIndex(bodyTempPageRoot.currentTemp) === index) ? 1.0 : 0.32

                                                            radius: 0
                                                            Rectangle {
                                                                anchors.fill: parent
                                                                visible: index === 0
                                                                color: parent.color
                                                                radius: 7
                                                                clip: true
                                                            }
                                                        }
                                                    }
                                                }
                                            }

                                            Row {
                                                anchors.left: parent.left
                                                anchors.right: parent.right
                                                anchors.bottom: barTrack.top
                                                anchors.bottomMargin: 4
                                                Repeater {
                                                    model: ["35", "36", "37", "38", "39+"]
                                                    delegate: Text {
                                                        width: barTrack.width / 5
                                                        horizontalAlignment: Text.AlignHCenter
                                                        text: modelData
                                                        color: root.softText
                                                        font.family: root.uiFamily
                                                        font.pixelSize: 10
                                                    }
                                                }
                                            }

                                            Item {
                                                id: pointer
                                                width: 14
                                                height: 14
                                                anchors.bottom: barTrack.top
                                                anchors.bottomMargin: -2
                                                visible: sensorService.driverValid
                                                x: {
                                                    var t = bodyTempPageRoot.currentTemp
                                                    var clamped = Math.max(statusBar.tMin, Math.min(statusBar.tMax, t))
                                                    return barTrack.width * (clamped - statusBar.tMin) / (statusBar.tMax - statusBar.tMin) - width / 2
                                                }

                                                Canvas {
                                                    anchors.fill: parent
                                                    antialiasing: true
                                                    property color pColor: bodyTempPageRoot.statusColor(bodyTempPageRoot.classifyIndex(bodyTempPageRoot.currentTemp))
                                                    onPColorChanged: requestPaint()
                                                    onPaint: {
                                                        var ctx = getContext("2d")
                                                        ctx.reset()
                                                        ctx.fillStyle = pColor
                                                        ctx.beginPath()
                                                        ctx.moveTo(width / 2, height)
                                                        ctx.lineTo(0, 0)
                                                        ctx.lineTo(width, 0)
                                                        ctx.closePath()
                                                        ctx.fill()
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }

                                Rectangle {
                                    Layout.fillWidth: true
                                    Layout.fillHeight: true
                                    radius: 20
                                    color: root.glassPanel
                                    border.width: 1
                                    border.color: root.glassBorder

                                    Column {
                                        anchors.fill: parent
                                        anchors.margins: root.compact ? 14 : 18
                                        spacing: 8

                                        Row {
                                            spacing: 8
                                            Rectangle {
                                                width: 6
                                                height: 18
                                                radius: 3
                                                color: root.accentBlue
                                                anchors.verticalCenter: parent.verticalCenter
                                            }
                                            Text {
                                                text: "体温趋势"
                                                color: root.pageText
                                                font.family: root.uiFamily
                                                font.pixelSize: root.compact ? 14 : 16
                                                font.bold: true
                                                anchors.verticalCenter: parent.verticalCenter
                                            }
                                        }

                                        Canvas {
                                            id: btChart
                                            width: parent.width
                                            height: parent.height - (root.compact ? 28 : 32)
                                            renderTarget: Canvas.Image
                                            antialiasing: true

                                            onPaint: {
                                                var ctx = getContext("2d")
                                                var W = width, H = height
                                                ctx.reset()
                                                ctx.clearRect(0, 0, W, H)

                                                var padL = 40, padR = 12, padT = 6, padB = 22
                                                var plotW = W - padL - padR
                                                var plotH = H - padT - padB

                                                var pts = root.bodyTempHistory
                                                if (pts.length < 2) {
                                                    ctx.fillStyle = "#74746F"
                                                    ctx.font = "12px " + root.uiFamily
                                                    ctx.textAlign = "center"
                                                    ctx.textBaseline = "middle"
                                                    ctx.fillText("等待数据中…", W / 2, H / 2)
                                                    return
                                                }

                                                var lo = pts[0].temp, hi = pts[0].temp
                                                for (var i = 1; i < pts.length; ++i) {
                                                    if (pts[i].temp < lo) lo = pts[i].temp
                                                    if (pts[i].temp > hi) hi = pts[i].temp
                                                }
                                                if (hi - lo < 1.0) {
                                                    var mid = (hi + lo) / 2
                                                    lo = mid - 0.5
                                                    hi = mid + 0.5
                                                }
                                                var padY = (hi - lo) * 0.15
                                                var yMin = Math.floor((lo - padY) * 10) / 10
                                                var yMax = Math.ceil((hi + padY) * 10) / 10

                                                ctx.strokeStyle = Qt.rgba(1, 1, 1, 0.10)
                                                ctx.lineWidth = 1
                                                ctx.font = "10px " + root.uiFamily
                                                ctx.fillStyle = "#A8A8A2"
                                                ctx.textAlign = "right"
                                                ctx.textBaseline = "middle"
                                                for (var g = 0; g <= 4; ++g) {
                                                    var gy = padT + plotH * g / 4
                                                    var gv = yMax - (yMax - yMin) * g / 4
                                                    ctx.beginPath()
                                                    ctx.moveTo(padL, gy)
                                                    ctx.lineTo(padL + plotW, gy)
                                                    ctx.stroke()
                                                    ctx.fillText(gv.toFixed(1), padL - 4, gy)
                                                }

                                                function drawDashedY(value, color) {
                                                    if (value < yMin || value > yMax) return
                                                    var y = padT + plotH * (1 - (value - yMin) / (yMax - yMin))
                                                    ctx.strokeStyle = color
                                                    ctx.setLineDash([4, 4])
                                                    ctx.beginPath()
                                                    ctx.moveTo(padL, y)
                                                    ctx.lineTo(padL + plotW, y)
                                                    ctx.stroke()
                                                    ctx.setLineDash([])
                                                }
                                                drawDashedY(36.0, Qt.rgba(0.5, 0.7, 0.83, 0.35))
                                                drawDashedY(37.3, Qt.rgba(0.96, 0.64, 0.0, 0.4))

                                                ctx.strokeStyle = Qt.rgba(1, 1, 1, 0.18)
                                                ctx.beginPath()
                                                ctx.moveTo(padL, padT + plotH)
                                                ctx.lineTo(padL + plotW, padT + plotH)
                                                ctx.stroke()

                                                ctx.textAlign = "center"
                                                ctx.textBaseline = "top"
                                                var labelCount = Math.min(5, pts.length)
                                                for (var k = 0; k < labelCount; ++k) {
                                                    var ix = labelCount === 1 ? 0 : Math.floor((pts.length - 1) * k / (labelCount - 1))
                                                    var ts = new Date(pts[ix].t)
                                                    var lbl = Qt.formatDateTime(ts, "mm:ss")
                                                    var lx = pts.length === 1 ? padL + plotW / 2 : padL + plotW * ix / (pts.length - 1)
                                                    ctx.fillText(lbl, lx, padT + plotH + 4)
                                                }

                                                ctx.strokeStyle = root.accentBlue
                                                ctx.lineWidth = 2
                                                ctx.beginPath()
                                                for (var j = 0; j < pts.length; ++j) {
                                                    var x = padL + plotW * j / (pts.length - 1)
                                                    var v = pts[j].temp
                                                    var y = padT + plotH * (1 - (v - yMin) / (yMax - yMin))
                                                    if (j === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y)
                                                }
                                                ctx.stroke()

                                                var lastX = padL + plotW
                                                var lastV = pts[pts.length - 1].temp
                                                var lastY = padT + plotH * (1 - (lastV - yMin) / (yMax - yMin))
                                                ctx.fillStyle = Qt.rgba(0.96, 0.64, 0.0, 0.30)
                                                ctx.beginPath()
                                                ctx.arc(lastX, lastY, 10, 0, Math.PI * 2)
                                                ctx.fill()
                                                ctx.fillStyle = root.accentBlue
                                                ctx.beginPath()
                                                ctx.arc(lastX, lastY, 4, 0, Math.PI * 2)
                                                ctx.fill()
                                            }

                                            Connections {
                                                target: root
                                                function onBodyTempHistoryChanged() { btChart.requestPaint() }
                                            }
                                            Component.onCompleted: requestPaint()
                                            onWidthChanged: requestPaint()
                                            onHeightChanged: requestPaint()
                                        }
                                    }
                                }
                            }
                        }

                        Timer {
                            id: agoTick
                            interval: 1000
                            running: true
                            repeat: true
                            property int tick: 0
                            onTriggered: tick++
                        }
                    }
                }

                Component {
                    id: brightnessPageComponent

                    Item {
                        id: brightnessPageRoot
                        anchors.fill: parent

                        // auto 写亮度后让滑块跟随（用户拖动时不抢）。声明式 value 绑定首次拖动后会断，
                        // 这里兜底持续同步，保证自动模式下滑块实时跟着环境光走。
                        Connections {
                            target: brightnessController
                            function onBrightnessChanged() {
                                if (!brightnessSlider.pressed)
                                    brightnessSlider.value = brightnessController.brightness
                            }
                        }

                        Item {
                            anchors.fill: parent
                            anchors.margins: root.compact ? 16 : 22

                            RowLayout {
                                id: brTopBar
                                anchors.top: parent.top
                                anchors.left: parent.left
                                anchors.right: parent.right
                                height: root.compact ? 52 : 60
                                spacing: 14

                                Rectangle {
                                    Layout.preferredWidth: root.compact ? 44 : 50
                                    Layout.preferredHeight: root.compact ? 44 : 50
                                    radius: width / 2
                                    color: root.glassPanel
                                    border.width: 1
                                    border.color: root.glassBorder
                                    Text {
                                        anchors.centerIn: parent
                                        text: root.mdi("F0141")
                                        color: root.pageText
                                        font.family: root.iconFamily
                                        font.pixelSize: root.compact ? 26 : 30
                                    }
                                    MouseArea { anchors.fill: parent; onClicked: root.functionPage = "grid" }
                                }

                                Text {
                                    Layout.fillWidth: true
                                    text: "屏幕亮度"
                                    color: root.pageText
                                    font.family: root.uiFamily
                                    font.pixelSize: root.compact ? 20 : 24
                                    font.bold: true
                                    elide: Text.ElideRight
                                }

                                Text {
                                    visible: brightnessController.available
                                    text: "自动"
                                    color: root.mutedText
                                    font.family: root.uiFamily
                                    font.pixelSize: root.compact ? 13 : 15
                                }

                                Switch {
                                    id: brAutoSwitch
                                    visible: brightnessController.available
                                    Layout.alignment: Qt.AlignVCenter
                                    padding: 0
                                    checked: brightnessController.autoMode
                                    onToggled: brightnessController.autoMode = checked
                                    Accessible.name: "自动调节亮度"
                                    ToolTip.visible: hovered
                                    ToolTip.delay: 500
                                    ToolTip.text: "按环境光自动调节屏幕亮度"

                                    indicator: Rectangle {
                                        implicitWidth: root.compact ? 42 : 48
                                        implicitHeight: root.compact ? 22 : 26
                                        radius: height / 2
                                        color: brAutoSwitch.checked
                                               ? Qt.rgba(245 / 255, 164 / 255, 0, 0.28)
                                               : Qt.rgba(1, 1, 1, 0.10)
                                        border.width: 1
                                        border.color: brAutoSwitch.checked ? root.accentBlue : root.glassBorder
                                        Behavior on color { ColorAnimation { duration: 140 } }

                                        Rectangle {
                                            x: brAutoSwitch.checked ? parent.width - width - 3 : 3
                                            anchors.verticalCenter: parent.verticalCenter
                                            width: parent.height - 6
                                            height: parent.height - 6
                                            radius: height / 2
                                            color: brAutoSwitch.checked ? root.accentBlue : root.mutedText
                                            Behavior on x { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
                                            Behavior on color { ColorAnimation { duration: 140 } }
                                        }
                                    }
                                    contentItem: Item {}
                                }
                            }

                            Rectangle {
                                anchors.top: brTopBar.bottom
                                anchors.topMargin: root.compact ? 16 : 24
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.bottom: parent.bottom
                                radius: 22
                                color: root.glassPanel
                                border.width: 1
                                border.color: root.glassBorder

                                // 设备不支持（host x86 / 无 backlight 节点）
                                Text {
                                    anchors.centerIn: parent
                                    visible: !brightnessController.available
                                    width: parent.width - 64
                                    horizontalAlignment: Text.AlignHCenter
                                    wrapMode: Text.WordWrap
                                    text: "当前设备不支持亮度调节\n（未找到背光节点）"
                                    color: root.mutedText
                                    font.family: root.uiFamily
                                    font.pixelSize: root.compact ? 15 : 18
                                }

                                ColumnLayout {
                                    visible: brightnessController.available
                                    anchors.centerIn: parent
                                    width: Math.min(parent.width - (root.compact ? 48 : 96), 560)
                                    spacing: root.compact ? 20 : 30

                                    Text {
                                        Layout.alignment: Qt.AlignHCenter
                                        text: brightnessController.brightness + "%"
                                        color: root.pageText
                                        font.family: root.uiFamily
                                        font.pixelSize: root.compact ? 56 : 74
                                        font.bold: true
                                    }

                                    Text {
                                        Layout.alignment: Qt.AlignHCenter
                                        text: brightnessController.autoMode ? "自动模式 · 跟随环境光" : "手动模式"
                                        color: brightnessController.autoMode ? root.accentBlue : root.mutedText
                                        font.family: root.uiFamily
                                        font.pixelSize: root.compact ? 13 : 15
                                    }

                                    RowLayout {
                                        Layout.fillWidth: true
                                        Layout.topMargin: root.compact ? 4 : 8
                                        spacing: 16

                                        Text {
                                            text: root.mdi("F00DE")
                                            color: root.softText
                                            font.family: root.iconFamily
                                            font.pixelSize: 18
                                        }

                                        Slider {
                                            id: brightnessSlider
                                            Layout.fillWidth: true
                                            from: 0
                                            to: 100
                                            stepSize: 1
                                            value: brightnessController.brightness
                                            // 拖动即转手动：关自动 + 写亮度
                                            onMoved: {
                                                brightnessController.autoMode = false
                                                brightnessController.setBrightness(value)
                                            }

                                            background: Rectangle {
                                                x: brightnessSlider.leftPadding
                                                y: brightnessSlider.topPadding + brightnessSlider.availableHeight / 2 - 3
                                                width: brightnessSlider.availableWidth
                                                height: 6
                                                radius: 3
                                                color: Qt.rgba(1, 1, 1, 0.10)

                                                Rectangle {
                                                    width: brightnessSlider.visualPosition * parent.width
                                                    height: parent.height
                                                    radius: 3
                                                    color: root.accentBlue
                                                }
                                            }

                                            handle: Rectangle {
                                                x: brightnessSlider.leftPadding + brightnessSlider.visualPosition * (brightnessSlider.availableWidth - width)
                                                y: brightnessSlider.topPadding + brightnessSlider.availableHeight / 2 - height / 2
                                                width: root.compact ? 22 : 26
                                                height: width
                                                radius: width / 2
                                                color: root.accentBlue
                                                border.color: Qt.rgba(0, 0, 0, 0.40)
                                                border.width: 1
                                            }
                                        }

                                        Text {
                                            text: root.mdi("F00E0")
                                            color: root.pageText
                                            font.family: root.iconFamily
                                            font.pixelSize: 26
                                        }
                                    }

                                    RowLayout {
                                        Layout.alignment: Qt.AlignHCenter
                                        Layout.topMargin: root.compact ? 4 : 8
                                        spacing: root.compact ? 10 : 14

                                        Repeater {
                                            model: [25, 50, 75, 100]
                                            delegate: Button {
                                                id: presetBtn
                                                text: modelData + "%"
                                                hoverEnabled: true
                                                Layout.preferredWidth: root.compact ? 72 : 88
                                                Layout.preferredHeight: root.compact ? 38 : 44
                                                onClicked: {
                                                    brightnessController.autoMode = false
                                                    brightnessController.setBrightness(modelData)
                                                }
                                                background: Rectangle {
                                                    radius: 12
                                                    color: presetBtn.down
                                                           ? Qt.rgba(245 / 255, 164 / 255, 0, 0.18)
                                                           : (presetBtn.hovered ? Qt.rgba(1, 1, 1, 0.08) : Qt.rgba(1, 1, 1, 0.04))
                                                    border.width: 1
                                                    border.color: root.glassBorder
                                                    Behavior on color { ColorAnimation { duration: 120 } }
                                                }
                                                contentItem: Text {
                                                    text: presetBtn.text
                                                    color: root.pageText
                                                    font.family: root.uiFamily
                                                    font.pixelSize: root.compact ? 13 : 15
                                                    horizontalAlignment: Text.AlignHCenter
                                                    verticalAlignment: Text.AlignVCenter
                                                }
                                            }
                                        }
                                    }

                                    Text {
                                        Layout.alignment: Qt.AlignHCenter
                                        Layout.topMargin: root.compact ? 6 : 12
                                        text: "当前环境光照：" + (sensorService.ambientValid
                                              ? Math.round(sensorService.ambientLux) + " lx"
                                              : "—")
                                        color: root.softText
                                        font.family: root.uiFamily
                                        font.pixelSize: root.compact ? 13 : 15
                                    }
                                }
                            }
                        }
                    }
                }

                Loader {
                    anchors.fill: parent
                    visible: root.functionPage === "imu"
                    active: root.functionPage === "imu"
                    asynchronous: false
                    sourceComponent: Component {
                        ImuPage {
                            host: root
                            service: imuService
                        }
                    }
                }

                Loader {
                    anchors.fill: parent
                    visible: root.functionPage === "camera"
                    active: root.functionPage === "camera"
                    asynchronous: false
                    sourceComponent: cameraPageComponent
                }

                Loader {
                    anchors.fill: parent
                    visible: root.functionPage === "weather"
                    active: root.functionPage === "weather"
                    asynchronous: false
                    sourceComponent: weatherPageComponent
                }

                Loader {
                    anchors.fill: parent
                    visible: root.functionPage === "video"
                    active: root.functionPage === "video"
                    asynchronous: false
                    sourceComponent: videoPageComponent
                }

                Loader {
                    anchors.fill: parent
                    visible: root.functionPage === "music"
                    active: root.functionPage === "music"
                    asynchronous: false
                    sourceComponent: musicPageComponent
                }

                Loader {
                    anchors.fill: parent
                    visible: root.functionPage === "ai"
                    active: root.functionPage === "ai"
                    asynchronous: false
                    sourceComponent: aiPageComponent
                }

                Loader {
                    anchors.fill: parent
                    visible: root.functionPage === "thermo"
                    active: root.functionPage === "thermo"
                    asynchronous: false
                    sourceComponent: thermoPageComponent
                }

                Loader {
                    anchors.fill: parent
                    visible: root.functionPage === "bodytemp"
                    active: root.functionPage === "bodytemp"
                    asynchronous: false
                    sourceComponent: bodyTempPageComponent
                }

                Loader {
                    anchors.fill: parent
                    visible: root.functionPage === "brightness"
                    active: root.functionPage === "brightness"
                    asynchronous: false
                    sourceComponent: brightnessPageComponent
                }
            }
        }

    }   // === ColumnLayout 关 ===

    // ↓↓↓ nav 从 ColumnLayout 里搬出来，独立锚定 root 底部，永远不被中间内容挤下屏 ↓↓↓
    Item {
        id: navOverlay
        anchors.left: root.left
        anchors.right: root.right
        anchors.bottom: root.bottom
        anchors.leftMargin: root.pageMargin
        anchors.rightMargin: root.pageMargin
        anchors.bottomMargin: root.pageMargin
        height: root.navReserve
        visible: root.navVisible
        z: 100

        Rectangle {
            anchors.fill: navPanel
            anchors.topMargin: 11
            radius: navPanel.radius
            color: root.shadowTint
        }

        Rectangle {
            id: navPanel
            anchors.fill: parent
            radius: root.compact ? 26 : 30
            color: root.glassPanel
            border.width: 1
            border.color: root.glassBorder

            RowLayout {
                anchors.fill: parent
                anchors.margins: root.compact ? 12 : 14
                spacing: root.compact ? 12 : 16

                Repeater {
                    model: navItems

                    delegate: Button {
                        id: navButton
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        hoverEnabled: true
                        focusPolicy: Qt.StrongFocus
                        Accessible.name: model.label + "标签"
                        ToolTip.visible: hovered
                        ToolTip.delay: 500
                        ToolTip.text: String(model.hint)
                        enabled: !root.switchingPage
                        onClicked: {
                            if (root.activeNavIndex !== index) {
                                root.switchingPage = true
                                root.functionPage = "grid"
                                root.activeNavIndex = index
                                switchGuardTimer.restart()
                            }
                        }

                        background: Rectangle {
                            radius: root.compact ? 20 : 24
                            color: root.activeNavIndex === index
                                   ? Qt.rgba(245 / 255, 164 / 255, 0, 0.18)
                                   : navButton.down
                                     ? Qt.rgba(245 / 255, 164 / 255, 0, 0.14)
                                     : navButton.hovered
                                       ? Qt.rgba(245 / 255, 164 / 255, 0, 0.09)
                                       : Qt.rgba(38 / 255, 40 / 255, 42 / 255, 0.48)
                            border.width: 1
                            border.color: root.activeNavIndex === index
                                          ? Qt.rgba(245 / 255, 164 / 255, 0, 0.56)
                                          : Qt.rgba(1, 1, 1, 0.20)

                            Behavior on color {
                                ColorAnimation { duration: 120 }
                            }
                        }

                        contentItem: Item {
                            Row {
                                anchors.centerIn: parent
                                spacing: root.compact ? 12 : 16

                                Item {
                                    width: root.compact ? 30 : 38
                                    height: width
                                    anchors.verticalCenter: parent.verticalCenter

                                    Image {
                                        id: customNavIcon
                                        anchors.fill: parent
                                        source: root.customNavIconSource(model.iconFile)
                                        fillMode: Image.PreserveAspectFit
                                        asynchronous: true
                                        cache: true
                                        smooth: true
                                        mipmap: true
                                        opacity: root.activeNavIndex === index ? 1.0 : 0.78
                                        visible: status === Image.Ready
                                        Behavior on opacity { NumberAnimation { duration: 120 } }
                                    }

                                    Text {
                                        anchors.centerIn: parent
                                        visible: customNavIcon.status !== Image.Ready
                                        text: root.mdi(model.glyph)
                                        color: root.activeNavIndex === index ? root.accentBlue : root.accentCyan
                                        font.family: root.iconFamily
                                        font.pixelSize: root.compact ? 28 : 36
                                    }
                                }

                                Text {
                                    id: navLabel
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: model.label
                                    color: root.activeNavIndex === index ? root.accentBlue : root.pageText
                                    font.family: root.uiFamily
                                    font.pixelSize: root.compact ? 18 : 22
                                    font.bold: true
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    // ↑↑↑ navOverlay 结束 ↑↑↑

    Rectangle {
        id: imuCriticalBanner
        anchors.top: parent.top
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.topMargin: root.compact ? 16 : 24
        width: Math.min(parent.width - 40, root.compact ? 620 : 760)
        height: root.compact ? 76 : 88
        radius: 20
        visible: root.imuAlertVisible
        color: Qt.rgba(74 / 255, 22 / 255, 20 / 255, 0.96)
        border.width: 2
        border.color: root.accentDanger
        z: 500

        RowLayout {
            anchors.fill: parent
            anchors.margins: root.compact ? 14 : 18
            spacing: 14
            Text {
                text: root.mdi("F0026")
                color: root.accentDanger
                font.family: root.iconFamily
                font.pixelSize: root.compact ? 30 : 36
            }
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 3
                Text {
                    Layout.fillWidth: true
                    text: root.imuAlertTitle
                    color: root.pageText
                    font.family: root.uiFamily
                    font.pixelSize: root.compact ? 16 : 19
                    font.bold: true
                    elide: Text.ElideRight
                }
                Text {
                    Layout.fillWidth: true
                    text: root.imuAlertDetail + " · 请结合视频与人工检查确认"
                    color: root.mutedText
                    font.family: root.uiFamily
                    font.pixelSize: root.compact ? 11 : 13
                    elide: Text.ElideRight
                }
            }
            Text {
                text: "×"
                color: root.mutedText
                font.pixelSize: 28
            }
        }

        MouseArea {
            anchors.fill: parent
            onClicked: root.imuAlertVisible = false
        }
    }
}
