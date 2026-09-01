import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import qs.Commons

Item {
  id: root

  required property var runtimeState

  readonly property bool shown: (runtimeState.recording || runtimeState.processing || runtimeState.reviewing)
    && !(runtimeState.reviewing && submitting)
  readonly property string partialText: String(runtimeState.record.partial_text || "").trim()
  readonly property string reviewText: String(runtimeState.record.review_text || "")
  readonly property string language: String(runtimeState.record.language || "en")
  property real wavePhase: 0
  property bool submitting: false

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

  function commitReview(text) {
    if (runtimeState.reviewing && !runtimeState.actionRunning && String(text).trim() !== "") {
      // Unmap the exclusive layer before starting the paste process. Waiting in
      // the controller is not sufficient because a status refresh can already
      // be in flight and delay the visible state update by one polling cycle.
      submitting = true
      runtimeState.runAction(["review-commit", String(text)])
    }
  }

  function cancelReview() {
    if (runtimeState.reviewing && !runtimeState.actionRunning) {
      submitting = true
      runtimeState.runAction(["review-cancel"])
    }
  }

  Connections {
    target: root.runtimeState
    function onActionFinished() {
      root.submitting = false
    }
    function onRefreshed() {
      if (root.runtimeState.recording || root.runtimeState.processing)
        root.submitting = false
    }
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
      property bool reviewLoaded: false

      Timer {
        interval: 80
        running: overlayWindow.visible && root.runtimeState.reviewing && !transcriptEditor.activeFocus
        repeat: true
        onTriggered: transcriptEditor.forceActiveFocus()
      }

      Shortcut {
        sequence: "Escape"
        enabled: overlayWindow.visible && root.runtimeState.reviewing
        onActivated: root.cancelReview()
      }

      Shortcut {
        sequence: "Return"
        enabled: overlayWindow.visible && root.runtimeState.reviewing
        onActivated: root.commitReview(transcriptEditor.text)
      }

      Shortcut {
        sequence: "Enter"
        enabled: overlayWindow.visible && root.runtimeState.reviewing
        onActivated: root.commitReview(transcriptEditor.text)
      }

      Connections {
        target: root.runtimeState
        function onRefreshed() {
          if (root.runtimeState.reviewing && !overlayWindow.reviewLoaded) {
            overlayWindow.reviewLoaded = true
            transcriptEditor.text = root.reviewText
            Qt.callLater(function() {
              transcriptEditor.forceActiveFocus()
              transcriptEditor.cursorPosition = transcriptEditor.length
            })
          } else if (!root.runtimeState.reviewing) {
            overlayWindow.reviewLoaded = false
          }
        }
      }

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
      WlrLayershell.keyboardFocus: root.runtimeState.reviewing && !root.submitting
        ? WlrKeyboardFocus.Exclusive
        : WlrKeyboardFocus.None

      // Recording previews remain click-through. Review mode intentionally
      // owns the editor area and keyboard until Enter or Escape is pressed.
      mask: Region { item: root.runtimeState.reviewing ? overlayColumn : controlCapsule }

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

          visible: (root.runtimeState.recording && root.partialText !== "") || root.runtimeState.reviewing
          width: root.runtimeState.reviewing
            ? Math.min(760, overlayWindow.width - 64)
            : Math.min(760, Math.max(320, transcriptText.implicitWidth + 40), overlayWindow.width - 64)
          height: root.runtimeState.reviewing
            ? 180
            : Math.min(184, Math.max(56, transcriptText.implicitHeight + 30))
          anchors.horizontalCenter: parent.horizontalCenter
          radius: 17
          color: root.runtimeState.reviewing ? Qt.rgba(0.04, 0.045, 0.06, 0.98) : "#2d63ea"

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

            visible: !root.runtimeState.reviewing
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

          TextEdit {
            id: transcriptEditor

            visible: root.runtimeState.reviewing
            anchors.fill: parent
            anchors.margins: 17
            color: "white"
            selectionColor: "#2d63ea"
            selectedTextColor: "white"
            font.family: Style.font.family
            font.pixelSize: Math.max(16, Style.font.body)
            font.weight: Font.Medium
            wrapMode: TextEdit.Wrap
            selectByMouse: true
            activeFocusOnTab: true
            Keys.onPressed: function(event) {
              if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter)
                  && !(event.modifiers & Qt.ShiftModifier)) {
                event.accepted = true
                root.commitReview(transcriptEditor.text)
              } else if (event.key === Qt.Key_Escape) {
                event.accepted = true
                root.cancelReview()
              }
            }
          }
        }

        Rectangle {
          id: controlCapsule

          width: root.runtimeState.reviewing ? 244 : (root.runtimeState.processing ? 126 : 154)
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
            visible: root.runtimeState.reviewing
            anchors.centerIn: parent
            spacing: 8

            Rectangle {
              width: 76
              height: 36
              radius: 18
              color: reviewCancelMouse.containsMouse ? Qt.rgba(1, 1, 1, 0.16) : Qt.rgba(1, 1, 1, 0.08)

              Text {
                anchors.centerIn: parent
                text: root.l("Cancel", "取消")
                color: Qt.rgba(1, 1, 1, 0.72)
                font.family: Style.font.family
                font.pixelSize: Math.max(12, Style.font.caption)
              }

              MouseArea {
                id: reviewCancelMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.cancelReview()
              }
            }

            Rectangle {
              width: 144
              height: 36
              radius: 18
              color: reviewCommitMouse.containsMouse ? "white" : Qt.rgba(1, 1, 1, 0.94)

              Text {
                anchors.centerIn: parent
                text: root.l("Enter · Paste", "Enter · 粘贴")
                color: "#101116"
                font.family: Style.font.family
                font.pixelSize: Math.max(13, Style.font.caption)
                font.weight: Font.DemiBold
              }

              MouseArea {
                id: reviewCommitMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.commitReview(transcriptEditor.text)
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
