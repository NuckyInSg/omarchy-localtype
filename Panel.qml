import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "app.localtype.voice-input"
  ipcTarget: "app.localtype.voice-input"
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.5)
  readonly property color surface: Color.popups.background
  readonly property color track: Style.selectedFillFor(foreground, Color.accent)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property string resolvedCtlPath: decodeURIComponent(String(Qt.resolvedUrl("bin/localtypectl")).replace(/^file:\/\//, ""))

  property string selectedMode: String(setting("defaultMode", "Smart")) === "Verbatim" ? "raw" : "smart"
  property bool cursorActive: false
  property var localSettings: ({})
  readonly property string language: String(localSettings.language || "en")

  function alpha(color, opacity) { return Qt.rgba(color.r, color.g, color.b, opacity) }
  function clamp(value, minimum, maximum) { return Math.max(minimum, Math.min(maximum, value)) }
  function l(english, chinese) { return language === "zh" ? chinese : english }
  function shortcut(mode) {
    var value = String(mode === "smart" ? (localSettings.smart_shortcut || "F9") : (localSettings.raw_shortcut || "SHIFT + F9"))
    return value.replace(/\s*\+\s*/g, "+").replace("SHIFT", "Shift").replace("CTRL", "Ctrl").replace("ALT", "Alt").replace("SUPER", "Super")
  }
  function applySettings(output) {
    try {
      var value = JSON.parse(String(output || "{}"))
      localSettings = value && typeof value === "object" ? value : ({})
      selectedMode = String(localSettings.default_mode || "smart")
    } catch (error) { /* Keep English defaults if settings are unavailable. */ }
  }

  function phaseTitle() {
    if (runtimeState.recording) return l("Listening", "正在聆听")
    if (runtimeState.processing) return l("Processing", "正在处理")
    if (runtimeState.installing) return l("Installing local engine", "正在安装本地引擎")
    if (runtimeState.phase === "error") return l("Needs attention", "需要处理")
    if (!runtimeState.serviceActive) return l("Service offline", "服务离线")
    if (!runtimeState.backendReady) return l("Loading models", "正在加载模型")
    return l("Ready", "就绪")
  }

  function phaseMeta() {
    if (runtimeState.recording) return selectedMode === "smart" ? l("SMART DICTATION", "智能听写") : l("VERBATIM DICTATION", "原文听写")
    if (runtimeState.processing) return l("TRANSCRIBING LOCALLY", "正在本地识别")
    if (runtimeState.installing) return l("FIRST-RUN SETUP", "首次运行设置")
    if (runtimeState.phase === "error") return l("LAST REQUEST FAILED", "上次请求失败")
    if (!runtimeState.serviceActive) return l("START THE LOCAL SERVICE", "启动本地服务")
    if (!runtimeState.backendReady) return l("GPU WARMING UP", "GPU 正在预热")
    return l("LOCAL · PRIVATE · CHINESE", "本地 · 私密 · 中文")
  }

  function actionLabel() {
    if (runtimeState.recording) return l("Stop & type", "停止并输入")
    if (runtimeState.installing || runtimeState.processing || runtimeState.actionRunning) return l("Working…", "处理中…")
    if (!runtimeState.serviceActive) return l("Start service", "启动服务")
    if (!runtimeState.backendReady) return l("Models are loading", "模型正在加载")
    return selectedMode === "smart" ? l("Start smart dictation", "开始智能听写") : l("Start verbatim dictation", "开始原文听写")
  }

  function actionIcon() {
    if (runtimeState.recording) return "󰓛"
    if (runtimeState.processing || runtimeState.actionRunning) return "󰔟"
    if (!runtimeState.serviceActive) return "󰐊"
    return "󰍬"
  }

  function runPrimaryAction() {
    if (runtimeState.actionRunning || runtimeState.processing || runtimeState.installing) return
    if (!runtimeState.serviceActive) runtimeState.runAction(["start"])
    else if (runtimeState.backendReady || runtimeState.recording) runtimeState.runAction(["toggle", selectedMode])
  }

  function shortGpuName() {
    var name = String(runtimeState.gpu.name || "CPU")
    return name.replace("NVIDIA GeForce ", "").replace(" Laptop GPU", "")
  }

  function gpuRatio() {
    var total = Number(runtimeState.gpu.memory_total_mib || 0)
    return total > 0 ? clamp(Number(runtimeState.gpu.memory_used_mib || 0) / total, 0, 1) : 0
  }

  function formatMemory(mebibytes) {
    var value = Number(mebibytes || 0)
    return value >= 1024 ? (value / 1024).toFixed(1) + " GiB" : Math.round(value) + " MiB"
  }

  function lastText() {
    var value = String(runtimeState.record.last_text || "")
    return value === "" ? l("Your latest dictation will appear here.", "最近一次听写会显示在这里。") : value
  }

  function errorText() {
    if (runtimeState.actionError !== "") return runtimeState.actionError
    return String(runtimeState.record.error || "")
  }

  visible: true
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    cursorActive = false
    runtimeState.refresh()
    if (!settingsProcess.running) settingsProcess.running = true
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  LocalTypeState {
    id: runtimeState
    ctlPath: root.resolvedCtlPath
    refreshInterval: Number(root.setting("refreshIntervalMs", 3000))
  }

  Process {
    id: settingsProcess
    running: false
    command: [root.resolvedCtlPath, "settings-show"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applySettings(text)
    }
  }

  Component.onCompleted: settingsProcess.running = true

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function record(): string { root.selectedMode = "smart"; root.runPrimaryAction(); return "ok" }
    function verbatim(): string { root.selectedMode = "raw"; root.runPrimaryAction(); return "ok" }
    function cancel(): string { runtimeState.runAction(["cancel"]); return "ok" }
    function refresh(): string { runtimeState.refresh(); return "ok" }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: runtimeState.serviceActive ? "󰍬" : "󰍭"
    active: runtimeState.recording || runtimeState.processing
    tooltipText: runtimeState.recording ? root.l("LocalType is listening", "LocalType 正在聆听") : (runtimeState.backendReady ? root.l("LocalType ready", "LocalType 已就绪") : root.l("LocalType offline", "LocalType 离线"))
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) root.runPrimaryAction()
      else if (buttonCode === Qt.MiddleButton) {
        root.selectedMode = root.selectedMode === "smart" ? "raw" : "smart"
      } else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(contentColumn.implicitHeight, Style.space(680))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onMoveRequested: function(dx, dy) {
        if (dx !== 0) {
          root.cursorActive = true
          root.selectedMode = dx < 0 ? "smart" : "raw"
        }
        if (dy !== 0)
          panelFlick.contentY = root.clamp(panelFlick.contentY + dy * Style.space(52), 0,
                                           Math.max(0, panelFlick.contentHeight - panelFlick.height))
      }
      onActivateRequested: root.runPrimaryAction()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text) {
        if (text === "r" || text === "R") runtimeState.refresh()
        else if (text === "s" || text === "S") root.selectedMode = "smart"
        else if (text === "v" || text === "V") root.selectedMode = "raw"
        else if ((text === "c" || text === "C") && runtimeState.recording) runtimeState.runAction(["cancel"])
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: contentColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: contentColumn
          width: panelFlick.width
          spacing: Style.space(12)

          PanelHero {
            width: parent.width
            title: "LocalType"
            meta: root.phaseMeta()
            detail: root.phaseTitle().toUpperCase()
            foreground: root.foreground
            fontFamily: root.fontFamily

            iconComponent: Component {
              Text {
                text: runtimeState.serviceActive ? "󰍬" : "󰍭"
                color: runtimeState.phase === "error" ? root.urgent : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
          }

          PanelSeparator { foreground: root.foreground }

          Column {
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              text: root.l("STATUS", "状态")
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Item {
              width: parent.width
              implicitHeight: Math.max(statusLabel.implicitHeight, statusValue.implicitHeight)

              Text {
                id: statusLabel
                text: root.phaseTitle()
                color: runtimeState.phase === "error" ? root.urgent : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: statusValue
                text: runtimeState.installing ? root.l("INSTALLING", "安装中") : (runtimeState.backendReady ? "GPU" : (runtimeState.serviceActive ? root.l("LOADING", "加载中") : root.l("OFFLINE", "离线")))
                color: runtimeState.backendReady ? root.foreground : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            Meter {
              width: parent.width
              value: runtimeState.recording ? 1 : root.gpuRatio()
              active: runtimeState.recording
            }

            Item {
              width: parent.width
              implicitHeight: Math.max(modelCaption.implicitHeight, memoryCaption.implicitHeight)

              Text {
                id: modelCaption
                text: String(runtimeState.record.asr_model || "Qwen3-ASR-1.7B")
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
                anchors.left: parent.left
                anchors.right: memoryCaption.left
                anchors.rightMargin: Style.spacing.md
              }

              Text {
                id: memoryCaption
                text: root.formatMemory(runtimeState.gpu.memory_used_mib) + " / " + root.formatMemory(runtimeState.gpu.memory_total_mib)
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                anchors.right: parent.right
              }
            }
          }

          ErrorCard {
            visible: root.errorText() !== ""
            width: parent.width
            message: root.errorText()
          }

          PanelSeparator { foreground: root.foreground }

          Column {
            width: parent.width
            spacing: Style.spacing.md

            PanelSectionHeader {
              text: root.l("DICTATION", "听写")
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Row {
              width: parent.width
              spacing: Style.spacing.md

              Button {
                width: (parent.width - parent.spacing) / 2
                text: root.l("SMART", "智能")
                iconText: "󰧑"
                selected: root.selectedMode === "smart"
                hasCursor: root.cursorActive && root.selectedMode === "smart"
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                onClicked: {
                  root.cursorActive = true
                  root.selectedMode = "smart"
                }
              }

              Button {
                width: (parent.width - parent.spacing) / 2
                text: root.l("VERBATIM", "原文")
                iconText: "󰑋"
                selected: root.selectedMode === "raw"
                hasCursor: root.cursorActive && root.selectedMode === "raw"
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                onClicked: {
                  root.cursorActive = true
                  root.selectedMode = "raw"
                }
              }
            }

            Button {
              width: parent.width
              text: root.actionLabel()
              iconText: root.actionIcon()
              iconSpinning: runtimeState.processing || runtimeState.actionRunning
              active: runtimeState.recording || runtimeState.backendReady
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.body
              verticalPadding: Style.spacing.lg
              onClicked: root.runPrimaryAction()
            }

            Row {
              width: parent.width
              spacing: Style.spacing.md

              Button {
                visible: runtimeState.recording
                width: parent.width
                text: root.l("Cancel recording", "取消录音")
                iconText: "󰅖"
                bordered: true
                foreground: root.urgent
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                onClicked: runtimeState.runAction(["cancel"])
              }
            }

            Text {
              width: parent.width
              text: root.selectedMode === "smart"
                ? root.shortcut("smart") + root.l(" · removes filler words and fixes punctuation", " · 去除语气词并修正标点")
                : root.shortcut("raw") + root.l(" · preserves the recognized wording", " · 忠实保留识别原文")
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              horizontalAlignment: Text.AlignHCenter
            }
          }

          PanelSeparator {
            visible: root.setting("showRecentText", true)
            foreground: root.foreground
          }

          Column {
            visible: root.setting("showRecentText", true)
            width: parent.width
            spacing: Style.spacing.md

            PanelSectionHeader {
              text: root.l("RECENT", "最近听写")
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            BorderSurface {
              width: parent.width
              implicitHeight: recentText.implicitHeight + Style.space(20)
              color: root.alpha(root.foreground, 0.05)
              borderSpec: Border.flat(root.alpha(root.foreground, 0.10), 1)
              radius: Style.cornerRadius

              Text {
                id: recentText
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.space(10)
                anchors.rightMargin: Style.space(10)
                text: root.lastText()
                color: String(runtimeState.record.last_text || "") === "" ? root.dim : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                maximumLineCount: 4
                elide: Text.ElideRight
                wrapMode: Text.Wrap
              }

              MouseArea {
                anchors.fill: parent
                enabled: String(runtimeState.record.last_text || "") !== ""
                cursorShape: Qt.PointingHandCursor
                onClicked: runtimeState.runAction(["copy-recent"])
              }
            }

            Text {
              visible: String(runtimeState.record.last_text || "") !== ""
              width: parent.width
              text: root.l("Click the card to copy it", "点击卡片即可复制")
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              horizontalAlignment: Text.AlignRight
            }
          }

          PanelSeparator { foreground: root.foreground }

          Column {
            width: parent.width
            spacing: Style.spacing.md

            PanelSectionHeader {
              text: root.l("MODELS", "模型")
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            ModelRow {
              width: parent.width
              name: "Qwen3-ASR-1.7B"
              role: root.l("SPEECH", "识别")
              fill: 1
            }

            ModelRow {
              width: parent.width
              name: "Qwen3-0.6B"
              role: root.l("POLISH", "润色")
              fill: 0.68
            }
          }

          Row {
            width: parent.width
            spacing: Style.spacing.md

            Button {
              width: (parent.width - parent.spacing) / 2
              text: root.l("Open app", "打开应用")
              iconText: "󰆍"
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              onClicked: {
                runtimeState.runAction(["open"])
                root.close()
              }
            }

            Button {
              width: (parent.width - parent.spacing) / 2
              text: root.l("Restart service", "重启服务")
              iconText: "󰜉"
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              onClicked: runtimeState.runAction(["restart"])
            }
          }

          Text {
            width: parent.width
            text: root.shortGpuName() + root.l(" · audio stays on this device", " · 音频不会离开本机")
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
          }
        }
      }
    }
  }

  component Meter: Item {
    id: meter
    property real value: 0
    property bool active: false
    implicitHeight: Math.max(Style.space(4), Math.round(Style.spacing.controlHeight * 0.14))

    Rectangle {
      anchors.fill: parent
      radius: height / 2
      color: root.track
    }

    Rectangle {
      anchors.left: parent.left
      anchors.top: parent.top
      anchors.bottom: parent.bottom
      width: parent.width * root.clamp(meter.value, 0, 1)
      radius: height / 2
      color: meter.active ? Color.accent : root.foreground

      Behavior on width { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
    }
  }

  component ModelRow: Item {
    id: modelRow
    property string name: ""
    property string role: ""
    property real fill: 0
    implicitHeight: modelName.implicitHeight + Style.spacing.lg

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius
      color: root.alpha(root.foreground, 0.05)
    }

    Rectangle {
      anchors.left: parent.left
      anchors.top: parent.top
      anchors.bottom: parent.bottom
      width: parent.width * modelRow.fill
      radius: Style.cornerRadius
      color: root.alpha(root.foreground, 0.14)
    }

    Text {
      id: modelName
      text: modelRow.name
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      anchors.left: parent.left
      anchors.leftMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
    }

    Text {
      text: modelRow.role
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      anchors.right: parent.right
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
    }
  }

  component ErrorCard: BorderSurface {
    id: errorCard
    property string message: ""
    implicitHeight: errorMessage.implicitHeight + Style.spacing.xl * 2
    color: root.alpha(root.urgent, 0.10)
    borderSpec: Border.flat(root.alpha(root.urgent, 0.35), 1)
    radius: Style.cornerRadius

    Text {
      id: errorMessage
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(12)
      anchors.rightMargin: Style.space(12)
      text: errorCard.message
      color: root.urgent
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }
  }
}
