import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import qs.Commons

Item {
  id: root

  required property var runtimeState

  readonly property bool shown: runtimeState.recording || runtimeState.processing
  readonly property string partialText: String(runtimeState.record.partial_text || "").trim()
  readonly property string language: String(runtimeState.record.language || "en")
  property real wavePhase: 0

  function l(english, chinese) {
    return root.language === "zh" ? chinese : english
  }

  function finishRecording() {
    if (runtimeState.recording && !runtimeState.actionRunning)
      runtimeState.runAction(["toggle", String(runtimeState.record.mode || "smart")])
  }

  function cancelRecording() {
    if (runtimeState.recording && !runtimeState.actionRunning)
      runtimeState.runAction(["cancel"])
  }

  Timer {
    interval: 58
    running: root.shown
    repeat: true
    onTriggered: root.wavePhase += 0.34
  }

  Variants {
    model: Quickshell.screens

    PanelWindow {
      id: overlayWindow

      required property var modelData
      readonly property bool focusedOutput: Hyprland.focusedMonitor === null
        ? modelData === Quickshell.screens[0]
        : modelData.name === Hyprland.focusedMonitor.name

      screen: modelData
      visible: root.shown && focusedOutput
      anchors {
        top: true
        bottom: true
        left: true
        right: true
      }
      color: "transparent"
      exclusionMode: ExclusionMode.Ignore
      WlrLayershell.namespace: "localtype-dictation-overlay"
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

      // The transcript is visual-only. Only the compact control capsule takes
      // pointer input, so the overlay never blocks the application underneath.
      mask: Region { item: controlCapsule }

      Column {
        id: overlayColumn

        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 28
        spacing: 14
        opacity: overlayWindow.visible ? 1 : 0
        scale: overlayWindow.visible ? 1 : 0.94

        Behavior on opacity {
          NumberAnimation { duration: 150; easing.type: Easing.OutCubic }
        }
        Behavior on scale {
          NumberAnimation { duration: 180; easing.type: Easing.OutBack }
        }

        Rectangle {
          id: transcriptCard

          visible: root.runtimeState.recording && root.partialText !== ""
          width: Math.min(760, Math.max(320, transcriptText.implicitWidth + 40), overlayWindow.width - 64)
          height: Math.min(184, Math.max(56, transcriptText.implicitHeight + 30))
          anchors.horizontalCenter: parent.horizontalCenter
          radius: 17
          color: "#2d63ea"

          Rectangle {
            anchors.fill: parent
            anchors.margins: 1
            radius: parent.radius - 1
            color: "transparent"
            border.width: 1
            border.color: Qt.rgba(1, 1, 1, 0.12)
          }

          Text {
            id: transcriptText

            anchors.fill: parent
            anchors.leftMargin: 20
            anchors.rightMargin: 20
            anchors.topMargin: 15
            anchors.bottomMargin: 15
            text: root.partialText
            color: "white"
            font.family: Style.font.family
            font.pixelSize: Math.max(15, Style.font.body)
            font.weight: Font.Medium
            wrapMode: Text.Wrap
            maximumLineCount: 6
            elide: Text.ElideRight
            lineHeight: 1.18
          }
        }

        Rectangle {
          id: controlCapsule

          width: root.runtimeState.processing ? 126 : 154
          height: 50
          anchors.horizontalCenter: parent.horizontalCenter
          radius: height / 2
          color: Qt.rgba(0.025, 0.027, 0.032, 0.97)
          border.width: 1
          border.color: Qt.rgba(1, 1, 1, 0.14)

          Behavior on width {
            NumberAnimation { duration: 180; easing.type: Easing.OutCubic }
          }

          Rectangle {
            anchors.fill: parent
            anchors.margins: 2
            radius: parent.radius - 2
            color: "transparent"
            border.width: 1
            border.color: Qt.rgba(1, 1, 1, 0.05)
          }

          Row {
            visible: root.runtimeState.recording
            anchors.centerIn: parent
            spacing: 10

            Rectangle {
              id: cancelButton

              width: 36
              height: 36
              radius: 18
              color: cancelMouse.containsMouse ? Qt.rgba(1, 1, 1, 0.18) : Qt.rgba(1, 1, 1, 0.10)

              Text {
                anchors.centerIn: parent
                text: "×"
                color: "white"
                font.family: Style.font.family
                font.pixelSize: 25
                font.weight: Font.Light
                anchors.verticalCenterOffset: -1
              }

              MouseArea {
                id: cancelMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.cancelRecording()
              }
            }

            Item {
              width: 52
              height: 36

              Row {
                anchors.centerIn: parent
                spacing: 3

                Repeater {
                  model: 9

                  Rectangle {
                    required property int index
                    width: 3
                    height: 6 + Math.abs(Math.sin(root.wavePhase + index * 0.72)) * (index % 2 === 0 ? 20 : 15)
                    anchors.verticalCenter: parent.verticalCenter
                    radius: width / 2
                    color: "white"

                    Behavior on height {
                      NumberAnimation { duration: 70; easing.type: Easing.InOutSine }
                    }
                  }
                }
              }
            }

            Rectangle {
              id: finishButton

              width: 36
              height: 36
              radius: 18
              color: finishMouse.containsMouse ? "white" : Qt.rgba(1, 1, 1, 0.94)

              Text {
                anchors.centerIn: parent
                text: "✓"
                color: "#101116"
                font.family: Style.font.family
                font.pixelSize: 21
                font.weight: Font.DemiBold
                anchors.verticalCenterOffset: -1
              }

              MouseArea {
                id: finishMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.finishRecording()
              }
            }
          }

          Row {
            visible: root.runtimeState.processing
            anchors.centerIn: parent
            spacing: 9

            Row {
              anchors.verticalCenter: parent.verticalCenter
              spacing: 3

              Repeater {
                model: 3

                Rectangle {
                  required property int index
                  width: 4
                  height: 4
                  radius: 2
                  color: "white"
                  opacity: 0.28 + 0.72 * Math.abs(Math.sin(root.wavePhase * 0.72 + index * 0.9))
                }
              }
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: root.l("Polishing…", "正在整理…")
              color: "white"
              font.family: Style.font.family
              font.pixelSize: Math.max(13, Style.font.caption)
              font.weight: Font.Medium
            }
          }
        }
      }
    }
  }
}
