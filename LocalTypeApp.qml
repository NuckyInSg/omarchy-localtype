pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Item {
  id: root

  property var shell: null
  property bool closingFromHost: false
  property string currentPage: "workspace"
  property string selectedMode: "smart"
  property string language: "en"
  property var allHistory: []
  property var historyEntries: []
  property string historyQuery: ""
  property var dictionaryEntries: []
  property var scenes: []
  property var settings: ({})
  property int selectedSceneIndex: 0
  property string queuedDataset: ""
  property var queuedArgs: []
  property string refreshAfterAction: ""
  property bool confirmClearHistory: false
  property string dataError: ""

  readonly property color foreground: Color.foreground
  readonly property color background: Color.background
  readonly property color accent: Color.accent
  readonly property color urgent: Color.urgent
  readonly property color muted: Color.muted
  readonly property color sidebarColor: Qt.darker(Color.background, 1.22)
  readonly property color deepColor: Qt.darker(Color.background, 1.10)
  readonly property string fontFamily: Style.font.family
  readonly property string ctlPath: decodeURIComponent(String(Qt.resolvedUrl("bin/localtypectl")).replace(/^file:\/\//, ""))

  function alpha(color, opacity) { return Qt.rgba(color.r, color.g, color.b, opacity) }
  function clamp(value, minimum, maximum) { return Math.max(minimum, Math.min(maximum, value)) }
  function l(english, chinese) { return language === "zh" ? chinese : english }
  function shortcut(mode) {
    var value = String(mode === "smart" ? (settings.smart_shortcut || "F9") : (settings.raw_shortcut || "SHIFT + F9"))
    return value.replace(/\s*\+\s*/g, "+").replace("SHIFT", "Shift").replace("CTRL", "Ctrl").replace("ALT", "Alt").replace("SUPER", "Super")
  }
  function sceneDescription(scene) {
    if (language === "zh") return String(scene.description || "")
    if (scene.id === "codex") return "Preserve technical terms and commands; use concise Markdown"
    if (scene.id === "chromium") return "General polishing with automatic punctuation"
    if (scene.id === "slack") return "Conversational and concise; never add headings"
    if (scene.id === "obsidian") return "Organize paragraphs, lists, and short headings"
    return String(scene.description || "")
  }
  function sceneStyleValue(value) {
    if (language === "zh") return String(value || "技术")
    var styles = ({ "技术": "Technical", "通用": "General", "聊天": "Chat", "笔记": "Notes", "正式": "Formal" })
    return String(styles[value] || value || "Technical")
  }
  function sceneStyleStorage(value) {
    if (language === "zh") return String(value)
    var styles = ({ "Technical": "技术", "General": "通用", "Chat": "聊天", "Notes": "笔记", "Formal": "正式" })
    return String(styles[value] || value)
  }
  function pageTitle() {
    if (currentPage === "workspace") return l("Voice Workspace", "语音工作台")
    if (currentPage === "history") return l("Dictation History", "听写历史")
    if (currentPage === "dictionary") return l("Personal Dictionary", "个人词典")
    if (currentPage === "scenes") return l("App Scenes", "应用场景")
    if (currentPage === "models") return l("Local Models", "本地模型")
    return l("Settings", "设置")
  }
  function pageSubtitle() {
    if (currentPage === "workspace") return l("Local smart voice input", "本地智能语音输入")
    if (currentPage === "history") return l("Find, reuse, and compare original and polished transcripts", "查找、复用和对比原始语音与润色结果")
    if (currentPage === "dictionary") return l("Improve names, product terms, and correction rules", "让专有名词、人名与纠错规则识别得更准确")
    if (currentPage === "scenes") return l("Adapt tone, formatting, and output to the active app", "根据当前应用自动调整语气、格式与输出方式")
    if (currentPage === "models") return l("Manage speech recognition and text polishing models", "管理语音识别与智能润色模型")
    return l("Manage language, shortcuts, privacy, and local data", "管理语言、快捷键、隐私与本地数据")
  }
  function pageComponent() {
    if (currentPage === "workspace") return workspacePage
    if (currentPage === "history") return historyPage
    if (currentPage === "dictionary") return dictionaryPage
    if (currentPage === "scenes") return scenesPage
    if (currentPage === "models") return modelsPage
    return settingsPage
  }
  function open(payloadJson) {
    closingFromHost = false
    appWindow.visible = true
    if (payloadJson) {
      try {
        var payload = JSON.parse(String(payloadJson))
        var requestedPage = String(payload.page || "")
        if (["workspace", "history", "dictionary", "scenes", "models", "settings"].indexOf(requestedPage) !== -1)
          currentPage = requestedPage
      } catch (error) { /* Ignore malformed optional launch payloads. */ }
    }
    runtimeState.refresh()
    loadDataset("settings", ["settings-show"])
    loadCurrentPage()
    Qt.callLater(function() { appFocus.forceActiveFocus() })
  }
  function close() {
    closingFromHost = true
    appWindow.visible = false
    closingFromHost = false
  }
  function requestClose() {
    if (shell && typeof shell.hide === "function") shell.hide("app.localtype.voice-input")
    else appWindow.visible = false
  }
  function navigate(page) {
    currentPage = page
    loadCurrentPage()
  }
  function loadCurrentPage() {
    if (currentPage === "workspace") {
      runtimeState.refresh()
      loadDataset("history", ["history-list"])
    } else if (currentPage === "history") loadDataset("history", ["history-list"])
    else if (currentPage === "dictionary") loadDataset("dictionary", ["dictionary-list"])
    else if (currentPage === "scenes") loadDataset("scenes", ["scenes-list"])
    else if (currentPage === "settings") loadDataset("settings", ["settings-show"])
    else runtimeState.refresh()
  }
  function loadDataset(dataset, args) {
    if (dataProcess.running) {
      queuedDataset = dataset
      queuedArgs = args
      return
    }
    dataError = ""
    dataProcess.dataset = dataset
    dataProcess.command = [ctlPath].concat(args)
    dataProcess.running = true
  }
  function applyDataset(dataset, output) {
    try {
      var value = JSON.parse(String(output || (dataset === "settings" ? "{}" : "[]")))
      if (dataset === "history") {
        allHistory = Array.isArray(value) ? value : []
        filterHistory(historyQuery)
      } else if (dataset === "dictionary") dictionaryEntries = Array.isArray(value) ? value : []
      else if (dataset === "scenes") {
        scenes = Array.isArray(value) ? value : []
        selectedSceneIndex = clamp(selectedSceneIndex, 0, Math.max(0, scenes.length - 1))
      } else if (dataset === "settings") {
        settings = value && typeof value === "object" ? value : ({})
        language = String(settings.language || "en")
        selectedMode = String(settings.default_mode || "smart")
      }
    } catch (error) {
      dataError = l("Local data could not be read", "本地数据无法读取")
    }
  }
  function filterHistory(query) {
    var needle = String(query || "").toLowerCase()
    if (needle === "") {
      historyEntries = allHistory.slice()
      return
    }
    historyEntries = allHistory.filter(function(entry) {
      return String(entry.final_text || "").toLowerCase().indexOf(needle) !== -1
        || String(entry.raw_text || "").toLowerCase().indexOf(needle) !== -1
        || String(entry.application_title || "").toLowerCase().indexOf(needle) !== -1
    })
  }
  function runAction(args, refreshDataset) {
    if (actionProcess.running) return
    dataError = ""
    root.refreshAfterAction = refreshDataset || ""
    actionProcess.command = [ctlPath].concat(args)
    actionProcess.running = true
  }
  function formatMemory(mebibytes) {
    var value = Number(mebibytes || 0)
    return value >= 1024 ? (value / 1024).toFixed(1) + " GiB" : Math.round(value) + " MiB"
  }
  function gpuRatio() {
    var total = Number(runtimeState.gpu.memory_total_mib || 0)
    return total > 0 ? clamp(Number(runtimeState.gpu.memory_used_mib || 0) / total, 0, 1) : 0
  }
  function formatTime(iso) {
    var date = new Date(String(iso || ""))
    if (isNaN(date.getTime())) return "--:--"
    return String(date.getHours()).padStart(2, "0") + ":" + String(date.getMinutes()).padStart(2, "0")
  }
  function formatDuration(milliseconds) {
    var seconds = Math.max(0, Math.round(Number(milliseconds || 0) / 1000))
    return "00:" + String(seconds).padStart(2, "0")
  }
  function recentEntry() {
    return allHistory.length > 0 ? allHistory[0] : ({})
  }
  function recentText() {
    return String(runtimeState.record.last_text || recentEntry().final_text || l("Your polished transcript will appear here after dictation.", "完成一次听写后，整理结果会显示在这里。"))
  }
  function recentUpdatedAt() {
    return String(runtimeState.record.updated_at || recentEntry().created_at || "")
  }
  function phaseTitle() {
    if (runtimeState.recording) return l("Listening", "正在聆听")
    if (runtimeState.processing) return l("Transcribing locally", "正在本地识别")
    if (runtimeState.phase === "error") return l("Needs attention", "需要处理")
    if (!runtimeState.serviceActive) return l("Service offline", "服务离线")
    if (!runtimeState.backendReady) return l("Loading models", "正在加载模型")
    return l("Press " + shortcut(selectedMode) + " to start", "按 " + shortcut(selectedMode) + " 开始")
  }
  function primaryAction() {
    if (runtimeState.actionRunning || runtimeState.processing || runtimeState.installing) return
    if (!runtimeState.serviceActive) runtimeState.runAction(["start"])
    else if (runtimeState.backendReady || runtimeState.recording) runtimeState.runAction(["toggle", selectedMode])
  }
  function selectedScene() {
    return scenes.length > selectedSceneIndex ? scenes[selectedSceneIndex] : ({})
  }
  function settingSet(key, value) {
    var next = ({})
    for (var k in settings) next[k] = settings[k]
    next[key] = value
    settings = next
    if (key === "language") language = String(value)
    runAction(["setting-set", key, String(value)], "settings")
  }
  function saveShortcuts(smart, raw) {
    if (String(smart).trim() === "" || String(raw).trim() === "") return
    runAction(["shortcuts-set", String(smart).trim(), String(raw).trim()], "settings")
  }

  LocalTypeState {
    id: runtimeState
    ctlPath: root.ctlPath
    refreshInterval: 2000
    onRefreshed: if (root.currentPage === "workspace" || root.currentPage === "history")
      root.loadDataset("history", ["history-list"])
  }

  Process {
    id: dataProcess
    property string dataset: ""
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyDataset(dataProcess.dataset, text)
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim() !== "") root.dataError = text.trim()
    }
    onExited: function(exitCode, exitStatus) {
      if (root.queuedDataset !== "") {
        var dataset = root.queuedDataset
        var args = root.queuedArgs
        root.queuedDataset = ""
        root.queuedArgs = []
        root.loadDataset(dataset, args)
      }
    }
  }

  Process {
    id: actionProcess
    running: false
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim() !== "") root.dataError = text.trim()
    }
    onExited: function(exitCode, exitStatus) {
      runtimeState.refresh()
      if (root.refreshAfterAction === "history") root.loadDataset("history", ["history-list"])
      else if (root.refreshAfterAction === "dictionary") root.loadDataset("dictionary", ["dictionary-list"])
      else if (root.refreshAfterAction === "scenes") root.loadDataset("scenes", ["scenes-list"])
      else if (root.refreshAfterAction === "settings") root.loadDataset("settings", ["settings-show"])
      root.refreshAfterAction = ""
    }
  }

  Timer {
    id: clearConfirmTimer
    interval: 4500
    onTriggered: root.confirmClearHistory = false
  }

  component Surface: BorderSurface {
    color: root.alpha(root.foreground, 0.035)
    borderSpec: Border.flat(root.alpha(root.foreground, 0.18), 1)
    radius: Math.max(4, Style.cornerRadius)
  }

  component SectionLabel: Text {
    color: root.muted
    font.family: root.fontFamily
    font.pixelSize: Math.max(11, Style.font.caption)
    font.bold: true
    font.letterSpacing: 1.1
  }

  component TitleText: Text {
    color: root.foreground
    font.family: root.fontFamily
    font.pixelSize: Style.font.display
    font.bold: true
  }

  component BodyText: Text {
    color: root.foreground
    font.family: root.fontFamily
    font.pixelSize: Math.max(14, Style.font.body)
  }

  component MutedText: Text {
    color: root.muted
    font.family: root.fontFamily
    font.pixelSize: Math.max(12, Style.font.bodySmall)
  }

  component PageHeader: Item {
    property alias actionText: headerAction.text
    property alias actionIcon: headerAction.iconText
    signal actionClicked()
    height: 100
    width: parent ? parent.width : 0

    Column {
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      spacing: 5
      TitleText { text: root.pageTitle() }
      MutedText { text: root.pageSubtitle(); font.pixelSize: Style.font.subtitle }
    }

    Button {
      id: headerAction
      visible: text !== ""
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      bordered: true
      foreground: root.foreground
      accent: root.accent
      fontFamily: root.fontFamily
      fontSize: Style.font.body
      horizontalPadding: 18
      verticalPadding: 10
      onClicked: parent.actionClicked()
    }
  }

  component StatusMeter: Item {
    property real value: 0
    property color meterColor: root.accent
    implicitHeight: 5
    Rectangle { anchors.fill: parent; color: root.alpha(root.foreground, 0.10); radius: 2 }
    Rectangle {
      height: parent.height
      width: parent.width * root.clamp(parent.value, 0, 1)
      color: parent.meterColor
      radius: 2
    }
  }

  component LabeledToggle: Item {
    property string label: ""
    property string detail: ""
    property bool checked: false
    signal toggled(bool checked)
    implicitHeight: detail === "" ? 40 : 54
    width: parent ? parent.width : 0

    Column {
      anchors.left: parent.left
      anchors.right: toggle.left
      anchors.rightMargin: 16
      anchors.verticalCenter: parent.verticalCenter
      spacing: 3
      BodyText { text: parent.parent.label; width: parent.width; elide: Text.ElideRight }
      MutedText { visible: text !== ""; text: parent.parent.detail; width: parent.width; elide: Text.ElideRight }
    }
    ToggleSwitch {
      id: toggle
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      checked: parent.checked
      foreground: parent.checked ? root.accent : root.foreground
      accent: root.accent
      onToggled: parent.toggled(!parent.checked)
    }
  }

  FloatingWindow {
    id: appWindow
    title: "LocalType"
    color: root.background
    implicitWidth: 1400
    implicitHeight: 980
    minimumSize: Qt.size(1040, 720)
    visible: false

    onVisibleChanged: {
      if (!visible && !root.closingFromHost && root.shell && typeof root.shell.hide === "function")
        root.shell.hide("app.localtype.voice-input")
    }

    FocusScope {
      id: appFocus
      anchors.fill: parent
      focus: true
      Keys.onEscapePressed: root.requestClose()

      Rectangle {
        anchors.fill: parent
        color: root.background

        Column {
          anchors.fill: parent
          spacing: 0

          Rectangle {
            width: parent.width
            height: 40
            color: root.deepColor
            border.color: root.alpha(root.foreground, 0.16)
            border.width: 1

            Text {
              anchors.centerIn: parent
              text: "LocalType"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.subtitle
              font.letterSpacing: 1
            }

            Row {
              anchors.right: parent.right
              anchors.rightMargin: 10
              anchors.verticalCenter: parent.verticalCenter
              spacing: 2
              Button {
                width: 36; height: 30; text: "—"; foreground: root.muted
                onClicked: appWindow.visible = false
              }
              Button {
                width: 36; height: 30; text: "×"; foreground: root.foreground
                onClicked: root.requestClose()
              }
            }

            MouseArea {
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.rightMargin: 90
              height: parent.height
              onPressed: appWindow.startSystemMove()
            }
          }

          Row {
            width: parent.width
            height: parent.height - 40
            spacing: 0

            Rectangle {
              width: 300
              height: parent.height
              color: root.sidebarColor
              border.color: root.alpha(root.foreground, 0.14)
              border.width: 1

              Column {
                anchors.fill: parent
                anchors.margins: 22
                spacing: 18

                Row {
                  width: parent.width
                  height: 76
                  spacing: 16
                  Text {
                    text: "󰍬"
                    color: root.accent
                    font.family: root.fontFamily
                    font.pixelSize: 38
                    anchors.verticalCenter: parent.verticalCenter
                  }
                  Column {
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 4
                    Text {
                      text: "LOCALTYPE"
                      color: root.accent
                      font.family: root.fontFamily
                      font.pixelSize: Math.max(18, Style.font.heading)
                      font.bold: true
                      font.letterSpacing: 1.5
                    }
                    SectionLabel { text: root.l("LOCAL · PRIVATE · CHINESE", "本地 · 私密 · 中文") }
                  }
                }

                Column {
                  width: parent.width
                  spacing: 8
                  Repeater {
                    model: [
                      { id: "workspace", label: root.l("Workspace", "工作台"), icon: "󰆍" },
                      { id: "history", label: root.l("History", "历史"), icon: "󰋚" },
                      { id: "dictionary", label: root.l("Dictionary", "词典"), icon: "󰓹" },
                      { id: "scenes", label: root.l("Scenes", "场景"), icon: "󰙅" },
                      { id: "models", label: root.l("Models", "模型"), icon: "󰘚" },
                      { id: "settings", label: root.l("Settings", "设置"), icon: "󰒓" }
                    ]
                    delegate: Button {
                      required property var modelData
                      width: parent.width
                      height: 56
                      text: modelData.label
                      iconText: modelData.icon
                      leftAlign: true
                      bordered: false
                      selected: root.currentPage === modelData.id
                      foreground: root.currentPage === modelData.id ? root.accent : root.foreground
                      accent: root.accent
                      fontFamily: root.fontFamily
                      fontSize: Math.max(16, Style.font.subtitle)
                      horizontalPadding: 16
                      onClicked: root.navigate(modelData.id)

                      Rectangle {
                        visible: root.currentPage === parent.modelData.id
                        width: 3
                        anchors.left: parent.left
                        anchors.top: parent.top
                        anchors.bottom: parent.bottom
                        color: root.accent
                      }
                    }
                  }
                }

                Item { width: 1; height: Math.max(0, parent.height - 76 - 6 * 64 - 18 * 3 - 232) }

                Surface {
                  width: parent.width
                  height: 218

                  Column {
                    anchors.fill: parent
                    anchors.margins: 16
                    spacing: 13

                    Row {
                      spacing: 10
                      Rectangle { width: 9; height: 9; radius: 5; color: runtimeState.backendReady ? "#adda78" : root.urgent; anchors.verticalCenter: parent.verticalCenter }
                      BodyText { text: root.l("Local · Private", "本地 · 私密") }
                    }
                    Row { spacing: 10; Text { text: "󰧑"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: 16 } BodyText { text: String(runtimeState.record.asr_model || "Qwen3-ASR-1.7B") } }
                    Row { spacing: 10; Text { text: "󰚩"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: 16 } BodyText { text: String(runtimeState.record.polisher_model || "Qwen3-0.6B").replace("Qwen/", "") } }
                    Row { spacing: 10; Text { text: "󰢮"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: 16 } BodyText { text: String(runtimeState.gpu.name || "GPU").replace("NVIDIA GeForce ", "").replace(" Laptop GPU", "") } }
                    StatusMeter { width: parent.width; value: root.gpuRatio(); meterColor: root.accent }
                    MutedText { text: root.formatMemory(runtimeState.gpu.memory_used_mib) + " / " + root.formatMemory(runtimeState.gpu.memory_total_mib) + " · " + Number(runtimeState.gpu.utilization || 0) + "%" }
                  }
                }
              }
            }

            Rectangle {
              width: parent.width - 300
              height: parent.height
              color: root.background

              Column {
                anchors.fill: parent
                anchors.leftMargin: 36
                anchors.rightMargin: 36
                anchors.topMargin: 24
                anchors.bottomMargin: 18
                spacing: 12

                Loader {
                  id: pageLoader
                  width: parent.width
                  height: parent.height - footer.height - parent.spacing
                  sourceComponent: root.pageComponent()
                }

                Item {
                  id: footer
                  width: parent.width
                  height: 28
                  Rectangle { width: parent.width; height: 1; color: root.alpha(root.foreground, 0.13) }
                  MutedText {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.verticalCenterOffset: 5
                    text: (runtimeState.backendReady ? root.l("READY", "就绪") : (runtimeState.serviceActive ? root.l("LOADING", "加载中") : root.l("OFFLINE", "离线")))
                      + root.l(" · Chinese · Local inference · ", " · 中文 · 本地推理 · ") + root.formatMemory(runtimeState.gpu.memory_used_mib)
                      + " / " + root.formatMemory(runtimeState.gpu.memory_total_mib)
                  }
                  MutedText {
                    visible: root.dataError !== ""
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.verticalCenterOffset: 5
                    text: root.dataError
                    color: root.urgent
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
    id: workspacePage
    Item {
      PageHeader {
        id: workspaceHeader
        width: parent.width
        actionText: root.shortcut(root.selectedMode) + (runtimeState.recording ? root.l(" Stop", " 停止") : root.l(" Start", " 开始"))
        actionIcon: runtimeState.recording ? "󰓛" : "󰍬"
        onActionClicked: root.primaryAction()
      }

      Column {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: workspaceHeader.bottom
        anchors.bottom: parent.bottom
        spacing: 18

        Surface {
          width: parent.width
          height: Math.max(340, parent.height * 0.58)
          borderSpec: Border.flat(root.accent, 1)

          Column {
            anchors.centerIn: parent
            width: Math.min(720, parent.width - 80)
            spacing: 20

            Rectangle {
              anchors.horizontalCenter: parent.horizontalCenter
              width: 122
              height: 122
              radius: 61
              color: root.alpha(root.accent, 0.05)
              border.color: root.accent
              border.width: 1
              Text {
                anchors.centerIn: parent
                text: runtimeState.processing ? "󰔟" : (runtimeState.recording ? "󰑊" : "󰍬")
                color: runtimeState.recording ? root.urgent : root.accent
                font.family: root.fontFamily
                font.pixelSize: 52
              }
            }
            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              text: root.phaseTitle()
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
              font.bold: true
            }
            StatusMeter {
              width: parent.width
              height: runtimeState.recording ? 8 : 4
              value: runtimeState.recording || runtimeState.processing ? 1 : root.gpuRatio()
              meterColor: runtimeState.recording ? root.urgent : root.accent
            }
            MutedText {
              anchors.horizontalCenter: parent.horizontalCenter
              text: runtimeState.recording
                ? root.l("Press " + root.shortcut(root.selectedMode) + " again to stop and type", "再按一次 " + root.shortcut(root.selectedMode) + " 停止并输入")
                : root.shortcut("smart") + root.l(" smart dictation · ", " 智能听写 · ") + root.shortcut("raw") + root.l(" verbatim", " 原文听写")
              font.pixelSize: Style.font.subtitle
            }
          }
        }

        Row {
          width: parent.width
          height: 96
          spacing: 18
          Button {
            width: (parent.width - parent.spacing) / 2
            height: parent.height
            text: root.l("Smart dictation  ·  Clean up wording, grammar, and punctuation", "智能听写  ·  自动优化文本、修正语法与标点")
            iconText: "󰧑"
            selected: root.selectedMode === "smart"
            bordered: true
            foreground: root.selectedMode === "smart" ? root.accent : root.foreground
            accent: root.accent
            fontFamily: root.fontFamily
            fontSize: Style.font.subtitle
            onClicked: root.selectedMode = "smart"
          }
          Button {
            width: (parent.width - parent.spacing) / 2
            height: parent.height
            text: root.l("Verbatim dictation  ·  Preserve the recognized wording", "原文听写  ·  忠实记录原话")
            iconText: "󰑋"
            selected: root.selectedMode === "raw"
            bordered: true
            foreground: root.selectedMode === "raw" ? root.accent : root.foreground
            accent: root.accent
            fontFamily: root.fontFamily
            fontSize: Style.font.subtitle
            onClicked: root.selectedMode = "raw"
          }
        }

        Column {
          width: parent.width
          spacing: 10
          Text { text: root.l("Recent dictation", "最近听写"); color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.heading; font.bold: true }
          Surface {
            width: parent.width
            height: 116
            Column {
              anchors.fill: parent
              anchors.margins: 18
              spacing: 14
              BodyText {
                width: parent.width
                text: root.recentText()
                font.pixelSize: Style.font.subtitle
                wrapMode: Text.Wrap
                maximumLineCount: 2
                elide: Text.ElideRight
              }
              Row {
                width: parent.width
                MutedText { text: root.formatTime(root.recentUpdatedAt()) }
                Item { width: parent.width - 130; height: 1 }
                Button {
                  width: 90; text: root.l("Copy", "复制"); iconText: "󰆏"; bordered: true; foreground: root.foreground
                  onClicked: root.runAction(["copy-text", root.recentText()], "")
                }
              }
            }
          }
        }
      }
    }
  }

  Component {
    id: historyPage
    Item {
      PageHeader {
        id: historyHeader
        width: parent.width
        actionText: root.confirmClearHistory ? root.l("Click again to confirm", "再次点击确认清空") : root.l("Clear history", "清空历史")
        actionIcon: "󰩺"
        onActionClicked: {
          if (!root.confirmClearHistory) {
            root.confirmClearHistory = true
            clearConfirmTimer.restart()
          } else {
            root.confirmClearHistory = false
            root.runAction(["history-clear"], "history")
          }
        }
      }

      Column {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: historyHeader.bottom
        anchors.bottom: parent.bottom
        spacing: 16

        Row {
          width: parent.width
          spacing: 12
          TextField {
            id: historySearch
            width: parent.width - 372
            placeholderText: root.l("Search dictation…", "搜索听写内容…")
            foreground: root.foreground
            accent: root.accent
            onTextChanged: {
              root.historyQuery = text
              root.filterHistory(text)
            }
          }
          Button { width: 96; text: root.l("All", "全部"); selected: true; bordered: true; foreground: root.accent; accent: root.accent }
          Button { width: 120; text: root.l("Smart", "智能听写"); bordered: true; foreground: root.foreground }
          Button { width: 120; text: root.l("Verbatim", "原文听写"); bordered: true; foreground: root.foreground }
        }

        ScrollView {
          id: historyView
          width: parent.width
          height: parent.height - 64
          clip: true
          ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
          Column {
            width: historyView.availableWidth
            spacing: 12

            SectionLabel { text: root.l("LOCAL RECORDS · " + root.historyEntries.length, "本地记录 · " + root.historyEntries.length + " 条") }

            Repeater {
              model: root.historyEntries
              delegate: Surface {
                required property var modelData
                required property int index
                width: historyView.availableWidth
                height: Math.max(188, historyText.implicitHeight + 142)
                borderSpec: Border.flat(index === 0 ? root.accent : root.alpha(root.foreground, 0.18), 1)

                Column {
                  anchors.fill: parent
                  anchors.margins: 16
                  spacing: 11

                  Row {
                    width: parent.width
                    spacing: 16
                    BodyText { text: root.formatTime(parent.parent.parent.modelData.created_at); font.pixelSize: Style.font.subtitle }
                    SectionLabel { text: parent.parent.parent.modelData.mode === "smart" ? root.l("SMART", "智能听写") : root.l("VERBATIM", "原文听写"); color: parent.parent.parent.modelData.mode === "smart" ? root.accent : root.muted }
                    MutedText { text: root.formatDuration(parent.parent.parent.modelData.duration_ms) }
                    Rectangle { width: 1; height: 18; color: root.alpha(root.foreground, 0.18) }
                    MutedText { text: String(parent.parent.parent.modelData.application_title || parent.parent.parent.modelData.application_class || root.l("Current app", "当前应用")) }
                    Item { width: Math.max(1, parent.width - 430); height: 1 }
                    Button {
                      width: 42; iconText: "󰆏"; foreground: root.foreground
                      onClicked: root.runAction(["copy-text", String(parent.parent.parent.parent.modelData.final_text || "")], "")
                    }
                    Button {
                      width: 42; iconText: "󰩺"; foreground: root.muted
                      onClicked: root.runAction(["history-delete", String(parent.parent.parent.parent.modelData.id)], "history")
                    }
                  }
                  Rectangle { width: parent.width; height: 1; color: root.alpha(root.foreground, 0.12) }
                  SectionLabel { text: parent.parent.modelData.mode === "smart" ? root.l("POLISHED", "智能润色") : root.l("VERBATIM", "听写原文"); color: parent.parent.modelData.mode === "smart" ? root.accent : root.muted }
                  BodyText {
                    id: historyText
                    width: parent.width
                    text: String(parent.parent.modelData.final_text || "")
                    wrapMode: Text.Wrap
                    font.pixelSize: Style.font.subtitle
                  }
                  MutedText {
                    width: parent.width
                    visible: String(parent.parent.modelData.raw_text || "") !== String(parent.parent.modelData.final_text || "")
                    text: root.l("ORIGINAL · ", "原始识别 · ") + String(parent.parent.modelData.raw_text || "")
                    elide: Text.ElideRight
                  }
                }
              }
            }

            Surface {
              visible: root.historyEntries.length === 0
              width: parent.width
              height: 180
              Column {
                anchors.centerIn: parent
                spacing: 12
                Text { anchors.horizontalCenter: parent.horizontalCenter; text: "󰋚"; color: root.muted; font.family: root.fontFamily; font.pixelSize: 34 }
                MutedText { anchors.horizontalCenter: parent.horizontalCenter; text: root.historyQuery === "" ? root.l("No dictation history yet", "还没有听写记录") : root.l("No matching records", "没有找到匹配记录"); font.pixelSize: Style.font.subtitle }
              }
            }
          }
        }
      }
    }
  }

  Component {
    id: dictionaryPage
    Item {
      PageHeader { id: dictionaryHeader; width: parent.width; actionText: root.l("Refresh", "刷新"); actionIcon: "󰑐"; onActionClicked: root.loadDataset("dictionary", ["dictionary-list"]) }

      Column {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: dictionaryHeader.bottom
        anchors.bottom: parent.bottom
        spacing: 18

        Surface {
          width: parent.width
          height: 112
          borderSpec: Border.flat(root.accent, 1)
          Row {
            anchors.fill: parent
            anchors.margins: 16
            spacing: 14
            Column { width: (parent.width - 160) * 0.46; spacing: 6; SectionLabel { text: root.l("HEARD AS", "听到的词") } TextField { id: spokenField; width: parent.width; placeholderText: root.l("Example: oh-marky", "例如：欧马奇"); foreground: root.foreground; accent: root.accent } }
            Column { width: (parent.width - 160) * 0.54; spacing: 6; SectionLabel { text: root.l("REPLACE WITH", "应输出的词") } TextField { id: writtenField; width: parent.width; placeholderText: root.l("Example: Omarchy", "例如：Omarchy"); foreground: root.foreground; accent: root.accent } }
            Button {
              width: 132
              anchors.bottom: parent.bottom
              text: root.l("Add", "添加")
              iconText: "󰐕"
              bordered: true
              foreground: root.accent
              accent: root.accent
              verticalPadding: 11
              onClicked: {
                if (spokenField.text.trim() === "" || writtenField.text.trim() === "") return
                root.runAction(["dictionary-set", spokenField.text.trim(), writtenField.text.trim()], "dictionary")
                spokenField.text = ""
                writtenField.text = ""
              }
            }
          }
        }

        TextField { width: parent.width; placeholderText: root.l("Search entries…", "搜索词条…"); foreground: root.foreground; accent: root.accent }

        Surface {
          width: parent.width
          height: parent.height - 184
          Column {
            anchors.fill: parent
            anchors.margins: 18
            spacing: 0
            Row {
              width: parent.width
              height: 44
              SectionLabel { width: parent.width * 0.34; text: root.l("HEARD AS", "听到的词") }
              SectionLabel { width: parent.width * 0.46; text: root.l("REPLACE WITH", "应输出的词") }
              SectionLabel { width: parent.width * 0.20; text: root.l("ACTION", "操作") }
            }
            Rectangle { width: parent.width; height: 1; color: root.alpha(root.foreground, 0.14) }
            ScrollView {
              width: parent.width
              height: parent.height - 62
              clip: true
              ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
              Column {
                width: parent.width
                Repeater {
                  model: root.dictionaryEntries
                  delegate: Item {
                    required property var modelData
                    width: parent.width
                    height: 58
                    Row {
                      anchors.fill: parent
                      anchors.leftMargin: 10
                      BodyText { width: parent.width * 0.34; anchors.verticalCenter: parent.verticalCenter; text: String(parent.parent.modelData.spoken || "") }
                      BodyText { width: parent.width * 0.46; anchors.verticalCenter: parent.verticalCenter; text: String(parent.parent.modelData.written || ""); color: root.accent }
                      Button {
                        width: 88; anchors.verticalCenter: parent.verticalCenter; text: root.l("Delete", "删除"); iconText: "󰩺"; bordered: true; foreground: root.muted
                        onClicked: root.runAction(["dictionary-delete", String(parent.parent.parent.modelData.spoken)], "dictionary")
                      }
                    }
                    Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: root.alpha(root.foreground, 0.10) }
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
    id: scenesPage
    Item {
      PageHeader { id: scenesHeader; width: parent.width; actionText: root.l("Refresh", "刷新"); actionIcon: "󰑐"; onActionClicked: root.loadDataset("scenes", ["scenes-list"]) }

      Row {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: scenesHeader.bottom
        anchors.bottom: parent.bottom
        spacing: 20

        Column {
          width: (parent.width - parent.spacing) * 0.45
          height: parent.height
          spacing: 10
          Text { text: root.l("Scene rules", "场景规则"); color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.heading; font.bold: true }
          Repeater {
            model: root.scenes
            delegate: Surface {
              required property var modelData
              required property int index
              width: parent.width
              height: 92
              borderSpec: Border.flat(index === root.selectedSceneIndex ? root.accent : root.alpha(root.foreground, 0.18), 1)

              MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.selectedSceneIndex = index }
              Row {
                anchors.fill: parent
                anchors.margins: 14
                spacing: 14
                Text { width: 34; text: modelData.icon === "code" ? "󰆍" : (modelData.icon === "browser" ? "󰖟" : (modelData.icon === "chat" ? "󰭻" : "󰈙")); color: index === root.selectedSceneIndex ? Color.accent : Color.foreground; font.family: root.fontFamily; font.pixelSize: 26; anchors.verticalCenter: parent.verticalCenter }
                Column { width: parent.width - 130; anchors.verticalCenter: parent.verticalCenter; spacing: 6; BodyText { text: String(modelData.name || ""); font.pixelSize: Style.font.subtitle; font.bold: true } MutedText { width: parent.width; text: root.sceneDescription(modelData); elide: Text.ElideRight } }
                ToggleSwitch {
                  anchors.verticalCenter: parent.verticalCenter
                  checked: modelData.enabled === true
                  foreground: modelData.enabled === true ? root.accent : root.foreground
                  accent: root.accent
                  onToggled: root.runAction(["scene-toggle", String(modelData.id), String(!modelData.enabled)], "scenes")
                }
              }
            }
          }
        }

        Column {
          width: parent.width - parent.spacing - ((parent.width - parent.spacing) * 0.45)
          height: parent.height
          spacing: 10
          Text { text: String(root.selectedScene().name || root.l("Scene", "场景")) + root.l(" scene", " 场景"); color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.heading; font.bold: true }
          Surface {
            width: parent.width
            height: parent.height - 38
            Column {
              anchors.fill: parent
              anchors.margins: 18
              spacing: 13
              SectionLabel { text: root.l("OUTPUT STYLE", "输出风格") }
              Dropdown {
                id: sceneStyle
                width: parent.width
                showLabel: false
                value: root.sceneStyleValue(root.selectedScene().style)
                options: root.language === "zh" ? ["技术", "通用", "聊天", "笔记", "正式"] : ["Technical", "General", "Chat", "Notes", "Formal"]
                foreground: root.foreground
                accent: root.accent
              }
              LabeledToggle { label: root.l("Preserve code and commands", "保留代码与命令"); checked: root.selectedScene().preserve_code === true; onToggled: root.runAction(["scene-set", String(root.selectedScene().id), "preserve_code", String(checked)], "scenes") }
              LabeledToggle { label: root.l("Use Markdown automatically", "自动使用 Markdown"); checked: root.selectedScene().markdown === true; onToggled: root.runAction(["scene-set", String(root.selectedScene().id), "markdown", String(checked)], "scenes") }
              LabeledToggle { label: root.l("Remove filler words", "移除语气词"); checked: root.selectedScene().remove_fillers === true; onToggled: root.runAction(["scene-set", String(root.selectedScene().id), "remove_fillers", String(checked)], "scenes") }
              LabeledToggle { label: root.l("Submit automatically", "自动提交"); detail: root.l("Off by default. LocalType types text but never executes it.", "默认关闭，LocalType 只输入、不执行"); checked: root.selectedScene().auto_submit === true; onToggled: root.runAction(["scene-set", String(root.selectedScene().id), "auto_submit", String(checked)], "scenes") }
              SectionLabel { text: root.l("POLISHING INSTRUCTIONS", "润色指令") }
              TextArea {
                id: scenePrompt
                width: parent.width
                height: 96
                text: String(root.selectedScene().prompt || "")
                color: root.foreground
                placeholderTextColor: root.muted
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                wrapMode: TextEdit.Wrap
                background: Surface {}
                padding: 12
              }
              SectionLabel { text: root.l("MATCH WINDOW CLASSES", "匹配窗口类名") }
              TextField { id: sceneClasses; width: parent.width; text: String(root.selectedScene().classes || ""); foreground: root.foreground; accent: root.accent }
              Button {
                width: parent.width
                text: root.l("Save scene", "保存场景")
                iconText: "󰆓"
                bordered: true
                foreground: root.accent
                accent: root.accent
                verticalPadding: 10
                onClicked: {
                  var sceneId = String(root.selectedScene().id || "")
                  if (sceneId === "") return
                  root.runAction(["scene-save", sceneId, root.sceneStyleStorage(sceneStyle.value), scenePrompt.text, sceneClasses.text], "scenes")
                }
              }
              MutedText { text: root.l("Every scene is processed locally by Qwen3-0.6B.", "所有场景处理均由本地 Qwen3-0.6B 完成。") }
            }
          }
        }
      }
    }
  }

  Component {
    id: modelsPage
    Item {
      PageHeader { id: modelsHeader; width: parent.width; actionText: root.l("Refresh status", "刷新状态"); actionIcon: "󰑐"; onActionClicked: runtimeState.refresh() }
      Column {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: modelsHeader.bottom
        anchors.bottom: parent.bottom
        spacing: 16

        Repeater {
          model: [
            { label: root.l("SPEECH", "语音识别"), name: String(runtimeState.record.asr_model || "Qwen3-ASR-1.7B"), detail: root.l("Chinese · CUDA · BF16", "中文 · CUDA · BF16"), description: root.l("Accuracy-first Mandarin and Chinese dialect recognition", "准确率优先，支持普通话与多种中文方言"), memory: Math.max(0, Number(runtimeState.gpu.memory_used_mib || 0) - 700), latency: Number(runtimeState.record.processing_ms || 860) / 1000 },
            { label: root.l("POLISH", "智能润色"), name: String(runtimeState.record.polisher_model || "Qwen3-0.6B").replace("Qwen/", ""), detail: root.l("Local · CUDA · BF16", "本地 · CUDA · BF16"), description: root.l("Corrects wording and punctuation while preserving names", "修正错字、标点与语气，保留专有名词"), memory: 700, latency: 0.21 }
          ]
          delegate: Surface {
            required property var modelData
            width: parent.width
            height: 128
            Row {
              anchors.fill: parent
              anchors.margins: 18
              spacing: 20
              SectionLabel { width: 108; text: modelData.label; color: root.accent; anchors.verticalCenter: parent.verticalCenter }
              Column { width: parent.width - 430; anchors.verticalCenter: parent.verticalCenter; spacing: 8; BodyText { text: modelData.name; font.pixelSize: Style.font.heading; font.bold: true } MutedText { text: modelData.detail } MutedText { text: modelData.description } }
              Column { width: 170; anchors.verticalCenter: parent.verticalCenter; spacing: 9; MutedText { text: root.l("VRAM ", "显存 ") + root.formatMemory(modelData.memory) } StatusMeter { width: parent.width; value: Number(modelData.memory || 0) / Math.max(1, Number(runtimeState.gpu.memory_total_mib || 8192)); meterColor: root.accent } MutedText { text: root.l("Latest ", "最近 ") + Number(modelData.latency || 0).toFixed(2) + " s" } }
              Button { width: 96; text: root.l("Reload", "重载"); bordered: true; foreground: root.foreground; anchors.verticalCenter: parent.verticalCenter; onClicked: runtimeState.runAction(["restart"]) }
            }
          }
        }

        Row {
          width: parent.width
          height: parent.height - 288
          spacing: 20
          Column {
            width: (parent.width - parent.spacing) / 2
            height: parent.height
            spacing: 10
            Text { text: root.l("Inference device", "推理设备"); color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.heading; font.bold: true }
            Surface {
              width: parent.width
              height: parent.height - 36
              Column {
                anchors.fill: parent
                anchors.margins: 20
                spacing: 17
                BodyText { text: String(runtimeState.gpu.name || "GPU"); font.pixelSize: Style.font.subtitle; font.bold: true }
                Rectangle { width: parent.width; height: 1; color: root.alpha(root.foreground, 0.13) }
                Row { width: parent.width; BodyText { text: root.l("CUDA available", "CUDA 可用") } Item { width: parent.width - 160; height: 1 } Rectangle { width: 10; height: 10; radius: 5; color: runtimeState.gpu.available ? "#adda78" : root.urgent; anchors.verticalCenter: parent.verticalCenter } }
                Row { width: parent.width; MutedText { text: root.l("Total VRAM", "总显存") } Item { width: parent.width - 180; height: 1 } BodyText { text: root.formatMemory(runtimeState.gpu.memory_total_mib) } }
                Row { width: parent.width; MutedText { text: root.l("Used VRAM", "已用显存") } Item { width: parent.width - 190; height: 1 } BodyText { text: root.formatMemory(runtimeState.gpu.memory_used_mib) } }
                StatusMeter { width: parent.width; value: root.gpuRatio(); meterColor: root.accent }
                Row { width: parent.width; MutedText { text: root.l("Temperature", "温度") } Item { width: parent.width - 150; height: 1 } BodyText { text: Number(runtimeState.gpu.temperature_c || 0) + "°C" } }
                Row { width: parent.width; MutedText { text: root.l("Utilization", "利用率") } Item { width: parent.width - 160; height: 1 } BodyText { text: Number(runtimeState.gpu.utilization || 0) + "%" } }
                StatusMeter { width: parent.width; value: Number(runtimeState.gpu.utilization || 0) / 100; meterColor: "#adda78" }
              }
            }
          }
          Column {
            width: (parent.width - parent.spacing) / 2
            height: parent.height
            spacing: 10
            Text { text: root.l("Service control", "服务控制"); color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.heading; font.bold: true }
            Surface {
              width: parent.width
              height: parent.height - 36
              Column {
                anchors.fill: parent
                anchors.margins: 20
                spacing: 16
                LabeledToggle { label: root.l("Preload at desktop startup", "桌面启动时预热"); detail: root.l("Load both local models immediately after login", "登录后立即加载两个本地模型"); checked: root.settings.prewarm_models !== false; onToggled: root.settingSet("prewarm_models", checked) }
                LabeledToggle { label: root.l("Unload polisher when idle", "空闲时卸载润色模型"); detail: root.l("Saves VRAM, but the next dictation will be slower", "节省显存，但下一次听写会更慢"); checked: false }
                Rectangle { width: parent.width; height: 1; color: root.alpha(root.foreground, 0.13) }
                Row { width: parent.width; MutedText { text: root.l("Service", "服务") } Item { width: parent.width - 180; height: 1 } BodyText { text: runtimeState.serviceActive ? root.l("Running", "运行中") : root.l("Stopped", "已停止"); color: runtimeState.serviceActive ? "#adda78" : root.urgent } }
                Row { width: parent.width; MutedText { text: root.l("Endpoint", "接口") } Item { width: parent.width - 220; height: 1 } BodyText { text: "127.0.0.1:8765" } }
                Button { width: parent.width; text: root.l("Apply and restart service", "应用并重启服务"); iconText: "󰑐"; bordered: true; foreground: root.accent; accent: root.accent; verticalPadding: 11; onClicked: runtimeState.runAction(["restart"]) }
                MutedText { text: root.l("Audio never leaves this device", "音频不会离开本机"); anchors.horizontalCenter: parent.horizontalCenter }
              }
            }
          }
        }
      }
    }
  }

  Component {
    id: settingsPage
    Item {
      PageHeader { id: settingsHeader; width: parent.width; actionText: root.l("Run diagnostics", "运行自检"); actionIcon: "󰓙"; onActionClicked: root.runAction(["doctor"], "") }
      ScrollView {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: settingsHeader.bottom
        anchors.bottom: parent.bottom
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        Column {
          width: parent.width
          spacing: 18
          Surface {
            width: parent.width
            height: 222
            Column {
              anchors.fill: parent
              anchors.margins: 18
              spacing: 12
              SectionLabel { text: root.l("SHORTCUTS", "快捷键") }
              Row {
                width: parent.width
                spacing: 16
                BodyText { width: 180; text: root.l("Smart dictation", "智能听写"); anchors.verticalCenter: parent.verticalCenter }
                TextField { id: smartShortcutField; width: parent.width - 196; text: String(root.settings.smart_shortcut || "F9"); placeholderText: "F9"; foreground: root.foreground; accent: root.accent }
              }
              Row {
                width: parent.width
                spacing: 16
                BodyText { width: 180; text: root.l("Verbatim dictation", "原文听写"); anchors.verticalCenter: parent.verticalCenter }
                TextField { id: rawShortcutField; width: parent.width - 196; text: String(root.settings.raw_shortcut || "SHIFT + F9"); placeholderText: "SHIFT + F9"; foreground: root.foreground; accent: root.accent }
              }
              Button {
                width: parent.width
                text: root.l("Apply shortcuts", "应用快捷键")
                iconText: "󰌌"
                bordered: true
                foreground: root.accent
                accent: root.accent
                onClicked: root.saveShortcuts(smartShortcutField.text, rawShortcutField.text)
              }
            }
          }
          Surface {
            width: parent.width
            height: 338
            Column {
              anchors.fill: parent
              anchors.margins: 18
              spacing: 10
              SectionLabel { text: root.l("LANGUAGE, DICTATION & PRIVACY", "语言、听写与隐私") }
              Dropdown { width: parent.width; label: root.l("App language", "应用语言"); value: String(root.settings.language || "en"); options: [{ value: "en", label: "English" }, { value: "zh", label: "简体中文" }]; foreground: root.foreground; accent: root.accent; onChanged: function(value) { root.settingSet("language", value) } }
              Dropdown { width: parent.width; label: root.l("Default dictation mode", "默认听写模式"); value: String(root.settings.default_mode || "smart"); options: [{ value: "smart", label: root.l("Smart dictation", "智能听写") }, { value: "raw", label: root.l("Verbatim dictation", "原文听写") }]; foreground: root.foreground; accent: root.accent; onChanged: function(value) { root.settingSet("default_mode", value) } }
              LabeledToggle { label: root.l("Save text history", "保存文字历史"); detail: root.l("Stores text and metadata only, never WAV audio", "只保存文字和元数据，不保存 WAV 音频"); checked: root.settings.keep_history !== false; onToggled: root.settingSet("keep_history", checked) }
              LabeledToggle { label: root.l("Paste terminal input as one block", "终端使用整段粘贴"); detail: root.l("Prevents Codex and other TUIs from splitting one sentence", "避免 Codex 等 TUI 把一句话拆成多次提交"); checked: root.settings.terminal_paste !== false; onToggled: root.settingSet("terminal_paste", checked) }
            }
          }
          Surface {
            width: parent.width
            height: 196
            Column {
              anchors.fill: parent
              anchors.margins: 18
              spacing: 13
              SectionLabel { text: root.l("LOCAL DATA", "本地数据") }
              Row { width: parent.width; MutedText { width: 220; text: root.l("Personal dictionary", "个人词典") } BodyText { width: parent.width - 220; text: "~/.config/localtype/dictionary.json"; horizontalAlignment: Text.AlignRight; elide: Text.ElideLeft } }
              Row { width: parent.width; MutedText { width: 220; text: root.l("Dictation history", "听写历史") } BodyText { width: parent.width - 220; text: "~/.local/state/localtype/history.json"; horizontalAlignment: Text.AlignRight; elide: Text.ElideLeft } }
              Row { width: parent.width; MutedText { width: 220; text: root.l("Models and runtime", "模型与环境") } BodyText { width: parent.width - 220; text: "~/.local/share/localtype/"; horizontalAlignment: Text.AlignRight; elide: Text.ElideLeft } }
              Row { width: parent.width; MutedText { width: 220; text: root.l("Version", "版本") } BodyText { width: parent.width - 220; text: "LocalType 0.3.0"; horizontalAlignment: Text.AlignRight } }
            }
          }
        }
      }
    }
  }
}
