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
  property var corrections: []
  property var scenes: []
  property var settings: ({})
  property int selectedSceneIndex: 0
  property string queuedDataset: ""
  property var queuedArgs: []
  property string refreshAfterAction: ""
  property bool confirmClearHistory: false
  property string correctionHistoryId: ""
  property string correctionOriginalText: ""
  property bool showAdvanced: false
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
    var value = String(mode === "smart"
      ? (settings.smart_shortcut || "F9")
      : (mode === "learn" ? (settings.learn_shortcut || "CTRL + SHIFT + F9") : (settings.raw_shortcut || "SHIFT + F9")))
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
    if (currentPage === "workspace") return l("Dictate", "听写")
    if (currentPage === "history") return l("Dictation History", "听写历史")
    if (currentPage === "dictionary") return l("Personal Dictionary", "个人词典")
    return l("Settings", "设置")
  }
  function pageSubtitle() {
    if (currentPage === "workspace") return l("Speak naturally and keep moving", "自然说话，保持专注")
    if (currentPage === "history") return l("Find, reuse, and compare original and polished transcripts", "查找、复用和对比原始语音与润色结果")
    if (currentPage === "dictionary") return l("Names, terms, and corrections LocalType should remember", "让 LocalType 记住名字、术语和纠错")
    return l("Manage language, shortcuts, privacy, and local data", "管理语言、快捷键、隐私与本地数据")
  }
  function pageComponent() {
    if (currentPage === "workspace") return workspacePage
    if (currentPage === "history") return historyPage
    if (currentPage === "dictionary") return dictionaryPage
    return settingsPage
  }
  function open(payloadJson) {
    closingFromHost = false
    appWindow.visible = true
    if (payloadJson) {
      try {
        var payload = JSON.parse(String(payloadJson))
        var requestedPage = String(payload.page || "")
        if (["workspace", "history", "dictionary", "settings"].indexOf(requestedPage) !== -1)
          currentPage = requestedPage
        else if (requestedPage === "learning") currentPage = "dictionary"
        else if (requestedPage === "scenes" || requestedPage === "models") currentPage = "settings"
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
    else if (currentPage === "dictionary") {
      loadDataset("dictionary", ["dictionary-list"])
    }
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
      } else if (dataset === "dictionary") {
        dictionaryEntries = Array.isArray(value) ? value : []
        if (currentPage === "dictionary") Qt.callLater(function() { loadDataset("corrections", ["corrections-list"]) })
      }
      else if (dataset === "corrections") corrections = Array.isArray(value) ? value : []
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
  function pendingCorrections() {
    return corrections.filter(function(entry) { return String(entry.status || "pending") === "pending" })
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
  function saveShortcuts(smart, raw, learn) {
    if (String(smart).trim() === "" || String(raw).trim() === "" || String(learn).trim() === "") return
    runAction(["shortcuts-set", String(smart).trim(), String(raw).trim(), String(learn).trim()], "settings")
  }
  function editAndLearn(entry) {
    correctionHistoryId = String(entry.id || "")
    correctionOriginalText = String(entry.final_text || "")
    correctionText.text = correctionOriginalText
    correctionEditor.open()
  }
  function proposeHistoryCorrection() {
    var corrected = correctionText.text.trim()
    if (corrected === "" || corrected === correctionOriginalText.trim()) return
    correctionEditor.close()
    currentPage = "dictionary"
    runAction(["correction-propose", "--history-id", correctionHistoryId, "--corrected", corrected, "--source", "history"], "corrections")
  }
  function savePolishPrompt(prompt) {
    if (String(prompt).trim() === "") return
    runAction(["setting-set", "polish_prompt", String(prompt)], "settings")
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
      else if (root.refreshAfterAction === "corrections") {
        root.loadDataset("corrections", ["corrections-list"])
        root.loadDataset("dictionary", ["dictionary-list"])
      }
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
            visible: false
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
                      { id: "learning", label: root.l("Learning", "学习"), icon: "󰛨" },
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

                Item { width: 1; height: Math.max(0, parent.height - 76 - 7 * 64 - 18 * 3 - 232) }

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

          Item {
            width: parent.width
            height: parent.height - 40

            Column {
              anchors.fill: parent
              spacing: 0

              Item {
                width: parent.width
                height: 104
                Row {
                  anchors.fill: parent
                  anchors.leftMargin: 44
                  anchors.rightMargin: 44
                  spacing: 16
                  Row {
                    width: 310
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 14
                    Text { text: "󰍬"; color: root.accent; font.family: root.fontFamily; font.pixelSize: 36; anchors.verticalCenter: parent.verticalCenter }
                    Text { text: "LOCALTYPE"; color: root.accent; font.family: root.fontFamily; font.pixelSize: Math.max(19, Style.font.heading); font.bold: true; font.letterSpacing: 1.5; anchors.verticalCenter: parent.verticalCenter }
                  }
                  Item { width: Math.max(1, parent.width - 310 - 212 - 60 - 48); height: 1 }
                  Surface {
                    width: 212
                    height: 48
                    anchors.verticalCenter: parent.verticalCenter
                    Row {
                      anchors.centerIn: parent
                      spacing: 10
                      Rectangle { width: 9; height: 9; radius: 5; color: runtimeState.backendReady ? "#adda78" : root.urgent; anchors.verticalCenter: parent.verticalCenter }
                      BodyText { text: root.l("Local · Private", "本地 · 私密"); anchors.verticalCenter: parent.verticalCenter }
                    }
                  }
                  Button {
                    width: 60
                    height: 48
                    iconText: "󰒓"
                    bordered: true
                    selected: root.currentPage === "settings"
                    foreground: root.currentPage === "settings" ? root.accent : root.foreground
                    accent: root.accent
                    onClicked: root.navigate(root.currentPage === "settings" ? "workspace" : "settings")
                  }
                }
              }

              Row {
                width: parent.width - 88
                height: 56
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: 4
                Repeater {
                  model: [
                    { id: "workspace", label: root.l("Dictate", "听写"), icon: "󰍬" },
                    { id: "history", label: root.l("History", "历史"), icon: "󰋚" },
                    { id: "dictionary", label: root.l("Dictionary", "词典"), icon: "󰓹" }
                  ]
                  delegate: Button {
                    required property var modelData
                    width: (parent.width - 8) / 3
                    height: parent.height
                    text: modelData.label
                    iconText: modelData.icon
                    bordered: true
                    selected: root.currentPage === modelData.id
                    foreground: root.currentPage === modelData.id ? root.accent : root.foreground
                    accent: root.accent
                    fontFamily: root.fontFamily
                    fontSize: Style.font.subtitle
                    onClicked: root.navigate(modelData.id)
                    Rectangle {
                      visible: root.currentPage === parent.modelData.id
                      height: 2
                      anchors.left: parent.left
                      anchors.right: parent.right
                      anchors.bottom: parent.bottom
                      color: root.accent
                    }
                  }
                }
              }

              Item {
                width: parent.width
                height: parent.height - 160
                Loader {
                  id: simplePageLoader
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.top: parent.top
                  anchors.bottom: simpleFooter.top
                  anchors.leftMargin: 48
                  anchors.rightMargin: 48
                  anchors.topMargin: 28
                  anchors.bottomMargin: 12
                  sourceComponent: root.pageComponent()
                }
                Item {
                  id: simpleFooter
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.bottom: parent.bottom
                  anchors.leftMargin: 48
                  anchors.rightMargin: 48
                  height: 42
                  Rectangle { width: parent.width; height: 1; color: root.alpha(root.foreground, 0.12) }
                  MutedText {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.verticalCenterOffset: 4
                    text: (runtimeState.backendReady ? root.l("READY", "就绪") : (runtimeState.serviceActive ? root.l("LOADING", "加载中") : root.l("OFFLINE", "离线")))
                      + root.l(" · Chinese · Local inference", " · 中文 · 本地推理")
                  }
                  MutedText {
                    visible: root.dataError !== ""
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.verticalCenterOffset: 4
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
        visible: false
        width: parent.width
        actionText: root.shortcut(root.selectedMode) + (runtimeState.recording ? root.l(" Stop", " 停止") : root.l(" Start", " 开始"))
        actionIcon: runtimeState.recording ? "󰓛" : "󰍬"
        onActionClicked: root.primaryAction()
      }

      Column {
        visible: false
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
            text: root.l("Smart  ·  Clean wording", "智能听写  ·  自动优化文本、修正语法与标点")
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
            text: root.l("Verbatim  ·  Keep original wording", "原文听写  ·  忠实记录原话")
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

      Column {
        anchors.fill: parent
        spacing: 22

        Row {
          width: parent.width
          height: 48
          Item { width: parent.width - 320; height: 1 }
          Row {
            width: 320
            height: 44
            Button { width: 160; height: parent.height; text: root.l("Polished", "智能润色"); selected: root.selectedMode === "smart"; bordered: true; foreground: root.selectedMode === "smart" ? root.accent : root.foreground; accent: root.accent; onClicked: root.selectedMode = "smart" }
            Button { width: 160; height: parent.height; text: root.l("Verbatim", "原文听写"); selected: root.selectedMode === "raw"; bordered: true; foreground: root.selectedMode === "raw" ? root.accent : root.foreground; accent: root.accent; onClicked: root.selectedMode = "raw" }
          }
        }

        Surface {
          width: parent.width
          height: 176
          Row {
            anchors.fill: parent
            anchors.margins: 28
            spacing: 28
            Text {
              width: 150
              text: runtimeState.processing ? "󰔟" : (runtimeState.recording ? "󰑊" : "󰍬")
              color: runtimeState.recording ? root.urgent : root.accent
              font.family: root.fontFamily
              font.pixelSize: 62
              anchors.verticalCenter: parent.verticalCenter
              horizontalAlignment: Text.AlignHCenter
            }
            Column {
              width: parent.width - 150 - 246 - 56
              anchors.verticalCenter: parent.verticalCenter
              spacing: 12
              TitleText { width: parent.width; text: root.phaseTitle(); font.pixelSize: Style.font.display; wrapMode: Text.Wrap }
              MutedText {
                width: parent.width
                text: runtimeState.recording
                  ? root.l("Press the shortcut again when you finish.", "说完后再次按快捷键即可停止。")
                  : root.l("LocalType will transcribe and polish before inserting.", "LocalType 会先识别并润色，再输入文字。")
                font.pixelSize: Style.font.subtitle
                wrapMode: Text.Wrap
              }
            }
            Button {
              width: 246
              height: 62
              anchors.verticalCenter: parent.verticalCenter
              text: runtimeState.recording ? root.l("Stop recording", "停止录音") : root.l("Start recording", "开始录音")
              iconText: runtimeState.recording ? "󰓛" : "󰑊"
              bordered: true
              borderSpec: Border.flat(root.accent, 1)
              foreground: runtimeState.recording ? root.urgent : root.accent
              accent: root.accent
              fontSize: Style.font.subtitle
              onClicked: root.primaryAction()
            }
          }
        }

        Text { text: root.l("Today", "今天"); color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.heading; font.bold: true }

        Surface {
          width: parent.width
          height: parent.height - 290
          Item {
            width: parent.width
            height: parent.height
            Column {
              width: parent.width
              Repeater {
                model: root.allHistory.slice(0, 4)
                delegate: Item {
                id: recentRow
                required property var modelData
                required property int index
                width: parent.width
                height: parent.parent.height / Math.max(1, Math.min(4, root.allHistory.length))
                Row {
                  anchors.fill: parent
                  anchors.leftMargin: 28
                  anchors.rightMargin: 24
                  spacing: 20
                  MutedText { width: 120; text: root.formatTime(recentRow.modelData.created_at); anchors.verticalCenter: parent.verticalCenter }
                  BodyText { width: parent.width - 120 - 110 - 66 - 60; text: String(recentRow.modelData.final_text || ""); font.pixelSize: Style.font.subtitle; wrapMode: Text.Wrap; maximumLineCount: 2; elide: Text.ElideRight; anchors.verticalCenter: parent.verticalCenter }
                  Button { width: 110; text: root.l("Correct", "纠正"); iconText: "󰏫"; foreground: root.accent; visible: recentRow.index === 0; anchors.verticalCenter: parent.verticalCenter; onClicked: root.editAndLearn(recentRow.modelData) }
                  Button { width: 66; iconText: "󰆏"; foreground: root.foreground; anchors.verticalCenter: parent.verticalCenter; onClicked: root.runAction(["copy-text", String(recentRow.modelData.final_text || "")], "") }
                }
                Rectangle { visible: recentRow.index < Math.min(4, root.allHistory.length) - 1; anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom; height: 1; color: root.alpha(root.foreground, 0.10) }
                }
              }
            }
            Column {
              visible: root.allHistory.length === 0
              anchors.centerIn: parent
              spacing: 12
              Text { anchors.horizontalCenter: parent.horizontalCenter; text: "󰋚"; color: root.muted; font.family: root.fontFamily; font.pixelSize: 34 }
              MutedText { text: root.l("Your recent dictations will appear here.", "最近的听写会显示在这里。"); font.pixelSize: Style.font.subtitle }
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
        visible: false
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
        visible: false
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
                    Item { width: Math.max(1, parent.width - 690); height: 1 }
                    Button {
                      width: 42; iconText: "󰆏"; foreground: root.foreground
                      onClicked: root.runAction(["copy-text", String(parent.parent.parent.parent.modelData.final_text || "")], "")
                    }
                    Button {
                      width: 138; text: root.l("Correct & learn", "纠正并学习"); iconText: "󰛨"; bordered: true; foreground: root.accent; accent: root.accent
                      onClicked: root.editAndLearn(parent.parent.parent.parent.modelData)
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

      Column {
        anchors.fill: parent
        spacing: 16
        Row {
          width: parent.width
          height: 66
          Column {
            width: 310
            anchors.verticalCenter: parent.verticalCenter
            spacing: 4
            TitleText { text: root.l("History", "历史") }
            MutedText { text: root.l("Stored only on this device", "仅保存在本机") }
          }
          TextField {
            width: parent.width - 310 - 190
            anchors.verticalCenter: parent.verticalCenter
            placeholderText: root.l("Search dictations…", "搜索听写内容…")
            foreground: root.foreground
            accent: root.accent
            onTextChanged: { root.historyQuery = text; root.filterHistory(text) }
          }
          Item { width: 16; height: 1 }
          Button {
            width: 174
            anchors.verticalCenter: parent.verticalCenter
            text: root.confirmClearHistory ? root.l("Confirm clear", "确认清空") : root.l("Clear history", "清空历史")
            bordered: true
            foreground: root.confirmClearHistory ? root.urgent : root.muted
            onClicked: {
              if (!root.confirmClearHistory) { root.confirmClearHistory = true; clearConfirmTimer.restart() }
              else { root.confirmClearHistory = false; root.runAction(["history-clear"], "history") }
            }
          }
        }

        Surface {
          width: parent.width
          height: parent.height - 82
          ScrollView {
            id: simpleHistoryView
            width: parent.width
            height: parent.height
            clip: true
            ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
            Column {
              width: simpleHistoryView.availableWidth
              Repeater {
                model: root.historyEntries
                delegate: Item {
                  id: simpleHistoryRow
                  required property var modelData
                  width: parent.width
                  height: 116
                  Row {
                    anchors.fill: parent
                    anchors.leftMargin: 26
                    anchors.rightMargin: 22
                    spacing: 18
                    Column {
                      width: 108
                      anchors.verticalCenter: parent.verticalCenter
                      spacing: 8
                      BodyText { text: root.formatTime(simpleHistoryRow.modelData.created_at); font.pixelSize: Style.font.subtitle }
                      SectionLabel { text: simpleHistoryRow.modelData.mode === "smart" ? root.l("POLISHED", "智能润色") : root.l("VERBATIM", "原文听写"); color: simpleHistoryRow.modelData.mode === "smart" ? root.accent : root.muted }
                    }
                    BodyText { width: parent.width - 108 - 18 - 288; text: String(simpleHistoryRow.modelData.final_text || ""); font.pixelSize: Style.font.subtitle; wrapMode: Text.Wrap; maximumLineCount: 3; elide: Text.ElideRight; anchors.verticalCenter: parent.verticalCenter }
                    Button { width: 116; text: root.l("Correct", "纠正"); iconText: "󰏫"; foreground: root.accent; anchors.verticalCenter: parent.verticalCenter; onClicked: root.editAndLearn(simpleHistoryRow.modelData) }
                    Button { width: 58; iconText: "󰆏"; foreground: root.foreground; anchors.verticalCenter: parent.verticalCenter; onClicked: root.runAction(["copy-text", String(simpleHistoryRow.modelData.final_text || "")], "") }
                    Button { width: 58; iconText: "󰩺"; foreground: root.muted; anchors.verticalCenter: parent.verticalCenter; onClicked: root.runAction(["history-delete", String(simpleHistoryRow.modelData.id)], "history") }
                  }
                  Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom; height: 1; color: root.alpha(root.foreground, 0.10) }
                }
              }
              Item {
                visible: root.historyEntries.length === 0
                width: parent.width
                height: 220
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
  }

  Component {
    id: dictionaryPage
    Item {
      PageHeader { id: dictionaryHeader; width: parent.width; actionText: "" }

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
            Column { width: (parent.width - 160) * 0.54; spacing: 6; SectionLabel { text: root.l("WORD OR PHRASE", "词语或短语") } TextField { id: writtenField; width: parent.width; placeholderText: root.l("Example: Omarchy", "例如：Omarchy"); foreground: root.foreground; accent: root.accent } }
            Column { width: (parent.width - 160) * 0.46; spacing: 6; SectionLabel { text: root.l("SOUNDS LIKE · OPTIONAL", "近似读音 · 可选") } TextField { id: spokenField; width: parent.width; placeholderText: root.l("Example: oh-marky", "例如：欧马奇"); foreground: root.foreground; accent: root.accent } }
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
                if (writtenField.text.trim() === "") return
                var alias = spokenField.text.trim() === "" ? writtenField.text.trim() : spokenField.text.trim()
                root.runAction(["dictionary-set", alias, writtenField.text.trim()], "dictionary")
                spokenField.text = ""
                writtenField.text = ""
              }
            }
          }
        }

        Column {
          id: reviewSection
          visible: root.pendingCorrections().length > 0
          width: parent.width
          height: visible ? 42 + Math.min(2, root.pendingCorrections().length) * 76 : 0
          spacing: 8
          Text {
            text: root.l("Review corrections · " + root.pendingCorrections().length, "确认纠错 · " + root.pendingCorrections().length)
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            font.bold: true
          }
          Repeater {
            model: root.pendingCorrections().slice(0, 2)
            delegate: Surface {
              id: pendingCard
              required property var modelData
              width: reviewSection.width
              height: 68
              borderSpec: Border.flat(root.accent, 1)
              Row {
                anchors.fill: parent
                anchors.margins: 12
                spacing: 12
                BodyText { width: (parent.width - 250) * 0.44; text: String(pendingCard.modelData.spoken || ""); elide: Text.ElideRight; anchors.verticalCenter: parent.verticalCenter }
                Text { width: 28; text: "→"; color: root.muted; font.family: root.fontFamily; font.pixelSize: Style.font.subtitle; anchors.verticalCenter: parent.verticalCenter }
                BodyText { width: (parent.width - 250) * 0.56; text: String(pendingCard.modelData.written || ""); color: root.accent; elide: Text.ElideRight; anchors.verticalCenter: parent.verticalCenter }
                Button { width: 84; text: root.l("Ignore", "忽略"); foreground: root.muted; bordered: true; anchors.verticalCenter: parent.verticalCenter; onClicked: root.runAction(["correction-ignore", String(pendingCard.modelData.id)], "corrections") }
                Button { width: 104; text: root.l("Learn", "学习"); foreground: root.accent; accent: root.accent; bordered: true; anchors.verticalCenter: parent.verticalCenter; onClicked: root.runAction(["correction-accept", String(pendingCard.modelData.id)], "corrections") }
              }
            }
          }
        }

        TextField { visible: false; width: parent.width; placeholderText: root.l("Search entries…", "搜索词条…"); foreground: root.foreground; accent: root.accent }

        Surface {
          width: parent.width
          height: Math.max(220, parent.height - 130 - reviewSection.height - (reviewSection.visible ? 18 : 0))
          Column {
            anchors.fill: parent
            anchors.margins: 18
            spacing: 0
            Row {
              width: parent.width
              height: 44
              SectionLabel { width: parent.width * 0.46; text: root.l("WORD OR PHRASE", "词语或短语") }
              SectionLabel { width: parent.width * 0.34; text: root.l("PRONUNCIATION / SOURCE", "读音 / 来源") }
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
                      BodyText { width: parent.width * 0.46; anchors.verticalCenter: parent.verticalCenter; text: String(parent.parent.modelData.written || ""); color: root.accent }
                      BodyText { width: parent.width * 0.34; anchors.verticalCenter: parent.verticalCenter; text: String(parent.parent.modelData.spoken || "") === String(parent.parent.modelData.written || "") ? root.l("Vocabulary", "词汇") : String(parent.parent.modelData.spoken || "") }
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
    id: learningPage
    Item {
      PageHeader { id: learningHeader; width: parent.width; actionText: root.l("Refresh", "刷新"); actionIcon: "󰑐"; onActionClicked: root.loadDataset("corrections", ["corrections-list"]) }

      Column {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: learningHeader.bottom
        anchors.bottom: parent.bottom
        spacing: 16

        Surface {
          width: parent.width
          height: 96
          borderSpec: Border.flat(root.accent, 1)
          Row {
            anchors.fill: parent
            anchors.margins: 16
            spacing: 16
            Text { text: "󰛨"; color: root.accent; font.family: root.fontFamily; font.pixelSize: 30; anchors.verticalCenter: parent.verticalCenter }
            Column {
              width: parent.width - 70
              anchors.verticalCenter: parent.verticalCenter
              spacing: 6
              BodyText { text: root.l("Select a complete corrected sentence, then press " + root.shortcut("learn") + ".", "选中修改后的完整句子，然后按 " + root.shortcut("learn") + "。"); font.pixelSize: Style.font.subtitle; font.bold: true }
              MutedText { text: root.l("Clear local edits can learn automatically; ambiguous edits stay here for review. Acoustic learning also saves the aligned phrase audio.", "明确的局部修改可自动学习；有歧义的修改会留在这里确认。开启声学学习后还会保存对齐后的词语音频。") }
            }
          }
        }

        ScrollView {
          id: correctionsView
          width: parent.width
          height: parent.height - 112
          clip: true
          ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
          Column {
            width: correctionsView.availableWidth
            spacing: 12
            SectionLabel { text: root.l("CORRECTIONS · " + root.corrections.length, "纠错记录 · " + root.corrections.length + " 条") }
            Repeater {
              model: root.corrections
              delegate: Surface {
                id: correctionCard
                required property var modelData
                width: correctionsView.availableWidth
                height: 154
                borderSpec: Border.flat(modelData.status === "pending" ? root.accent : root.alpha(root.foreground, 0.18), 1)
                Column {
                  anchors.fill: parent
                  anchors.margins: 16
                  spacing: 11
                  Row {
                    width: parent.width
                    spacing: 12
                    SectionLabel { text: correctionCard.modelData.status === "pending" ? root.l("PENDING", "待确认") : (correctionCard.modelData.status === "learned" ? root.l("LEARNED", "已学习") : root.l("IGNORED", "已忽略")); color: correctionCard.modelData.status === "pending" ? root.accent : root.muted }
                    MutedText { text: String(correctionCard.modelData.application_title || correctionCard.modelData.application_class || root.l("Unknown app", "未知应用")) }
                    MutedText { text: root.l("Seen ", "出现 ") + Number(correctionCard.modelData.count || 1) + root.l("×", " 次") }
                    MutedText { visible: Number(correctionCard.modelData.acoustic_samples || 0) > 0; text: "󰑋 " + Number(correctionCard.modelData.acoustic_samples || 0) + root.l(" voice sample", " 个语音样本") }
                    Item { width: Math.max(1, parent.width - (Number(correctionCard.modelData.acoustic_samples || 0) > 0 ? 710 : 570)); height: 1 }
                    Button { visible: correctionCard.modelData.status === "pending"; width: 92; text: root.l("Ignore", "忽略"); bordered: true; foreground: root.muted; onClicked: root.runAction(["correction-ignore", String(correctionCard.modelData.id)], "corrections") }
                    Button { visible: correctionCard.modelData.status === "pending"; width: 104; text: root.l("Learn", "学习"); iconText: "󰆓"; bordered: true; foreground: root.accent; accent: root.accent; onClicked: root.runAction(["correction-accept", String(correctionCard.modelData.id)], "corrections") }
                    Button { visible: correctionCard.modelData.status !== "pending"; width: 92; text: root.l("Delete", "删除"); iconText: "󰩺"; bordered: true; foreground: root.muted; onClicked: root.runAction(["correction-delete", String(correctionCard.modelData.id)], "corrections") }
                  }
                  Row {
                    width: parent.width
                    spacing: 14
                    Surface { width: (parent.width - 46) * 0.46; height: 50; Column { anchors.fill: parent; anchors.margins: 8; spacing: 3; SectionLabel { text: root.l("HEARD AS", "识别为") } BodyText { text: String(correctionCard.modelData.spoken || ""); elide: Text.ElideRight; width: parent.width } } }
                    Text { text: "→"; color: root.accent; font.pixelSize: 22; anchors.verticalCenter: parent.verticalCenter }
                    Surface { width: (parent.width - 46) * 0.54; height: 50; Column { anchors.fill: parent; anchors.margins: 8; spacing: 3; SectionLabel { text: root.l("CORRECTED TO", "修正为") } BodyText { text: String(correctionCard.modelData.written || ""); color: root.accent; elide: Text.ElideRight; width: parent.width } } }
                  }
                }
              }
            }
            Surface {
              visible: root.corrections.length === 0
              width: parent.width
              height: 180
              Column { anchors.centerIn: parent; spacing: 12; Text { anchors.horizontalCenter: parent.horizontalCenter; text: "󰛨"; color: root.muted; font.family: root.fontFamily; font.pixelSize: 34 } MutedText { anchors.horizontalCenter: parent.horizontalCenter; text: root.l("No learned corrections yet", "还没有纠错学习记录"); font.pixelSize: Style.font.subtitle } }
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
      PageHeader { id: settingsHeader; visible: false; width: parent.width; actionText: root.l("Run diagnostics", "运行自检"); actionIcon: "󰓙"; onActionClicked: root.runAction(["doctor"], "") }
      ScrollView {
        visible: false
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
            height: 280
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
              Row {
                width: parent.width
                spacing: 16
                BodyText { width: 180; text: root.l("Learn correction", "纠错学习"); anchors.verticalCenter: parent.verticalCenter }
                TextField { id: learnShortcutField; width: parent.width - 196; text: String(root.settings.learn_shortcut || "CTRL + SHIFT + F9"); placeholderText: "CTRL + SHIFT + F9"; foreground: root.foreground; accent: root.accent }
              }
              Button {
                width: parent.width
                text: root.l("Apply shortcuts", "应用快捷键")
                iconText: "󰌌"
                bordered: true
                foreground: root.accent
                accent: root.accent
                onClicked: root.saveShortcuts(smartShortcutField.text, rawShortcutField.text, learnShortcutField.text)
              }
            }
          }
          Surface {
            width: parent.width
            height: 486
            Column {
              anchors.fill: parent
              anchors.margins: 18
              spacing: 11
              SectionLabel { text: root.l("POLISH PROMPT", "润色提示词") }
              MutedText {
                width: parent.width
                text: root.l(
                  "Complete Chat Prompt JSON sent to Qwen3-0.6B: edit system and input/output examples. Use {context} for the active app class. Plain-text system prompts also work. Changes apply immediately.",
                  "这是发送给 Qwen3-0.6B 的完整 Chat Prompt JSON：可编辑 system 和输入/输出示例。可用 {context} 引用当前应用类名；也支持纯文本 system prompt，保存后立即生效。"
                )
                wrapMode: Text.Wrap
              }
              TextArea {
                id: polishPromptField
                width: parent.width
                height: 326
                text: String(root.settings.polish_prompt || "")
                color: root.foreground
                placeholderTextColor: root.muted
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                wrapMode: TextEdit.Wrap
                background: Surface {}
                padding: 12
              }
              Row {
                width: parent.width
                spacing: 12
                Button {
                  width: (parent.width - parent.spacing) / 2
                  text: root.l("Restore default", "恢复默认")
                  iconText: "󰑐"
                  bordered: true
                  foreground: root.foreground
                  onClicked: root.runAction(["setting-reset", "polish_prompt"], "settings")
                }
                Button {
                  width: (parent.width - parent.spacing) / 2
                  text: root.l("Save prompt", "保存提示词")
                  iconText: "󰆓"
                  bordered: true
                  foreground: root.accent
                  accent: root.accent
                  onClicked: root.savePolishPrompt(polishPromptField.text)
                }
              }
            }
          }
          Surface {
            width: parent.width
            height: 402
            Column {
              anchors.fill: parent
              anchors.margins: 18
              spacing: 10
              SectionLabel { text: root.l("LANGUAGE, DICTATION & PRIVACY", "语言、听写与隐私") }
              Dropdown { width: parent.width; label: root.l("App language", "应用语言"); value: String(root.settings.language || "en"); options: [{ value: "en", label: "English" }, { value: "zh", label: "简体中文" }]; foreground: root.foreground; accent: root.accent; onChanged: function(value) { root.settingSet("language", value) } }
              Dropdown { width: parent.width; label: root.l("Default dictation mode", "默认听写模式"); value: String(root.settings.default_mode || "smart"); options: [{ value: "smart", label: root.l("Smart dictation", "智能听写") }, { value: "raw", label: root.l("Verbatim dictation", "原文听写") }]; foreground: root.foreground; accent: root.accent; onChanged: function(value) { root.settingSet("default_mode", value) } }
              LabeledToggle { label: root.l("Save text history", "保存文字历史"); detail: root.l("Text and metadata stay on this device", "文字与元数据只保存在本机"); checked: root.settings.keep_history !== false; onToggled: root.settingSet("keep_history", checked) }
              LabeledToggle { label: root.l("Learn from speech segments", "从语音片段学习"); detail: root.l("Keeps a 20-item local audio buffer and saves only corrected phrase samples", "在本机暂存最近 20 条录音，并长期保留纠错词的语音片段"); checked: root.settings.acoustic_learning === true; onToggled: root.settingSet("acoustic_learning", checked) }
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
              Row { width: parent.width; MutedText { width: 220; text: root.l("Acoustic memory", "声学记忆") } BodyText { width: parent.width - 220; text: "~/.local/state/localtype/acoustic-memory/"; horizontalAlignment: Text.AlignRight; elide: Text.ElideLeft } }
              Row { width: parent.width; MutedText { width: 220; text: root.l("Models and runtime", "模型与环境") } BodyText { width: parent.width - 220; text: "~/.local/share/localtype/"; horizontalAlignment: Text.AlignRight; elide: Text.ElideLeft } }
              Row { width: parent.width; MutedText { width: 220; text: root.l("Version", "版本") } BodyText { width: parent.width - 220; text: "LocalType 0.6.0"; horizontalAlignment: Text.AlignRight } }
            }
          }
        }
      }

      ScrollView {
        id: simpleSettingsScroll
        anchors.fill: parent
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        Connections {
          target: root
          function onShowAdvancedChanged() {
            if (!root.showAdvanced) return
            Qt.callLater(function() {
              simpleSettingsScroll.contentItem.contentY = Math.max(0, simpleSettingsScroll.contentItem.contentHeight - simpleSettingsScroll.height)
            })
          }
        }
        Column {
          width: parent.width
          spacing: 12

          Column {
            width: parent.width
            height: 58
            spacing: 4
            TitleText { text: root.l("Settings", "设置") }
            MutedText { text: root.l("Essentials first; advanced controls stay tucked away", "常用设置优先，高级选项默认收起"); font.pixelSize: Style.font.subtitle }
          }

          Surface {
            width: parent.width
            height: 422
            Column {
              anchors.fill: parent
              anchors.margins: 18
              spacing: 12
              SectionLabel { text: root.l("GENERAL", "常规") }
              Dropdown { width: parent.width; label: root.l("App language", "应用语言"); value: String(root.settings.language || "en"); options: [{ value: "en", label: "English" }, { value: "zh", label: "简体中文" }]; foreground: root.foreground; accent: root.accent; onChanged: function(value) { root.settingSet("language", value) } }
              Dropdown { width: parent.width; label: root.l("Default dictation mode", "默认听写模式"); value: String(root.settings.default_mode || "smart"); options: [{ value: "smart", label: root.l("Polished", "智能润色") }, { value: "raw", label: root.l("Verbatim", "原文听写") }]; foreground: root.foreground; accent: root.accent; onChanged: function(value) { root.settingSet("default_mode", value) } }
              LabeledToggle { label: root.l("Save text history", "保存文字历史"); detail: root.l("Text and metadata stay on this device", "文字与元数据只保存在本机"); checked: root.settings.keep_history !== false; onToggled: root.settingSet("keep_history", checked) }
              LabeledToggle { label: root.l("Learn from speech segments", "从语音片段学习"); detail: root.l("Keeps a 20-item local audio buffer and saves only corrected phrase samples", "在本机暂存最近 20 条录音，并长期保留纠错词的语音片段"); checked: root.settings.acoustic_learning === true; onToggled: root.settingSet("acoustic_learning", checked) }
              LabeledToggle { label: root.l("Learn clear corrections automatically", "自动学习明确的纠错"); detail: root.l("Ambiguous or large edits still wait for review", "有歧义或改动较大的内容仍需确认"); checked: root.settings.auto_learn_corrections !== false; onToggled: root.settingSet("auto_learn_corrections", checked) }
              LabeledToggle { label: root.l("Paste terminal input as one block", "终端使用整段粘贴"); detail: root.l("Prevents terminal apps from splitting one sentence", "避免终端应用把一句话拆成多段"); checked: root.settings.terminal_paste !== false; onToggled: root.settingSet("terminal_paste", checked) }
            }
          }

          Surface {
            width: parent.width
            height: 254
            Column {
              anchors.fill: parent
              anchors.margins: 18
              spacing: 12
              SectionLabel { text: root.l("SHORTCUTS", "快捷键") }
              Row { width: parent.width; spacing: 16; BodyText { width: 200; text: root.l("Polished dictation", "智能润色"); anchors.verticalCenter: parent.verticalCenter } TextField { id: simpleSmartShortcutField; width: parent.width - 216; text: String(root.settings.smart_shortcut || "F9"); placeholderText: "F9"; foreground: root.foreground; accent: root.accent } }
              Row { width: parent.width; spacing: 16; BodyText { width: 200; text: root.l("Verbatim dictation", "原文听写"); anchors.verticalCenter: parent.verticalCenter } TextField { id: simpleRawShortcutField; width: parent.width - 216; text: String(root.settings.raw_shortcut || "SHIFT + F9"); placeholderText: "SHIFT + F9"; foreground: root.foreground; accent: root.accent } }
              Row { width: parent.width; spacing: 16; BodyText { width: 200; text: root.l("Learn correction", "纠错学习"); anchors.verticalCenter: parent.verticalCenter } TextField { id: simpleLearnShortcutField; width: parent.width - 216; text: String(root.settings.learn_shortcut || "CTRL + SHIFT + F9"); placeholderText: "CTRL + SHIFT + F9"; foreground: root.foreground; accent: root.accent } }
              Button { width: parent.width; text: root.l("Apply shortcuts", "应用快捷键"); bordered: true; foreground: root.accent; accent: root.accent; onClicked: root.saveShortcuts(simpleSmartShortcutField.text, simpleRawShortcutField.text, simpleLearnShortcutField.text) }
            }
          }

          Surface {
            width: parent.width
            height: root.showAdvanced ? 514 : 72
            Column {
              anchors.fill: parent
              anchors.margins: 18
              spacing: 12
              Button {
                width: parent.width
                height: 36
                text: root.showAdvanced ? root.l("Hide advanced settings", "收起高级设置") : root.l("Advanced settings", "高级设置")
                iconText: root.showAdvanced ? "󰅃" : "󰅀"
                leftAlign: true
                foreground: root.muted
                onClicked: root.showAdvanced = !root.showAdvanced
              }
              Column {
                visible: root.showAdvanced
                width: parent.width
                spacing: 10
                SectionLabel { text: root.l("POLISH PROMPT", "润色提示词") }
                MutedText { width: parent.width; text: root.l("Edit the local polisher instruction only when you need custom behavior.", "仅在需要自定义润色行为时修改本地模型提示词。"); wrapMode: Text.Wrap }
                TextArea {
                  id: simplePolishPromptField
                  width: parent.width
                  height: 270
                  text: String(root.settings.polish_prompt || "")
                  color: root.foreground
                  placeholderTextColor: root.muted
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  wrapMode: TextEdit.Wrap
                  background: Surface {}
                  padding: 12
                }
                Row {
                  width: parent.width
                  spacing: 12
                  Button { width: (parent.width - parent.spacing) / 2; text: root.l("Restore default", "恢复默认"); bordered: true; foreground: root.foreground; onClicked: root.runAction(["setting-reset", "polish_prompt"], "settings") }
                  Button { width: (parent.width - parent.spacing) / 2; text: root.l("Save prompt", "保存提示词"); bordered: true; foreground: root.accent; accent: root.accent; onClicked: root.savePolishPrompt(simplePolishPromptField.text) }
                }
                Row {
                  width: parent.width
                  spacing: 12
                  LabeledToggle { width: parent.width - 184; label: root.l("Preload local models at login", "登录时预热本地模型"); checked: root.settings.prewarm_models !== false; onToggled: root.settingSet("prewarm_models", checked) }
                  Button { width: 172; text: root.l("Diagnostics", "运行自检"); bordered: true; foreground: root.muted; onClicked: root.runAction(["doctor"], "") }
                }
              }
            }
          }
          MutedText { width: parent.width; text: root.l("LocalType 0.6.0 · Audio and history stay on this device", "LocalType 0.6.0 · 音频与历史数据都留在本机"); horizontalAlignment: Text.AlignHCenter }
        }
      }
    }
  }

  Popup {
    id: correctionEditor
    parent: appWindow.contentItem
    anchors.centerIn: parent
    width: Math.min(820, parent.width - 80)
    height: 430
    modal: true
    focus: true
    closePolicy: Popup.CloseOnEscape
    Overlay.modal: Rectangle { color: root.alpha(root.background, 0.74) }
    background: Rectangle {
      color: root.deepColor
      border.color: root.accent
      border.width: 1
      radius: Math.max(4, Style.cornerRadius)
    }
    contentItem: Column {
      anchors.fill: parent
      anchors.margins: 22
      spacing: 14
      TitleText { text: root.l("Correct & learn", "纠正并学习"); font.pixelSize: Style.font.heading }
      MutedText { width: parent.width; text: root.l("Edit the complete sentence. Clear local corrections are learned now; ambiguous edits wait for review.", "编辑完整句子。明确的局部纠错会立即学习，有歧义的修改仍会等待确认。") ; wrapMode: Text.Wrap }
      TextArea {
        id: correctionText
        width: parent.width
        height: 210
        color: root.foreground
        placeholderTextColor: root.muted
        font.family: root.fontFamily
        font.pixelSize: Style.font.subtitle
        wrapMode: TextEdit.Wrap
        background: Surface {}
        padding: 12
      }
      Row {
        width: parent.width
        spacing: 12
        Button { width: (parent.width - parent.spacing) / 2; text: root.l("Cancel", "取消"); bordered: true; foreground: root.foreground; onClicked: correctionEditor.close() }
        Button { width: (parent.width - parent.spacing) / 2; text: root.l("Learn correction", "学习纠错"); iconText: "󰛨"; bordered: true; foreground: root.accent; accent: root.accent; onClicked: root.proposeHistoryCorrection() }
      }
    }
  }
}
