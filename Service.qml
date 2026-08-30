import QtQuick
import Quickshell
import Quickshell.Io

Item {
  id: root

  readonly property string ctlPath: decodeURIComponent(String(Qt.resolvedUrl("bin/localtypectl")).replace(/^file:\/\//, ""))

  LocalTypeState {
    id: runtimeState
    ctlPath: root.ctlPath
    statusCommand: "overlay-status"
    refreshInterval: 2600
  }

  DictationOverlay {
    id: dictationOverlay
    runtimeState: runtimeState
  }

  IpcHandler {
    target: "app.localtype.voice-input.overlay"

    function refresh(): string {
      runtimeState.refresh()
      return "ok"
    }

    function state(): string {
      return JSON.stringify({
        shown: dictationOverlay.shown,
        phase: runtimeState.phase,
        recording: runtimeState.recording,
        processing: runtimeState.processing
      })
    }
  }

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
