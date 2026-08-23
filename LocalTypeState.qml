import QtQuick
import Quickshell.Io

Item {
  id: root
  visible: false

  required property string ctlPath
  property int refreshInterval: 3000
  property var record: ({})
  property string actionError: ""
  property bool actionRunning: actionProcess.running

  readonly property string phase: String(record.phase || "starting")
  readonly property bool backendReady: record.backend_ready === true
  readonly property bool serviceActive: record.service_active === true
  readonly property bool recording: record.recording === true || phase === "recording"
  readonly property bool processing: phase === "processing"
  readonly property bool installing: phase === "installing"
  readonly property var gpu: record.gpu || ({})

  signal refreshed()

  function refresh() {
    if (root.ctlPath !== "" && !statusProcess.running) statusProcess.running = true
  }

  function runAction(arguments) {
    if (root.ctlPath === "" || actionProcess.running) return
    root.actionError = ""
    actionProcess.command = [root.ctlPath].concat(arguments)
    actionProcess.running = true
  }

  function applyStatus(output) {
    try {
      var value = JSON.parse(String(output || "{}"))
      root.record = value && typeof value === "object" ? value : ({})
      root.actionError = ""
      root.refreshed()
    } catch (error) {
      root.actionError = "状态数据无法解析"
    }
  }

  Process {
    id: statusProcess
    running: false
    command: [root.ctlPath, "status"]

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyStatus(text)
    }

    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim() !== "") root.actionError = text.trim()
    }
  }

  Process {
    id: actionProcess
    running: false

    onExited: {
      root.refresh()
    }

    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim() !== "") root.actionError = text.trim()
    }
  }

  Timer {
    id: refreshTimer
    interval: root.recording || root.processing || root.installing ? 650 : Math.max(1000, root.refreshInterval)
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }
}
