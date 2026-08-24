pragma ComponentBehavior: Bound

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
  property bool editorMode: false
  property bool editorLoading: false
  property string editorId: ""
  property string editorCreatedAt: ""
  property string editorSource: ""
  property bool editorEnabled: true
  property var editorTrigger: ({ type: "manual" })

  readonly property var triggerTypes: ["manual", "time", "interval", "lid-opened", "lid-closed", "monitor-connected", "monitor-disconnected", "app-opened", "app-closed", "wifi-connected", "wifi-disconnected", "power-source", "custom"]
  readonly property var conditionTypes: ["time-between", "weekday", "on-power", "lid-state", "monitor-present", "app-running", "on-ssid"]
  readonly property var actionTypes: ["theme", "dnd", "nightlight", "stay-awake", "launch", "workspace", "audio-output", "script", "webhook", "notify", "agent"]
  readonly property var weekdays: ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]
  readonly property var agentOps: ["close-window", "focus-window", "move-window-to-workspace", "notify"]

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

  readonly property int cardWidth: Math.min(Style.space(root.editorMode ? 760 : 660), panel.width - Style.gapsOut * 2)
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
  ListModel { id: editorConditions; dynamicRoles: true }
  ListModel { id: editorActions; dynamicRoles: true }

  function open(payloadJson) {
    root.confirmDeleteId = ""
    root.editorMode = false
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

  function clone(value) {
    return JSON.parse(JSON.stringify(value))
  }

  function cycleValue(values, value, delta) {
    var index = values.indexOf(value)
    if (index < 0) index = 0
    return values[(index + delta + values.length) % values.length]
  }

  function defaultTrigger(type) {
    if (type === "time") return { type: type, at: "09:00", days: root.weekdays.slice() }
    if (type === "interval") return { type: type, minutes: 60 }
    if (type === "monitor-connected" || type === "monitor-disconnected")
      return { type: type, match: { description: "" } }
    if (type === "app-opened" || type === "app-closed") return { type: type, match: { class: "" } }
    if (type === "wifi-connected") return { type: type, match: { ssid: "*" } }
    if (type === "power-source") return { type: type, source: "ac" }
    if (type === "custom") return { type: type, name: "" }
    return { type: type }
  }

  function defaultCondition(type) {
    var condition = { type: type, first: "", second: "", choice: "", selected: "" }
    if (type === "time-between") { condition.first = "09:00"; condition.second = "17:00" }
    else if (type === "weekday") condition.selected = root.weekdays.join(",")
    else if (type === "on-power") condition.choice = "ac"
    else if (type === "lid-state") condition.choice = "open"
    return condition
  }

  function defaultAction(type) {
    var action = { type: type, first: "", second: "", choice: "on", number: "", selected: "" }
    if (type === "launch") action.number = ""
    else if (type === "workspace") action.number = "1"
    else if (type === "agent") action.selected = "notify"
    return action
  }

  function wordsContain(words, value) {
    return String(words || "").split(",").indexOf(value) >= 0
  }

  function toggleWord(words, value) {
    var values = String(words || "").split(",").filter(function(entry) { return entry !== "" })
    var index = values.indexOf(value)
    if (index >= 0) values.splice(index, 1)
    else values.push(value)
    return values.join(",")
  }

  function integerOrText(value) {
    var text = String(value || "").trim()
    return /^-?\d+$/.test(text) ? Number(text) : text
  }

  function slugify(value) {
    var slug = String(value || "").toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "")
    return (slug || "manual-rule").substring(0, 41).replace(/-+$/g, "")
  }

  function uniqueRuleId(base) {
    var candidate = base
    var suffix = 2
    var used = function(id) {
      for (var i = 0; i < rulesModel.count; i++)
        if (rulesModel.get(i).ruleId === id) return true
      return false
    }
    while (used(candidate) && suffix < 100) {
      var ending = "-" + suffix
      candidate = base.substring(0, 41 - ending.length).replace(/-+$/g, "") + ending
      suffix += 1
    }
    return candidate
  }

  function startNewEditor() {
    root.editorId = ""
    root.editorCreatedAt = ""
    root.editorSource = ""
    root.editorEnabled = true
    root.editorTrigger = root.defaultTrigger("manual")
    editorConditions.clear()
    editorActions.clear()
    editorActions.append(root.defaultAction("notify"))
    editorName.text = ""
    editorCooldown.text = "60"
    root.editorLoading = false
    root.editorMode = true
    Qt.callLater(function() { triggerSelector.forceActiveFocus() })
  }

  function startEditCurrent() {
    var selected = root.currentRule()
    if (!selected || root.editorLoading) return
    root.editorLoading = true
    root.editorMode = true
    Qt.callLater(function() { editor.forceActiveFocus() })
    describeProcess.command = [root.cliPath, "describe", selected.ruleId]
    describeProcess.running = true
  }

  function loadEditorRule(rule) {
    root.editorId = String(rule.id || "")
    root.editorCreatedAt = String(rule.createdAt || new Date().toISOString())
    root.editorSource = String(rule.source || "")
    root.editorEnabled = rule.enabled === true
    root.editorTrigger = root.clone(rule.trigger || root.defaultTrigger("manual"))
    if (root.editorTrigger.type === "time" && root.editorTrigger.days === undefined) {
      var timeTrigger = root.clone(root.editorTrigger)
      timeTrigger.days = root.weekdays.slice()
      root.editorTrigger = timeTrigger
    }
    editorName.text = String(rule.name || rule.id || "")
    editorCooldown.text = String(rule.cooldownSeconds === undefined ? 60 : rule.cooldownSeconds)
    editorConditions.clear()
    var conditions = rule.conditions || []
    for (var i = 0; i < conditions.length; i++) {
      var condition = root.defaultCondition(String(conditions[i].type || "time-between"))
      if (condition.type === "time-between") { condition.first = String(conditions[i].from || ""); condition.second = String(conditions[i].to || "") }
      else if (condition.type === "weekday") condition.selected = (conditions[i].days || []).join(",")
      else if (condition.type === "on-power") condition.choice = String(conditions[i].source || "ac")
      else if (condition.type === "lid-state") condition.choice = String(conditions[i].state || "open")
      else if (condition.type === "monitor-present") condition.first = String((conditions[i].match || {}).description || (conditions[i].match || {}).name || "")
      else if (condition.type === "app-running") {
        condition.first = String((conditions[i].match || {}).class || "")
        condition.second = String((conditions[i].match || {}).title || "")
      }
      else if (condition.type === "on-ssid") condition.first = String(conditions[i].ssid || "")
      editorConditions.append(condition)
    }
    editorActions.clear()
    var actions = rule.actions || []
    for (var a = 0; a < actions.length; a++) {
      var action = root.defaultAction(String(actions[a].type || "notify"))
      if (action.type === "theme" || action.type === "script") action.first = String(actions[a].name || "")
      else if (action.type === "dnd" || action.type === "nightlight" || action.type === "stay-awake") action.choice = String(actions[a].state || "on")
      else if (action.type === "launch") { action.first = String(actions[a].app || ""); action.number = actions[a].workspace === undefined ? "" : String(actions[a].workspace) }
      else if (action.type === "workspace") action.number = String(actions[a].number || "")
      else if (action.type === "audio-output") action.first = String(actions[a].match || "")
      else if (action.type === "webhook") { action.first = String(actions[a].endpoint || ""); action.second = String(actions[a].message || "") }
      else if (action.type === "notify") { action.first = String(actions[a].title || ""); action.second = String(actions[a].message || "") }
      else if (action.type === "agent") {
        action.first = String(actions[a].task || "")
        action.selected = (actions[a].can || []).join(",")
        action.number = actions[a].timeoutSeconds === undefined ? "" : String(actions[a].timeoutSeconds)
      }
      editorActions.append(action)
    }
    if (editorActions.count === 0) editorActions.append(root.defaultAction("notify"))
    root.editorLoading = false
    Qt.callLater(function() { triggerSelector.forceActiveFocus() })
  }

  function conditionRule(condition) {
    if (condition.type === "time-between") return { type: condition.type, from: condition.first, to: condition.second }
    if (condition.type === "weekday") return { type: condition.type, days: String(condition.selected || "").split(",").filter(function(value) { return value !== "" }) }
    if (condition.type === "on-power") return { type: condition.type, source: condition.choice }
    if (condition.type === "lid-state") return { type: condition.type, state: condition.choice }
    if (condition.type === "monitor-present") return { type: condition.type, match: { description: condition.first } }
    if (condition.type === "app-running") {
      var match = String(condition.first || "").trim() !== "" ? { class: condition.first } : { title: condition.second }
      return { type: condition.type, match: match }
    }
    return { type: condition.type, ssid: condition.first }
  }

  function actionRule(action) {
    if (action.type === "theme" || action.type === "script") return { type: action.type, name: action.first }
    if (action.type === "dnd" || action.type === "nightlight" || action.type === "stay-awake") return { type: action.type, state: action.choice }
    if (action.type === "launch") {
      var launch = { type: action.type, app: action.first }
      if (String(action.number || "").trim() !== "") launch.workspace = root.integerOrText(action.number)
      return launch
    }
    if (action.type === "workspace") return { type: action.type, number: root.integerOrText(action.number) }
    if (action.type === "audio-output") return { type: action.type, match: action.first }
    if (action.type === "webhook") return { type: action.type, endpoint: action.first, message: action.second }
    if (action.type === "notify") {
      var notification = { type: action.type, message: action.second }
      if (String(action.first || "").trim() !== "") notification.title = action.first
      return notification
    }
    var agentAction = { type: action.type, task: action.first, can: String(action.selected || "").split(",").filter(function(value) { return value !== "" }) }
    if (String(action.number || "").trim() !== "") agentAction.timeoutSeconds = root.integerOrText(action.number)
    return agentAction
  }

  function composedTrigger() {
    var trigger = root.clone(root.editorTrigger)
    if (trigger.type === "interval") trigger.minutes = root.integerOrText(trigger.minutes)
    return trigger
  }

  function saveEditor() {
    var name = String(editorName.text || "").trim()
    var rule = {
      schemaVersion: 1,
      id: root.editorId || root.uniqueRuleId(root.slugify(name)),
      name: name,
      enabled: root.editorEnabled,
      trigger: root.composedTrigger(),
      conditions: [],
      actions: [],
      cooldownSeconds: root.integerOrText(editorCooldown.text),
      source: root.editorSource || "manual editor",
      createdBy: "manual"
    }
    if (root.editorCreatedAt !== "") rule.createdAt = root.editorCreatedAt
    for (var c = 0; c < editorConditions.count; c++) rule.conditions.push(root.conditionRule(editorConditions.get(c)))
    for (var a = 0; a < editorActions.count; a++) rule.actions.push(root.actionRule(editorActions.get(a)))
    var temporaryPath = root.stateHome + "/omaflow/.editor-rule." + Date.now() + ".json"
    var writer = "umask 077; trap 'rm -f -- \"$2\"' EXIT; printf '%s' \"$1\" > \"$2\"; \"$3\" stage-file \"$2\""
    Quickshell.execDetached(["/bin/sh", "-c", writer, "omaflow-editor", JSON.stringify(rule), temporaryPath, root.cliPath])
    root.editorMode = false
    Qt.callLater(function() { promptInput.forceActiveFocus() })
  }

  function cancelEditor() {
    root.editorMode = false
    root.editorLoading = false
    Qt.callLater(function() { promptInput.forceActiveFocus() })
  }

  function revealEditorNode(item) {
    if (!item || !item.activeFocus) return
    Qt.callLater(function() {
      var point = item.mapToItem(editorChain, 0, 0)
      var margin = Style.spacing.sm
      if (point.y < editorScroll.contentY + margin)
        editorScroll.contentY = Math.max(0, point.y - margin)
      else if (point.y + item.height > editorScroll.contentY + editorScroll.height - margin)
        editorScroll.contentY = Math.min(editorScroll.contentHeight - editorScroll.height, point.y + item.height - editorScroll.height + margin)
    })
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
    if (t.minutes) when += " every " + t.minutes + " minutes"
    if (t.days) when += " on " + t.days.join(", ")
    if (t.match) {
      if (t.match.description || t.match.name) when += ": " + (t.match.description || t.match.name)
      if (t.match.class || t.match.title) when += ": " + (t.match.class || t.match.title)
      if (t.match.ssid) when += ": " + t.match.ssid
      if (t.match.known === false) when += ": a network never seen before"
    }
    if (t.name) when += ": " + t.name
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
      if (cond.match) text += " " + (cond.match.description || cond.match.name || cond.match.class || cond.match.title || "")
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
      if (action.endpoint) atext += " → " + action.endpoint  // webhook: show WHERE it sends
      if (action.title) atext += " → [" + action.title + "]"
      if (action.message) atext += " \"" + action.message + "\""
      if (action.task) atext += " → " + action.task
      if (action.can) atext += " [can: " + action.can.join(", ") + "]"
      lines.push((a === 0 ? "Do     " : "       ") + atext)
    }
    var cooldown = (rule.cooldownSeconds === undefined || rule.cooldownSeconds === null)
      ? 60 : rule.cooldownSeconds
    lines.push("Cooldown  " + cooldown + "s")
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

  component EditorButton: Rectangle {
    id: editorButton
    property string label: ""
    property bool strong: false
    property bool tabFocus: true
    signal clicked()

    activeFocusOnTab: tabFocus
    implicitWidth: buttonLabel.implicitWidth + Style.spacing.md * 2
    implicitHeight: Math.max(Style.space(30), buttonLabel.implicitHeight + Style.spacing.sm)
    radius: root.cornerRadius
    color: strong ? root.accentColor : Style.controlFill(activeFocus, buttonMouse.containsMouse, root.foreground, root.accentColor)
    border.width: strong ? 0 : Style.controlBorderWidth(activeFocus, buttonMouse.containsMouse)
    border.color: Style.controlBorder(activeFocus, buttonMouse.containsMouse, root.foreground, root.accentColor)

    Text {
      id: buttonLabel
      anchors.centerIn: parent
      text: editorButton.label
      textFormat: Text.PlainText
      color: editorButton.strong ? root.selectedText : root.foreground
      font.family: Style.font.menuFamily
      font.pixelSize: Style.font.caption
    }

    MouseArea {
      id: buttonMouse
      anchors.fill: parent
      hoverEnabled: true
      onClicked: {
        editorButton.forceActiveFocus()
        editorButton.clicked()
      }
    }

    Keys.onPressed: function(event) {
      if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
        editorButton.clicked()
        event.accepted = true
      }
    }
  }

  component EditorField: Rectangle {
    id: editorField
    property alias text: fieldInput.text
    property string placeholder: ""
    property bool multiline: false
    property int preferredHeight: Style.space(34)

    implicitHeight: Math.max(preferredHeight, Math.ceil(fieldInput.contentHeight) + Style.spacing.sm * 2)
    radius: root.cornerRadius
    color: Style.controlFill(fieldInput.activeFocus, fieldMouse.containsMouse, root.foreground, root.accentColor)
    border.width: Style.controlBorderWidth(fieldInput.activeFocus, fieldMouse.containsMouse)
    border.color: Style.controlBorder(fieldInput.activeFocus, fieldMouse.containsMouse, root.foreground, root.accentColor)

    MouseArea {
      id: fieldMouse
      anchors.fill: parent
      hoverEnabled: true
      onClicked: fieldInput.forceActiveFocus()
    }

    Text {
      anchors.left: parent.left
      anchors.leftMargin: Style.spacing.sm
      anchors.verticalCenter: parent.verticalCenter
      visible: fieldInput.text.length === 0
      text: editorField.placeholder
      textFormat: Text.PlainText
      color: root.foreground
      opacity: 0.35
      font.family: Style.font.menuFamily
      font.pixelSize: Style.font.caption
    }

    TextEdit {
      id: fieldInput
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.leftMargin: Style.spacing.sm
      anchors.rightMargin: Style.spacing.sm
      anchors.verticalCenter: parent.verticalCenter
      activeFocusOnTab: true
      textFormat: TextEdit.PlainText
      wrapMode: editorField.multiline ? TextEdit.Wrap : TextEdit.NoWrap
      color: root.foreground
      selectionColor: root.selectedBackground
      selectedTextColor: root.selectedText
      font.family: Style.font.menuFamily
      font.pixelSize: Style.font.caption

      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
          var forward = event.key === Qt.Key_Tab && (event.modifiers & Qt.ShiftModifier) === 0
          fieldInput.nextItemInFocusChain(forward).forceActiveFocus()
          event.accepted = true
        }
      }
    }
  }

  component TypeSelector: FocusScope {
    id: typeSelector
    property string value: ""
    signal cycle(int delta)

    activeFocusOnTab: true
    implicitHeight: Style.space(34)

    Rectangle {
      anchors.fill: parent
      radius: root.cornerRadius
      color: Style.controlFill(typeSelector.activeFocus, selectorMouse.containsMouse, root.foreground, root.accentColor)
      border.width: Style.controlBorderWidth(typeSelector.activeFocus, selectorMouse.containsMouse)
      border.color: Style.controlBorder(typeSelector.activeFocus, selectorMouse.containsMouse, root.foreground, root.accentColor)
    }

    Text {
      anchors.left: parent.left
      anchors.leftMargin: Style.spacing.sm
      anchors.verticalCenter: parent.verticalCenter
      text: "‹"
      color: root.foreground
      opacity: 0.65
      font.family: Style.font.menuFamily
      font.pixelSize: Style.font.body
    }

    Text {
      anchors.centerIn: parent
      text: typeSelector.value
      textFormat: Text.PlainText
      color: root.foreground
      font.family: Style.font.menuFamily
      font.pixelSize: Style.font.caption
      font.weight: Font.DemiBold
    }

    Text {
      anchors.right: parent.right
      anchors.rightMargin: Style.spacing.sm
      anchors.verticalCenter: parent.verticalCenter
      text: "›"
      color: root.foreground
      opacity: 0.65
      font.family: Style.font.menuFamily
      font.pixelSize: Style.font.body
    }

    MouseArea {
      id: selectorMouse
      anchors.fill: parent
      hoverEnabled: true
      onClicked: function(mouse) {
        typeSelector.forceActiveFocus()
        typeSelector.cycle(mouse.x < width / 2 ? -1 : 1)
      }
    }

    Keys.onPressed: function(event) {
      if (event.key === Qt.Key_Left || event.key === Qt.Key_Right) {
        typeSelector.cycle(event.key === Qt.Key_Left ? -1 : 1)
        event.accepted = true
      }
    }
  }

  component ChoiceSelector: FocusScope {
    id: choiceSelector
    property string first: "on"
    property string second: "off"
    property string value: first
    signal selected(string value)

    activeFocusOnTab: true
    implicitHeight: Style.space(32)

    Row {
      anchors.fill: parent

      Repeater {
        model: [choiceSelector.first, choiceSelector.second]

        Rectangle {
          required property string modelData
          width: choiceSelector.width / 2
          height: choiceSelector.height
          radius: root.cornerRadius
          color: choiceSelector.value === modelData ? root.selectedBackground : "transparent"
          border.width: choiceSelector.activeFocus ? Style.normalBorderWidth : 1
          border.color: choiceSelector.activeFocus ? root.accentColor : root.border

          Text {
            anchors.centerIn: parent
            text: modelData
            textFormat: Text.PlainText
            color: choiceSelector.value === modelData ? root.selectedText : root.foreground
            font.family: Style.font.menuFamily
            font.pixelSize: Style.font.caption
          }

          MouseArea {
            anchors.fill: parent
            onClicked: {
              choiceSelector.forceActiveFocus()
              choiceSelector.selected(modelData)
            }
          }
        }
      }
    }

    Keys.onPressed: function(event) {
      if (event.key === Qt.Key_Left || event.key === Qt.Key_Right || event.key === Qt.Key_Space) {
        choiceSelector.selected(choiceSelector.value === choiceSelector.first ? choiceSelector.second : choiceSelector.first)
        event.accepted = true
      }
    }
  }

  component WordToggle: Rectangle {
    id: wordToggle
    property string label: ""
    property bool checked: false
    signal toggled()

    activeFocusOnTab: true
    implicitWidth: toggleText.implicitWidth + Style.spacing.sm * 2
    implicitHeight: Style.space(28)
    radius: root.cornerRadius
    color: checked ? root.selectedBackground : Style.controlFill(activeFocus, toggleMouse.containsMouse, root.foreground, root.accentColor)
    border.width: activeFocus ? Style.normalBorderWidth : 1
    border.color: activeFocus ? root.accentColor : root.border

    Text {
      id: toggleText
      anchors.centerIn: parent
      text: wordToggle.label
      textFormat: Text.PlainText
      color: wordToggle.checked ? root.selectedText : root.foreground
      font.family: Style.font.menuFamily
      font.pixelSize: Style.font.caption
    }

    MouseArea {
      id: toggleMouse
      anchors.fill: parent
      hoverEnabled: true
      onClicked: {
        wordToggle.forceActiveFocus()
        wordToggle.toggled()
      }
    }

    Keys.onPressed: function(event) {
      if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
        wordToggle.toggled()
        event.accepted = true
      }
    }
  }

  Process {
    id: describeProcess
    stdout: StdioCollector { id: describeOutput; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0) {
        try {
          root.loadEditorRule(JSON.parse(String(describeOutput.text || "{}")))
        } catch (error) {
          root.cancelEditor()
          root.staging = { status: "error", error: "Could not load the selected rule" }
        }
      } else {
        root.cancelEditor()
        root.staging = { status: "error", error: "Could not load the selected rule" }
      }
    }
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
    running: (root.compiling || root.editorLoading) && root.opened
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
        root.editorMode ? panel.height - Style.gapsOut * 2
          : content.implicitHeight + card.contentTopInset + card.contentBottomInset,
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

      FocusScope {
        id: editor
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.topMargin: card.contentTopInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        anchors.rightMargin: card.contentRightInset
        z: 10
        visible: root.editorMode

        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape) {
            root.cancelEditor()
            event.accepted = true
          }
        }

        Row {
          id: editorHeader
          anchors.top: parent.top
          anchors.left: parent.left
          anchors.right: parent.right
          spacing: Style.spacing.sm

          Text {
            text: root.editorId === "" ? "New automation" : "Edit automation"
            textFormat: Text.PlainText
            color: root.foreground
            font.family: Style.font.menuFamily
            font.pixelSize: Style.font.body
            font.weight: Font.DemiBold
          }

          Text {
            text: "· build the chain, then review before installing"
            textFormat: Text.PlainText
            color: root.foreground
            opacity: 0.5
            font.family: Style.font.menuFamily
            font.pixelSize: Style.font.caption
          }
        }

        Flickable {
          id: editorScroll
          anchors.top: editorHeader.bottom
          anchors.bottom: editorFooter.top
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.topMargin: Style.spacing.md
          anchors.bottomMargin: Style.spacing.md
          contentHeight: editorChain.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          visible: !root.editorLoading

          Column {
            id: editorChain
            width: editorScroll.width
            spacing: Style.spacing.sm

            FocusScope {
              id: triggerNode
              width: parent.width
              height: triggerCard.height
              onActiveFocusChanged: root.revealEditorNode(triggerNode)

              BorderSurface {
                id: triggerCard
                width: parent.width
                height: triggerColumn.implicitHeight + contentTopInset + contentBottomInset
                radius: root.cornerRadius
                color: root.background
                borderSpec: Border.flat(triggerNode.activeFocus ? root.accentColor : root.border, triggerNode.activeFocus ? Style.normalBorderWidth : 1)
                padding: Style.spacing.md

                Column {
                  id: triggerColumn
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.top: parent.top
                  anchors.leftMargin: triggerCard.contentLeftInset
                  anchors.rightMargin: triggerCard.contentRightInset
                  anchors.topMargin: triggerCard.contentTopInset
                  spacing: Style.spacing.sm

                  Row {
                    width: parent.width
                    spacing: Style.spacing.sm

                    Text {
                      width: Style.space(70)
                      anchors.verticalCenter: parent.verticalCenter
                      text: "WHEN"
                      color: root.accentColor
                      font.family: Style.font.menuFamily
                      font.pixelSize: Style.font.caption
                      font.weight: Font.DemiBold
                    }

                    TypeSelector {
                      id: triggerSelector
                      width: parent.width - Style.space(70) - parent.spacing
                      value: String(root.editorTrigger.type || "manual")
                      onCycle: function(delta) {
                        root.editorTrigger = root.defaultTrigger(root.cycleValue(root.triggerTypes, value, delta))
                      }
                    }
                  }

                  Row {
                    width: parent.width
                    spacing: Style.spacing.sm
                    visible: root.editorTrigger.type === "time"

                    Text {
                      width: Style.space(70)
                      anchors.verticalCenter: parent.verticalCenter
                      text: "at"
                      color: root.foreground
                      opacity: 0.55
                      font.family: Style.font.menuFamily
                      font.pixelSize: Style.font.caption
                    }

                    EditorField {
                      width: parent.width - Style.space(70) - parent.spacing
                      text: String(root.editorTrigger.at || "")
                      placeholder: "HH:MM"
                      onTextChanged: {
                        if (root.editorTrigger.type !== "time") return
                        var trigger = root.clone(root.editorTrigger)
                        trigger.at = text
                        root.editorTrigger = trigger
                      }
                    }
                  }

                  Flow {
                    width: parent.width
                    spacing: Style.spacing.xs
                    visible: root.editorTrigger.type === "time"

                    Repeater {
                      model: root.weekdays

                      WordToggle {
                        required property string modelData
                        label: modelData
                        checked: (root.editorTrigger.days || []).indexOf(modelData) >= 0
                        onToggled: {
                          var trigger = root.clone(root.editorTrigger)
                          var days = (trigger.days || []).slice()
                          var dayIndex = days.indexOf(modelData)
                          if (dayIndex >= 0) days.splice(dayIndex, 1)
                          else days.push(modelData)
                          trigger.days = days
                          root.editorTrigger = trigger
                        }
                      }
                    }
                  }

                  Row {
                    width: parent.width
                    spacing: Style.spacing.sm
                    visible: root.editorTrigger.type === "interval"

                    Text {
                      width: Style.space(70)
                      anchors.verticalCenter: parent.verticalCenter
                      text: "minutes"
                      color: root.foreground
                      opacity: 0.55
                      font.family: Style.font.menuFamily
                      font.pixelSize: Style.font.caption
                    }

                    EditorField {
                      width: parent.width - Style.space(70) - parent.spacing
                      text: String(root.editorTrigger.minutes || "")
                      placeholder: "1–1440"
                      onTextChanged: {
                        if (root.editorTrigger.type !== "interval") return
                        var trigger = root.clone(root.editorTrigger)
                        trigger.minutes = text
                        root.editorTrigger = trigger
                      }
                    }
                  }

                  Row {
                    width: parent.width
                    spacing: Style.spacing.sm
                    visible: root.editorTrigger.type === "monitor-connected" || root.editorTrigger.type === "monitor-disconnected" || root.editorTrigger.type === "wifi-connected" || root.editorTrigger.type === "custom"

                    Text {
                      width: Style.space(70)
                      anchors.verticalCenter: parent.verticalCenter
                      text: root.editorTrigger.type === "custom" ? "name" : "match"
                      color: root.foreground
                      opacity: 0.55
                      font.family: Style.font.menuFamily
                      font.pixelSize: Style.font.caption
                    }

                    EditorField {
                      width: parent.width - Style.space(70) - parent.spacing
                      text: root.editorTrigger.type === "custom" ? String(root.editorTrigger.name || "")
                        : root.editorTrigger.type === "wifi-connected" && (root.editorTrigger.match || {}).known === false ? "unknown"
                        : root.editorTrigger.type === "wifi-connected" ? String((root.editorTrigger.match || {}).ssid || "")
                        : String((root.editorTrigger.match || {}).description || "")
                      placeholder: root.editorTrigger.type === "wifi-connected" ? "SSID, *, or unknown"
                        : root.editorTrigger.type === "custom" ? "event name"
                        : "name or description"
                      onTextChanged: {
                        if (root.editorTrigger.type !== "custom" && root.editorTrigger.type !== "wifi-connected"
                            && root.editorTrigger.type !== "monitor-connected" && root.editorTrigger.type !== "monitor-disconnected") return
                        var trigger = root.clone(root.editorTrigger)
                        if (trigger.type === "custom") trigger.name = text
                        else if (trigger.type === "wifi-connected") trigger.match = text === "unknown" ? { known: false } : { ssid: text }
                        else trigger.match = { description: text }
                        root.editorTrigger = trigger
                      }
                    }
                  }

                  Column {
                    width: parent.width
                    spacing: Style.spacing.sm
                    visible: root.editorTrigger.type === "app-opened" || root.editorTrigger.type === "app-closed"

                    Row {
                      width: parent.width
                      spacing: Style.spacing.sm

                      Text {
                        width: Style.space(70)
                        anchors.verticalCenter: parent.verticalCenter
                        text: "class"
                        color: root.foreground
                        opacity: 0.55
                        font.family: Style.font.menuFamily
                        font.pixelSize: Style.font.caption
                      }

                      EditorField {
                        width: parent.width - Style.space(70) - parent.spacing
                        text: String((root.editorTrigger.match || {}).class || "")
                        placeholder: "class match"
                        onTextChanged: {
                          if (root.editorTrigger.type !== "app-opened" && root.editorTrigger.type !== "app-closed") return
                          var trigger = root.clone(root.editorTrigger)
                          if (String((trigger.match || {}).class || "") === text) return
                          trigger.match = { class: text }
                          root.editorTrigger = trigger
                        }
                      }
                    }

                    Row {
                      width: parent.width
                      spacing: Style.spacing.sm

                      Text {
                        width: Style.space(70)
                        anchors.verticalCenter: parent.verticalCenter
                        text: "title"
                        color: root.foreground
                        opacity: 0.55
                        font.family: Style.font.menuFamily
                        font.pixelSize: Style.font.caption
                      }

                      EditorField {
                        width: parent.width - Style.space(70) - parent.spacing
                        text: String((root.editorTrigger.match || {}).title || "")
                        placeholder: "title match"
                        onTextChanged: {
                          if (root.editorTrigger.type !== "app-opened" && root.editorTrigger.type !== "app-closed") return
                          var trigger = root.clone(root.editorTrigger)
                          if (String((trigger.match || {}).title || "") === text) return
                          trigger.match = { title: text }
                          root.editorTrigger = trigger
                        }
                      }
                    }
                  }

                  Row {
                    width: parent.width
                    spacing: Style.spacing.sm
                    visible: root.editorTrigger.type === "power-source"

                    Text {
                      width: Style.space(70)
                      anchors.verticalCenter: parent.verticalCenter
                      text: "source"
                      color: root.foreground
                      opacity: 0.55
                      font.family: Style.font.menuFamily
                      font.pixelSize: Style.font.caption
                    }

                    ChoiceSelector {
                      width: parent.width - Style.space(70) - parent.spacing
                      first: "ac"
                      second: "battery"
                      value: String(root.editorTrigger.source || "ac")
                      onSelected: function(value) {
                        if (root.editorTrigger.type !== "power-source") return
                        var trigger = root.clone(root.editorTrigger)
                        trigger.source = value
                        root.editorTrigger = trigger
                      }
                    }
                  }
                }
              }
            }

            Text {
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              text: "↓"
              color: root.foreground
              opacity: 0.35
              font.family: Style.font.menuFamily
              font.pixelSize: Style.font.body
            }

            Repeater {
              model: editorConditions

              FocusScope {
                id: conditionNode
                required property int index
                required property var model
                property string selectedWords: String(model.selected || "")
                width: editorChain.width
                height: conditionCard.height + (conditionNode.index < editorConditions.count - 1 ? conditionArrow.implicitHeight + Style.spacing.sm : 0)
                onActiveFocusChanged: root.revealEditorNode(conditionNode)

                BorderSurface {
                  id: conditionCard
                  width: parent.width
                  height: conditionColumn.implicitHeight + contentTopInset + contentBottomInset
                  radius: root.cornerRadius
                  color: root.background
                  borderSpec: Border.flat(conditionNode.activeFocus ? root.accentColor : root.border, conditionNode.activeFocus ? Style.normalBorderWidth : 1)
                  padding: Style.spacing.md

                  Column {
                    id: conditionColumn
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.leftMargin: conditionCard.contentLeftInset
                    anchors.rightMargin: conditionCard.contentRightInset
                    anchors.topMargin: conditionCard.contentTopInset
                    spacing: Style.spacing.sm

                    Row {
                      width: parent.width
                      spacing: Style.spacing.sm

                      Text {
                        width: Style.space(70)
                        anchors.verticalCenter: parent.verticalCenter
                        text: "ONLY IF"
                        color: root.accentColor
                        font.family: Style.font.menuFamily
                        font.pixelSize: Style.font.caption
                        font.weight: Font.DemiBold
                      }

                      TypeSelector {
                        width: parent.width - Style.space(70) - removeCondition.width - parent.spacing * 2
                        value: String(model.type)
                        onCycle: function(delta) {
                          editorConditions.set(conditionNode.index, root.defaultCondition(root.cycleValue(root.conditionTypes, value, delta)))
                        }
                      }

                      EditorButton {
                        id: removeCondition
                        label: "×"
                        onClicked: editorConditions.remove(conditionNode.index)
                      }
                    }

                    Row {
                      width: parent.width
                      spacing: Style.spacing.sm
                      visible: model.type === "time-between"

                      EditorField {
                        width: (parent.width - parent.spacing) / 2
                        text: String(model.first || "")
                        placeholder: "from HH:MM"
                        onTextChanged: editorConditions.setProperty(conditionNode.index, "first", text)
                      }

                      EditorField {
                        width: (parent.width - parent.spacing) / 2
                        text: String(model.second || "")
                        placeholder: "to HH:MM"
                        onTextChanged: editorConditions.setProperty(conditionNode.index, "second", text)
                      }
                    }

                    Flow {
                      width: parent.width
                      spacing: Style.spacing.xs
                      visible: model.type === "weekday"

                      Repeater {
                        model: root.weekdays

                        WordToggle {
                          required property string modelData
                          label: modelData
                          checked: root.wordsContain(conditionNode.selectedWords, modelData)
                          onToggled: editorConditions.setProperty(conditionNode.index, "selected", root.toggleWord(conditionNode.selectedWords, modelData))
                        }
                      }
                    }

                    ChoiceSelector {
                      width: parent.width
                      visible: model.type === "on-power" || model.type === "lid-state"
                      first: model.type === "on-power" ? "ac" : "open"
                      second: model.type === "on-power" ? "battery" : "closed"
                      value: String(model.choice || first)
                      onSelected: function(value) { editorConditions.setProperty(conditionNode.index, "choice", value) }
                    }

                    EditorField {
                      width: parent.width
                      visible: model.type === "monitor-present" || model.type === "on-ssid"
                      text: String(model.first || "")
                      placeholder: model.type === "on-ssid" ? "SSID match" : "monitor name or description"
                      onTextChanged: editorConditions.setProperty(conditionNode.index, "first", text)
                    }

                    Column {
                      width: parent.width
                      spacing: Style.spacing.sm
                      visible: model.type === "app-running"

                      Row {
                        width: parent.width
                        spacing: Style.spacing.sm

                        Text {
                          width: Style.space(70)
                          anchors.verticalCenter: parent.verticalCenter
                          text: "class"
                          color: root.foreground
                          opacity: 0.55
                          font.family: Style.font.menuFamily
                          font.pixelSize: Style.font.caption
                        }

                        EditorField {
                          width: parent.width - Style.space(70) - parent.spacing
                          text: String(model.first || "")
                          placeholder: "class match"
                          onTextChanged: {
                            if (model.type !== "app-running" || String(model.first || "") === text) return
                            editorConditions.setProperty(conditionNode.index, "first", text)
                            if (String(text).trim() !== "") editorConditions.setProperty(conditionNode.index, "second", "")
                          }
                        }
                      }

                      Row {
                        width: parent.width
                        spacing: Style.spacing.sm

                        Text {
                          width: Style.space(70)
                          anchors.verticalCenter: parent.verticalCenter
                          text: "title"
                          color: root.foreground
                          opacity: 0.55
                          font.family: Style.font.menuFamily
                          font.pixelSize: Style.font.caption
                        }

                        EditorField {
                          width: parent.width - Style.space(70) - parent.spacing
                          text: String(model.second || "")
                          placeholder: "title match"
                          onTextChanged: {
                            if (model.type !== "app-running" || String(model.second || "") === text) return
                            editorConditions.setProperty(conditionNode.index, "second", text)
                            if (String(text).trim() !== "") editorConditions.setProperty(conditionNode.index, "first", "")
                          }
                        }
                      }
                    }
                  }
                }

                Text {
                  id: conditionArrow
                  anchors.top: conditionCard.bottom
                  anchors.topMargin: Style.spacing.sm
                  width: parent.width
                  visible: conditionNode.index < editorConditions.count - 1
                  horizontalAlignment: Text.AlignHCenter
                  text: "↓"
                  color: root.foreground
                  opacity: 0.35
                  font.family: Style.font.menuFamily
                  font.pixelSize: Style.font.body
                }
              }
            }

            EditorButton {
              anchors.horizontalCenter: parent.horizontalCenter
              label: editorConditions.count >= 5 ? "5 conditions maximum" : "+ Only if"
              enabled: editorConditions.count < 5
              opacity: enabled ? 1 : 0.4
              onClicked: if (enabled) editorConditions.append(root.defaultCondition("time-between"))
            }

            Text {
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              text: "↓"
              color: root.foreground
              opacity: 0.35
              font.family: Style.font.menuFamily
              font.pixelSize: Style.font.body
            }

            Repeater {
              model: editorActions

              Column {
                id: actionDelegate
                required property int index
                required property var model
                property string selectedWords: String(model.selected || "")
                width: editorChain.width
                spacing: Style.spacing.sm

                FocusScope {
                  id: actionNode
                  width: parent.width
                  height: actionCard.height
                  onActiveFocusChanged: root.revealEditorNode(actionNode)

                  BorderSurface {
                    id: actionCard
                    width: parent.width
                    height: actionColumn.implicitHeight + contentTopInset + contentBottomInset
                    radius: root.cornerRadius
                    color: root.background
                    borderSpec: Border.flat(actionNode.activeFocus ? root.accentColor : root.border, actionNode.activeFocus ? Style.normalBorderWidth : 1)
                    padding: Style.spacing.md

                    Column {
                      id: actionColumn
                      anchors.left: parent.left
                      anchors.right: parent.right
                      anchors.top: parent.top
                      anchors.leftMargin: actionCard.contentLeftInset
                      anchors.rightMargin: actionCard.contentRightInset
                      anchors.topMargin: actionCard.contentTopInset
                      spacing: Style.spacing.sm

                      Row {
                        width: parent.width
                        spacing: Style.spacing.sm

                        Text {
                          width: Style.space(70)
                          anchors.verticalCenter: parent.verticalCenter
                          text: "DO"
                          color: root.accentColor
                          font.family: Style.font.menuFamily
                          font.pixelSize: Style.font.caption
                          font.weight: Font.DemiBold
                        }

                        TypeSelector {
                          width: parent.width - Style.space(70) - moveUp.width - moveDown.width - removeAction.width - parent.spacing * 4
                          value: String(model.type)
                          onCycle: function(delta) {
                            editorActions.set(actionDelegate.index, root.defaultAction(root.cycleValue(root.actionTypes, value, delta)))
                          }
                        }

                        EditorButton {
                          id: moveUp
                          label: "↑"
                          enabled: actionDelegate.index > 0
                          opacity: enabled ? 1 : 0.3
                          onClicked: if (enabled) editorActions.move(actionDelegate.index, actionDelegate.index - 1, 1)
                        }

                        EditorButton {
                          id: moveDown
                          label: "↓"
                          enabled: actionDelegate.index < editorActions.count - 1
                          opacity: enabled ? 1 : 0.3
                          onClicked: if (enabled) editorActions.move(actionDelegate.index, actionDelegate.index + 1, 1)
                        }

                        EditorButton {
                          id: removeAction
                          label: "×"
                          enabled: editorActions.count > 1
                          opacity: enabled ? 1 : 0.3
                          onClicked: if (enabled) editorActions.remove(actionDelegate.index)
                        }
                      }

                      EditorField {
                        width: parent.width
                        visible: model.type === "theme" || model.type === "audio-output" || model.type === "script"
                        text: String(model.first || "")
                        placeholder: model.type === "theme" ? "theme name" : model.type === "script" ? "allowed script name" : "sink match"
                        onTextChanged: editorActions.setProperty(actionDelegate.index, "first", text)
                      }

                      ChoiceSelector {
                        width: parent.width
                        visible: model.type === "dnd" || model.type === "nightlight" || model.type === "stay-awake"
                        first: "on"
                        second: "off"
                        value: String(model.choice || "on")
                        onSelected: function(value) { editorActions.setProperty(actionDelegate.index, "choice", value) }
                      }

                      Row {
                        width: parent.width
                        spacing: Style.spacing.sm
                        visible: model.type === "launch"

                        EditorField {
                          width: parent.width * 0.7 - parent.spacing
                          text: String(model.first || "")
                          placeholder: "app"
                          onTextChanged: editorActions.setProperty(actionDelegate.index, "first", text)
                        }

                        EditorField {
                          width: parent.width * 0.3
                          text: String(model.number || "")
                          placeholder: "workspace (optional)"
                          onTextChanged: editorActions.setProperty(actionDelegate.index, "number", text)
                        }
                      }

                      EditorField {
                        width: parent.width
                        visible: model.type === "workspace"
                        text: String(model.number || "")
                        placeholder: "workspace 1–10"
                        onTextChanged: editorActions.setProperty(actionDelegate.index, "number", text)
                      }

                      Row {
                        width: parent.width
                        spacing: Style.spacing.sm
                        visible: model.type === "webhook"

                        EditorField {
                          width: parent.width * 0.35 - parent.spacing
                          text: String(model.first || "")
                          placeholder: "endpoint"
                          onTextChanged: editorActions.setProperty(actionDelegate.index, "first", text)
                        }

                        EditorField {
                          width: parent.width * 0.65
                          text: String(model.second || "")
                          placeholder: "message"
                          onTextChanged: editorActions.setProperty(actionDelegate.index, "second", text)
                        }
                      }

                      Column {
                        width: parent.width
                        spacing: Style.spacing.sm
                        visible: model.type === "notify"

                        EditorField {
                          width: parent.width
                          text: String(model.first || "")
                          placeholder: "title (optional)"
                          onTextChanged: editorActions.setProperty(actionDelegate.index, "first", text)
                        }

                        EditorField {
                          width: parent.width
                          text: String(model.second || "")
                          placeholder: "message"
                          multiline: true
                          preferredHeight: Style.space(48)
                          onTextChanged: editorActions.setProperty(actionDelegate.index, "second", text)
                        }
                      }

                      Column {
                        width: parent.width
                        spacing: Style.spacing.sm
                        visible: model.type === "agent"

                        EditorField {
                          width: parent.width
                          text: String(model.first || "")
                          placeholder: "agent task"
                          multiline: true
                          preferredHeight: Style.space(48)
                          onTextChanged: editorActions.setProperty(actionDelegate.index, "first", text)
                        }

                        Flow {
                          width: parent.width
                          spacing: Style.spacing.xs

                          Repeater {
                            model: root.agentOps

                            WordToggle {
                              required property string modelData
                              label: modelData
                              checked: root.wordsContain(actionDelegate.selectedWords, modelData)
                              onToggled: editorActions.setProperty(actionDelegate.index, "selected", root.toggleWord(actionDelegate.selectedWords, modelData))
                            }
                          }
                        }

                        EditorField {
                          width: parent.width
                          text: String(model.number || "")
                          placeholder: "timeoutSeconds (optional)"
                          onTextChanged: editorActions.setProperty(actionDelegate.index, "number", text)
                        }
                      }
                    }
                  }
                }

                Text {
                  width: parent.width
                  horizontalAlignment: Text.AlignHCenter
                  visible: actionDelegate.index < editorActions.count - 1
                  text: "↓"
                  color: root.foreground
                  opacity: 0.35
                  font.family: Style.font.menuFamily
                  font.pixelSize: Style.font.body
                }
              }
            }

            EditorButton {
              anchors.horizontalCenter: parent.horizontalCenter
              label: editorActions.count >= 10 ? "10 actions maximum" : "+ Do"
              enabled: editorActions.count < 10
              opacity: enabled ? 1 : 0.4
              onClicked: if (enabled) editorActions.append(root.defaultAction("notify"))
            }
          }
        }

        Row {
          id: editorFooter
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          spacing: Style.spacing.sm
          visible: !root.editorLoading

          EditorField {
            id: editorName
            width: parent.width - editorCooldown.width - saveEditorButton.width - cancelEditorButton.width - parent.spacing * 3
            placeholder: "rule name"
          }

          EditorField {
            id: editorCooldown
            width: Style.space(105)
            placeholder: "cooldown s"
          }

          EditorButton {
            id: saveEditorButton
            label: "Save"
            strong: true
            onClicked: root.saveEditor()
          }

          EditorButton {
            id: cancelEditorButton
            label: "Cancel"
            onClicked: root.cancelEditor()
          }
        }

        Text {
          anchors.centerIn: parent
          visible: root.editorLoading
          text: root.spinnerFrames[root.spinnerFrame] + "  loading rule…"
          color: root.accentColor
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.body
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

          MouseArea {
            anchors.fill: parent
            onClicked: {
              root.cli(["stage", "reject"])
              root.staging = null
            }
          }
        }

        BorderSurface {
          id: previewCard
          width: Math.min(Style.space(560), parent.width - Style.space(24))
          height: Math.min(
            previewColumn.implicitHeight + previewFooter.implicitHeight + Style.spacing.sm
              + previewCard.contentTopInset + previewCard.contentBottomInset,
            parent.height - Style.space(24)
          )
          anchors.centerIn: parent
          color: root.background
          borderSpec: Border.flat(root.selectedText, Style.normalBorderWidth)
          radius: root.cornerRadius
          padding: Style.spacing.md

          MouseArea { anchors.fill: parent; onClicked: {} }

          // Scrollable body: title, request, the full action list, warnings.
          // Kept above a pinned footer so the Install/Discard controls — and
          // the disclosure of every action, including webhook destinations —
          // can never be clipped below the card on a small screen.
          Flickable {
            id: previewScroll
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: previewFooter.top
            anchors.topMargin: previewCard.contentTopInset
            anchors.leftMargin: previewCard.contentLeftInset
            anchors.rightMargin: previewCard.contentRightInset
            anchors.bottomMargin: Style.spacing.sm
            clip: true
            contentHeight: previewColumn.implicitHeight
            boundsBehavior: Flickable.StopAtBounds

            Column {
              id: previewColumn
              width: previewScroll.width
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
            }
          }

          Text {
            id: previewFooter
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.leftMargin: previewCard.contentLeftInset
            anchors.rightMargin: previewCard.contentRightInset
            anchors.bottomMargin: previewCard.contentBottomInset
            text: (previewScroll.contentHeight > previewScroll.height ? "↕ scroll    " : "") + "↵ Install rule    Esc Discard"
            textFormat: Text.PlainText
            color: root.foreground
            opacity: 0.45
            font.family: Style.font.menuFamily
            font.pixelSize: Style.font.caption
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
        visible: !root.editorMode

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
                  root.staging = null // optimistic: block repeated accepts until the file updates
                  event.accepted = true
                } else if (event.key === Qt.Key_Escape) {
                  root.cli(["stage", "reject"])
                  root.staging = null
                  event.accepted = true
                }
                return
              }
              if (event.key === Qt.Key_N && (event.modifiers & Qt.ControlModifier) !== 0) {
                root.startNewEditor()
                event.accepted = true
                return
              }
              if (event.key === Qt.Key_E && event.modifiers === Qt.NoModifier && promptInput.text.length === 0) {
                root.startEditCurrent()
                event.accepted = true
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
            required property int index
            required property var model
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
              anchors.rightMargin: Style.space(64)
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

            EditorButton {
              anchors.right: parent.right
              anchors.rightMargin: Style.spacing.sm
              anchors.verticalCenter: parent.verticalCenter
              z: 2
              label: "edit"
              tabFocus: false
              onClicked: {
                rulesList.currentIndex = index
                root.startEditCurrent()
              }
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
          text: "↵ Compile    Ctrl+N New    e Edit    Alt+↵ Run    Ctrl+↵ Dry-run    Ctrl+E Toggle    Alt+Del Delete"
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
