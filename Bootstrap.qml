import QtQuick
import Quickshell.Io

Item {
  id: root
  visible: false

  readonly property string ctlPath: decodeURIComponent(String(Qt.resolvedUrl("bin/localtypectl")).replace(/^file:\/\//, ""))

  Process {
    id: bootstrap
    command: [root.ctlPath, "ensure-runtime"]

    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim() !== "") console.warn("LocalType setup:", text.trim())
    }
  }

  Timer {
    interval: 500
    running: true
    repeat: false
    onTriggered: if (!bootstrap.running) bootstrap.running = true
  }
}
