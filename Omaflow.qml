import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui

Item {
  id: root

  property var shell: null
  property var manifest: null

  property bool opened: false
  property var rules: []
  property var logEntries: []
  property var staging: null
  property string confirmDeleteId: ""

  readonly property string stateHome: Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state"
  readonly property string pluginDir: {
    var url = Qt.resolvedUrl(".").toString()
    return url.indexOf("file://") === 0 ? url.substring(7) : url
  }
  readonly property string cliPath: pluginDir + "bin/omaflow"

  readonly property bool compiling: staging !== null && staging.status === "compiling"
  readonly property bool previewOpen: staging !== null && staging.status === "ready"
  readonly property string stagingError: staging !== null && staging.status === "error" ? String(staging.error || "") : ""

  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property color scrim: Color.menu.scrim
  property color selectedBackground: Color.menu.selectedBackground
  property color selectedText: Color.menu.selectedText
  readonly property color accentColor: Color.accent
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  readonly property int cornerRadius: Style.cornerRadius
  readonly property int contentMargin: Style.spacing.panelPadding

  readonly property var spinnerFrames: ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
  property int spinnerFrame: 0

  readonly property int cardWidth: Math.min(Style.space(660), panel.width - Style.gapsOut * 2)
  readonly property int rowHeight: Math.max(
    Style.space(52),
    Math.round(Style.font.body * 1.6 + Style.font.caption * 1.4 + Style.spacing.sm * 2)
  )
  readonly property int maxVisibleRows: 6
  readonly property int visibleRows: Math.min(rulesModel.count, maxVisibleRows)
  readonly property int listHeight: visibleRows > 0
    ? visibleRows * rowHeight + (visibleRows - 1) * Style.spacing.sm
    : 0

  ListModel { id: rulesModel }

  function open(payloadJson) {
    root.confirmDeleteId = ""
    promptInput.text = ""
    indexFile.reload()
    logFile.reload()
    stagingFile.reload()
    root.opened = true
    Qt.callLater(function() {
      promptInput.forceActiveFocus()
    })
  }

  function close() {
    root.opened = false
  }

  function ping() {
    return "ok"
  }

  function dismiss() {
    root.opened = false
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "jesperlugner.omaflow")
  }

  function applyIndex(jsonText) {
    var parsed = ({})
    try { parsed = JSON.parse(jsonText || "{}") } catch (e) { parsed = ({}) }
    root.rules = parsed.rules || []
    var selId = ""
    if (rulesList.currentIndex >= 0 && rulesList.currentIndex < rulesModel.count)
      selId = rulesModel.get(rulesList.currentIndex).ruleId
    rulesModel.clear()
    for (var i = 0; i < root.rules.length; i++) {
      var rule = root.rules[i]
      rulesModel.append({
        ruleId: String(rule.id || ""),
        name: String(rule.name || rule.id || ""),
        enabled: rule.enabled === true,
        triggerSummary: String(rule.triggerSummary || ""),
        actionsSummary: String(rule.actionsSummary || ""),
        conditionCount: Number(rule.conditionCount || 0),
        lastFired: String(rule.lastFired || "")
      })
    }
    var next = rulesModel.count > 0 ? 0 : -1
    if (selId !== "") {
      for (var r = 0; r < rulesModel.count; r++) {
        if (rulesModel.get(r).ruleId === selId) { next = r; break }
      }
    }
    rulesList.currentIndex = next
  }

  function applyLog(text) {
    var lines = String(text || "").split("\n")
    var entries = []
    for (var i = lines.length - 1; i >= 0 && entries.length < 5; i--) {
      if (lines[i].trim() === "") continue
      try { entries.push(JSON.parse(lines[i])) } catch (e) {}
    }
    root.logEntries = entries
  }

  function applyStaging(jsonText) {
    if (!jsonText || jsonText.trim() === "") {
      root.staging = null
      return
    }
    try { root.staging = JSON.parse(jsonText) } catch (e) { root.staging = null }
  }

  function formatWhen(iso) {
    if (!iso) return "never"
    var d = new Date(iso)
    if (isNaN(d.getTime())) return iso
    var now = new Date()
    var hh = ("0" + d.getHours()).slice(-2)
    var mm = ("0" + d.getMinutes()).slice(-2)
    if (d.toDateString() === now.toDateString()) return hh + ":" + mm
    var months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    return d.getDate() + " " + months[d.getMonth()] + " " + hh + ":" + mm
  }

  function summarizeRule(rule) {
    if (!rule) return []
    var lines = []
    var t = rule.trigger || {}
    var when = String(t.type || "?")
    if (t.at) when += " at " + t.at
    if (t.days) when += " on " + t.days.join(", ")
    if (t.match) {
      if (t.match.description || t.match.name) when += ": " + (t.match.description || t.match.name)
      if (t.match.ssid) when += ": " + t.match.ssid
      if (t.match.known === false) when += ": a network never seen before"
    }
    if (t.source) when += ": " + t.source
    lines.push("When   " + when)
    var conds = rule.conditions || []
    for (var c = 0; c < conds.length; c++) {
      var cond = conds[c]
      var text = String(cond.type || "?")
      if (cond.from) text += " " + cond.from + "–" + cond.to
      if (cond.days) text += " " + cond.days.join(", ")
      if (cond.source) text += " " + cond.source
      if (cond.ssid) text += " " + cond.ssid
      if (cond.match) text += " " + (cond.match.description || cond.match.name || "")
      lines.push("Only if  " + text)
    }
    var actions = rule.actions || []
    for (var a = 0; a < actions.length; a++) {
      var action = actions[a]
      var atext = String(action.type || "?")
      if (action.name) atext += " → " + action.name
      if (action.state) atext += " → " + action.state
      if (action.app) atext += " → " + action.app + (action.workspace ? " (workspace " + action.workspace + ")" : "")
      if (action.number) atext += " → " + action.number
      if (action.match) atext += " → " + action.match
      if (action.message) atext += " → \"" + action.message + "\""
      lines.push((a === 0 ? "Do     " : "       ") + atext)
    }
    lines.push("Cooldown  " + String(rule.cooldownSeconds || 60) + "s")
    return lines
  }

  function currentRule() {
    if (rulesList.currentIndex < 0 || rulesList.currentIndex >= rulesModel.count)
      return null
    return rulesModel.get(rulesList.currentIndex)
  }

  function cli(args) {
    Quickshell.execDetached([root.cliPath].concat(args))
  }

  function startAuthoring() {
    var text = String(promptInput.text || "").trim()
    if (text === "" || root.compiling)
      return
    promptInput.text = ""
    root.staging = { status: "compiling", request: text }
    root.cli(["author", text])
  }

  function moveSelection(delta) {
    if (rulesModel.count === 0)
      return
    var next = rulesList.currentIndex + delta
    if (next < 0) next = 0
    if (next >= rulesModel.count) next = rulesModel.count - 1
    rulesList.currentIndex = next
  }

  FileView {
    id: indexFile
    path: root.stateHome + "/omaflow/index.json"
    watchChanges: true
    printErrors: false
    onLoaded: root.applyIndex(text())
    onFileChanged: reload()
    onLoadFailed: root.applyIndex("")
  }

  FileView {
    id: logFile
    path: root.stateHome + "/omaflow/log.jsonl"
    watchChanges: true
    printErrors: false
    onLoaded: root.applyLog(text())
    onFileChanged: reload()
    onLoadFailed: root.applyLog("")
  }

  FileView {
    id: stagingFile
    path: root.stateHome + "/omaflow/staging.json"
    watchChanges: true
    printErrors: false
    onLoaded: root.applyStaging(text())
    onFileChanged: reload()
    onLoadFailed: root.applyStaging("")
  }

  Timer {
    interval: 90
    repeat: true
    running: root.compiling && root.opened
    onTriggered: root.spinnerFrame = (root.spinnerFrame + 1) % root.spinnerFrames.length
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "jesperlugner-omaflow"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.dismiss()
    }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: Math.min(
        content.implicitHeight + card.contentTopInset + card.contentBottomInset,
        panel.height - Style.gapsOut * 2
      )
      anchors.centerIn: parent
      radius: root.cornerRadius
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      MouseArea { anchors.fill: parent; onClicked: {} }

      ConfirmDialog {
        id: confirmDialog
        anchors.fill: parent
        z: 20
        opened: root.confirmDeleteId !== ""
        message: "Delete rule " + root.confirmDeleteId + "?"
        cancelText: "Keep"
        confirmText: "Delete"
        background: root.background
        foreground: root.foreground
        scrim: root.scrim
        selectedBackground: root.selectedBackground
        selectedText: root.selectedText
        fontFamily: Style.font.menuFamily
        cornerRadius: root.cornerRadius
        onCanceled: {
          root.confirmDeleteId = ""
          promptInput.forceActiveFocus()
        }
        onConfirmed: {
          root.cli(["delete", root.confirmDeleteId])
          root.confirmDeleteId = ""
          promptInput.forceActiveFocus()
        }
      }

      // Preview of a staged (agent-compiled) rule.
      Item {
        anchors.fill: parent
        z: 15
        visible: root.previewOpen

        Rectangle {
          anchors.fill: parent
          color: root.scrim

          MouseArea { anchors.fill: parent; onClicked: root.cli(["stage", "reject"]) }
        }

        BorderSurface {
          id: previewCard
          width: Math.min(Style.space(560), parent.width - Style.space(24))
          height: Math.min(
            previewColumn.implicitHeight + previewCard.contentTopInset + previewCard.contentBottomInset,
            parent.height - Style.space(24)
          )
          anchors.centerIn: parent
          color: root.background
          borderSpec: Border.flat(root.selectedText, Style.normalBorderWidth)
          radius: root.cornerRadius
          padding: Style.spacing.md

          MouseArea { anchors.fill: parent; onClicked: {} }

          Column {
            id: previewColumn
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.topMargin: previewCard.contentTopInset
            anchors.leftMargin: previewCard.contentLeftInset
            anchors.rightMargin: previewCard.contentRightInset
            spacing: Style.spacing.sm

            Text {
              width: parent.width
              text: root.previewOpen ? String(root.staging.rule.name || root.staging.rule.id) : ""
              textFormat: Text.PlainText
              color: root.foreground
              font.family: Style.font.menuFamily
              font.pixelSize: Style.font.body
              font.weight: Font.DemiBold
              elide: Text.ElideRight
            }

            Text {
              width: parent.width
              text: root.previewOpen ? "“" + String(root.staging.request || "") + "”  ·  compiled by " + String(root.staging.agent || "?") : ""
              textFormat: Text.PlainText
              color: root.foreground
              opacity: 0.55
              font.family: Style.font.menuFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.Wrap
            }

            Repeater {
              model: root.previewOpen ? root.summarizeRule(root.staging.rule) : []

              Text {
                required property var modelData
                width: previewColumn.width
                text: modelData
                textFormat: Text.PlainText
                color: root.foreground
                font.family: Style.font.menuFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.Wrap
              }
            }

            Text {
              width: parent.width
              visible: root.previewOpen && (root.staging.warnings || []).length > 0
              text: root.previewOpen ? (root.staging.warnings || []).join("\n") : ""
              textFormat: Text.PlainText
              color: root.accentColor
              opacity: 0.9
              font.family: Style.font.menuFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.Wrap
            }

            Text {
              width: parent.width
              text: "↵ Install rule    Esc Discard"
              textFormat: Text.PlainText
              color: root.foreground
              opacity: 0.45
              font.family: Style.font.menuFamily
              font.pixelSize: Style.font.caption
              topPadding: Style.spacing.sm
            }
          }
        }
      }

      Column {
        id: content
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.topMargin: card.contentTopInset
        anchors.leftMargin: card.contentLeftInset
        anchors.rightMargin: card.contentRightInset
        spacing: Style.spacing.md

        Row {
          width: parent.width
          spacing: Style.spacing.sm

          Text {
            text: "Omaflow"
            color: root.foreground
            font.family: Style.font.menuFamily
            font.pixelSize: Style.font.body
            font.weight: Font.DemiBold
          }

          Text {
            text: "· " + rulesModel.count + (rulesModel.count === 1 ? " automation" : " automations")
            color: root.foreground
            opacity: 0.55
            font.family: Style.font.menuFamily
            font.pixelSize: Style.font.body
          }

          Text {
            visible: root.compiling
            text: root.spinnerFrames[root.spinnerFrame] + "  compiling…"
            color: root.accentColor
            opacity: 0.9
            font.family: Style.font.menuFamily
            font.pixelSize: Style.font.body
          }
        }

        Rectangle {
          width: parent.width
          height: Math.max(Style.space(40), Math.ceil(promptInput.contentHeight) + Style.spacing.md * 2)
          radius: root.cornerRadius
          color: Style.controlFill(promptInput.activeFocus, promptHover.containsMouse, root.foreground, root.accentColor)
          border.width: Style.controlBorderWidth(promptInput.activeFocus, promptHover.containsMouse)
          border.color: Style.controlBorder(promptInput.activeFocus, promptHover.containsMouse, root.foreground, root.accentColor)

          MouseArea {
            id: promptHover
            anchors.fill: parent
            hoverEnabled: true
            onClicked: promptInput.forceActiveFocus()
          }

          Text {
            anchors.left: parent.left
            anchors.leftMargin: Style.spacing.md
            anchors.verticalCenter: parent.verticalCenter
            visible: promptInput.text.length === 0
            text: "Describe an automation…"
            color: root.foreground
            opacity: 0.4
            font.family: Style.font.menuFamily
            font.pixelSize: Style.font.body
          }

          TextEdit {
            id: promptInput
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: Style.spacing.md
            anchors.rightMargin: Style.spacing.md
            anchors.verticalCenter: parent.verticalCenter
            textFormat: TextEdit.PlainText
            wrapMode: TextEdit.Wrap
            color: root.foreground
            selectionColor: root.selectedBackground
            selectedTextColor: root.selectedText
            font.family: Style.font.menuFamily
            font.pixelSize: Style.font.body

            Keys.onPressed: function(event) {
              if (root.confirmDeleteId !== "") {
                if (confirmDialog.handleKey(event))
                  event.accepted = true
                return
              }
              if (root.previewOpen) {
                if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                  root.cli(["stage", "accept"])
                  event.accepted = true
                } else if (event.key === Qt.Key_Escape) {
                  root.cli(["stage", "reject"])
                  event.accepted = true
                }
                return
              }
              if (event.key === Qt.Key_Escape) {
                if (promptInput.text.length > 0)
                  promptInput.text = ""
                else
                  root.dismiss()
                event.accepted = true
                return
              }
              if (event.key === Qt.Key_Up) {
                root.moveSelection(-1)
                event.accepted = true
              } else if (event.key === Qt.Key_Down) {
                root.moveSelection(1)
                event.accepted = true
              } else if (event.key === Qt.Key_E && (event.modifiers & Qt.ControlModifier) !== 0) {
                var toggleRule = root.currentRule()
                if (toggleRule)
                  root.cli([toggleRule.enabled ? "disable" : "enable", toggleRule.ruleId])
                event.accepted = true
              } else if (event.key === Qt.Key_Delete && (event.modifiers & Qt.AltModifier) !== 0) {
                var delRule = root.currentRule()
                if (delRule)
                  root.confirmDeleteId = delRule.ruleId
                event.accepted = true
              } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                if ((event.modifiers & Qt.AltModifier) !== 0) {
                  var runRule = root.currentRule()
                  if (runRule)
                    root.cli(["run", runRule.ruleId, "--trigger", "manual (overlay)"])
                } else if ((event.modifiers & Qt.ControlModifier) !== 0) {
                  var dryRule = root.currentRule()
                  if (dryRule)
                    root.cli(["run", dryRule.ruleId, "--dry-run"])
                } else {
                  root.startAuthoring()
                }
                event.accepted = true
              }
            }
          }
        }

        Text {
          width: parent.width
          visible: root.stagingError !== ""
          text: "⚠ " + root.stagingError
          textFormat: Text.PlainText
          color: root.foreground
          opacity: 0.7
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.Wrap
        }

        Text {
          width: parent.width
          visible: rulesModel.count === 0
          text: "No automations yet. Describe one above — “when I join a new wifi network, turn on do-not-disturb and notify me” — and the agent compiles it into a rule you can inspect before installing."
          textFormat: Text.PlainText
          color: root.foreground
          opacity: 0.55
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.body
          wrapMode: Text.Wrap
        }

        ListView {
          id: rulesList
          width: parent.width
          height: root.listHeight
          visible: rulesModel.count > 0
          model: rulesModel
          spacing: Style.spacing.sm
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          highlightMoveDuration: 80

          delegate: Rectangle {
            id: row
            width: ListView.view.width
            height: root.rowHeight
            radius: root.cornerRadius

            readonly property bool isCurrent: index === rulesList.currentIndex

            color: isCurrent ? root.selectedBackground
              : rowMouse.containsMouse ? Style.hoverFillFor(root.foreground, root.accentColor)
              : "transparent"

            Rectangle {
              id: enabledDot
              width: Style.space(8)
              height: width
              radius: width / 2
              anchors.left: parent.left
              anchors.leftMargin: Style.spacing.md
              anchors.verticalCenter: parent.verticalCenter
              color: model.enabled ? root.accentColor : "transparent"
              border.width: model.enabled ? 0 : 1
              border.color: root.foreground
              opacity: model.enabled ? 1 : 0.4
            }

            Column {
              anchors.left: enabledDot.right
              anchors.leftMargin: Style.spacing.md
              anchors.right: parent.right
              anchors.rightMargin: Style.spacing.md
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.spacing.xxs

              Text {
                width: parent.width
                text: model.name
                textFormat: Text.PlainText
                color: row.isCurrent ? root.selectedText : root.foreground
                opacity: model.enabled ? 1 : 0.55
                font.family: Style.font.menuFamily
                font.pixelSize: Style.font.body
                elide: Text.ElideRight
              }

              Text {
                width: parent.width
                text: model.triggerSummary
                  + (model.conditionCount > 0 ? " · " + model.conditionCount + (model.conditionCount === 1 ? " condition" : " conditions") : "")
                  + " → " + model.actionsSummary
                  + " · last: " + root.formatWhen(model.lastFired)
                textFormat: Text.PlainText
                color: row.isCurrent ? root.selectedText : root.foreground
                opacity: 0.55
                font.family: Style.font.menuFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }
            }

            MouseArea {
              id: rowMouse
              anchors.fill: parent
              hoverEnabled: true
              onClicked: rulesList.currentIndex = index
            }
          }
        }

        Column {
          width: parent.width
          visible: root.logEntries.length > 0
          spacing: Style.spacing.xxs

          Text {
            text: "Recent activity"
            color: root.foreground
            opacity: 0.55
            font.family: Style.font.menuFamily
            font.pixelSize: Style.font.caption
          }

          Repeater {
            model: root.logEntries

            Text {
              required property var modelData
              width: parent.width
              text: root.formatWhen(modelData.at) + "  " + String(modelData.kind || "")
                + "  " + String(modelData.ruleName || modelData.ruleId || "")
                + "  ·  " + String(modelData.status || "")
                + (modelData.trigger ? "  [" + modelData.trigger + "]" : "")
              textFormat: Text.PlainText
              color: modelData.status === "ok" ? root.foreground : root.accentColor
              opacity: modelData.status === "ok" ? 0.55 : 0.9
              font.family: Style.font.menuFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }
          }
        }

        Text {
          width: parent.width
          text: "↵ Compile    Alt+↵ Run now    Ctrl+↵ Dry-run    Ctrl+E Toggle    Alt+Del Delete"
          textFormat: Text.PlainText
          color: root.foreground
          opacity: 0.45
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }
    }
  }
}
