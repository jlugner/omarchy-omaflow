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
  property var editorUntilTrigger: null
  property bool editorUntilRevert: false

  readonly property var triggerTypes: ["manual", "time", "interval", "lid-opened", "lid-closed", "monitor-connected", "monitor-disconnected", "app-opened", "app-closed", "wifi-connected", "wifi-disconnected", "power-source", "file-created", "folder-created", "git-branch-changed", "custom"]
  readonly property var conditionTypes: ["time-between", "weekday", "on-power", "lid-state", "monitor-present", "app-running", "on-branch", "hey-events", "on-ssid"]
  readonly property var actionTypes: ["theme", "dnd", "nightlight", "stay-awake", "launch", "workspace", "audio-output", "script", "webhook", "hey-timetrack", "hey-agenda", "notify", "agent"]
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
  property var themePalette: ({})

  function loadPalette(raw) {
    var palette = {}
    var lines = String(raw || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var match = lines[i].match(/^\s*([A-Za-z0-9_]+)\s*=\s*["']?(#[0-9A-Fa-f]{6})/)
      if (match) palette[match[1]] = match[2]
    }
    root.themePalette = palette
  }

  function themeHue(names, fallback) {
    for (var i = 0; i < names.length; i++)
      if (root.themePalette[names[i]]) return root.themePalette[names[i]]
    return fallback
  }

  readonly property color flowTrigger: themeHue(["blue", "bright_blue", "color4"], accentColor)
  readonly property color flowCondition: themeHue(["yellow", "bright_yellow", "color3"], accentColor)
  readonly property color flowAction: themeHue(["magenta", "bright_magenta", "color5"], accentColor)
  readonly property color flowLine: themeHue(["green", "bright_green", "color2"], accentColor)
  readonly property color flowUntil: themeHue(["orange", "bright_red", "red", "color1"], accentColor)
  readonly property var untilTypes: triggerTypes.filter(function(t) { return t !== "manual" })

  readonly property color editorHairline: Qt.alpha(foreground, 0.16)
  readonly property color editorInkMuted: Qt.alpha(foreground, 0.55)
  readonly property color editorLine: Qt.alpha(foreground, 0.3)
  readonly property var triggerCaptions: ({ "manual": "runs only when you run it", "time": "at a time of day", "interval": "on a repeating timer", "lid-opened": "when the laptop lid opens", "lid-closed": "when the laptop lid closes", "monitor-connected": "when a monitor is plugged in", "monitor-disconnected": "when a monitor is removed", "app-opened": "when a matching window appears", "app-closed": "when a matching window closes", "wifi-connected": "when wifi connects", "wifi-disconnected": "when wifi drops", "power-source": "when the power source changes", "file-created": "when a file lands in a watched folder", "folder-created": "when a folder appears in a watched folder", "git-branch-changed": "when a repo switches branch", "custom": "when you fire this named event" })
  readonly property var conditionCaptions: ({ "time-between": "only inside a time window", "weekday": "only on chosen weekdays", "on-power": "only on AC or battery", "lid-state": "only with the lid open or closed", "monitor-present": "only if a monitor is present", "app-running": "only if a matching window exists", "on-branch": "only while a repo is on a branch", "hey-events": "only with enough events today", "on-ssid": "only on a given wifi" })
  readonly property var actionCaptions: ({ "theme": "switch the desktop theme", "dnd": "toggle do-not-disturb", "nightlight": "toggle the night filter", "stay-awake": "keep the machine awake", "launch": "open an app", "workspace": "jump to a workspace", "audio-output": "route sound to a sink", "script": "run one allowed script", "webhook": "post to a named endpoint", "hey-timetrack": "track time in HEY, filed per category", "hey-agenda": "show today\u2019s HEY calendar", "notify": "show a notification", "agent": "ask the agent to act, inside limits" })
  readonly property var triggerProvides: ({
    "time": ["at"],
    "monitor-connected": ["name", "description"],
    "monitor-disconnected": ["name", "description"],
    "app-opened": ["class", "title"],
    "app-closed": ["class", "title"],
    "wifi-connected": ["ssid"],
    "power-source": ["source"],
    "file-created": ["name", "path"],
    "folder-created": ["name", "path"],
    "git-branch-changed": ["branch", "from", "repo"],
    "custom": ["name", "at", "your key=value pairs"]
  })

  function prettyType(value) { return String(value).split("-").join(" ") }

  function describeTrigger(trigger) {
    var t = trigger || {}
    var type = String(t.type || "manual")
    if (type === "manual") return "fires only when you run it — Alt+Return here, or the menu"
    if (type === "time") return "fires at " + (t.at || "…") + ((t.days || []).length > 0 && (t.days || []).length < 7 ? " on " + t.days.join(", ") : " every day")
    if (type === "interval") return "fires every " + (t.minutes || "…") + " minutes"
    if (type === "lid-opened") return "fires when the laptop lid opens"
    if (type === "lid-closed") return "fires when the laptop lid closes"
    if (type === "monitor-connected" || type === "monitor-disconnected") {
      var mon = (t.match || {}).description || (t.match || {}).name || ""
      return "fires when a monitor matching \u201c" + (mon || "…") + "\u201d is " + (type === "monitor-connected" ? "plugged in" : "removed")
    }
    if (type === "app-opened" || type === "app-closed") {
      var app = (t.match || {}).class || (t.match || {}).title || ""
      return "fires when a window matching \u201c" + (app || "…") + "\u201d " + (type === "app-opened" ? "appears" : "closes")
    }
    if (type === "wifi-connected") {
      var m = t.match || {}
      if (m.known === false) return "fires when connecting to a network never seen before"
      if (m.ssid === "*") return "fires when any wifi connects"
      return "fires when wifi \u201c" + (m.ssid || "…") + "\u201d connects"
    }
    if (type === "wifi-disconnected") return "fires when wifi drops"
    if (type === "power-source") return "fires when the machine switches to " + (t.source || "ac")
    if (type === "file-created" || type === "folder-created") {
      var what = type === "file-created" ? "a file" : "a folder"
      var name = (t.match || {}).name
      return "fires when " + what + (name ? " whose name contains \u201c" + name + "\u201d" : "") + " lands in " + (t.path || "…")
    }
    if (type === "git-branch-changed") {
      var gb = (t.match || {}).branch
      return "fires when " + (t.repo || "…") + " switches branch" + (gb ? " to one containing \u201c" + gb + "\u201d" : "")
    }
    if (type === "custom") return "fires when you run: omaflow trigger " + (t.name || "<name>")
    return root.triggerCaptions[type] || ""
  }

  function describeCondition(type, first, second, choice, selected) {
    type = String(type)
    if (type === "time-between") return "passes only between " + (first || "…") + " and " + (second || "…")
    if (type === "weekday") return "passes only on " + (String(selected || "").split(",").filter(function(v) { return v !== "" }).join(", ") || "…")
    if (type === "on-power") return "passes only on " + (choice === "battery" ? "battery power" : "AC power")
    if (type === "lid-state") return "passes only while the lid is " + (choice || "open")
    if (type === "monitor-present") return "passes only while a monitor matching \u201c" + (first || "…") + "\u201d is connected"
    if (type === "app-running") return "passes only while a window matching \u201c" + (first || second || "…") + "\u201d exists"
    if (type === "on-branch") return "passes only while " + (first || "…") + " is on a branch containing \u201c" + (second || "…") + "\u201d"
    if (type === "hey-events") return "passes only when your HEY calendar has at least " + (first || "…") + " event" + (String(first) === "1" ? "" : "s") + " today"
    if (type === "on-ssid") return "passes only while wifi contains \u201c" + (first || "…") + "\u201d"
    return root.conditionCaptions[type] || ""
  }

  function describeAction(type, first, second, choice, number, selected) {
    type = String(type)
    if (type === "theme") return "switches the desktop theme to \u201c" + (first || "…") + "\u201d"
    if (type === "dnd") return (choice === "off" ? "turns do-not-disturb off" : "silences notifications (do-not-disturb on)")
    if (type === "nightlight") return "turns the night filter " + (choice || "on")
    if (type === "stay-awake") return (choice === "off" ? "lets the machine sleep normally again" : "keeps the machine awake")
    if (type === "launch") return "opens " + (first || "…") + (String(number || "").trim() !== "" ? " on workspace " + number : "")
    if (type === "workspace") return "jumps to workspace " + (number || "…")
    if (type === "audio-output") return "routes sound to the sink matching \u201c" + (first || "…") + "\u201d"
    if (type === "script") return "runs the allowed script \u201c" + (first || "…") + "\u201d"
    if (type === "webhook") return "posts \u201c" + (second || "…") + "\u201d to the \u201c" + (first || "…") + "\u201d endpoint"
    if (type === "notify") return "shows a notification: \u201c" + (second || first || "…") + "\u201d"
    if (type === "agent") return "asks your agent to: " + (first || "…") + " — allowed: " + (String(selected || "").split(",").filter(function(v) { return v !== "" }).join(", ") || "nothing yet")
    if (type === "hey-agenda") return "notifies today\u2019s HEY events as a list" + (choice === "always" ? ", even when empty" : "; stays silent when there are none")
    if (type === "hey-timetrack") {
      var filing = String(second || "").trim() !== "" ? "file under the branch " + second + " is on right then"
        : String(first || "").trim() !== "" ? "file under \u201c" + first + "\u201d"
        : "stay unfiled"
      if (choice === "start") return "starts HEY time tracking (does nothing if already tracking); the track will " + filing + " once stopped"
      if (choice === "stop") return "stops the running HEY track and files it (under what it was started for, else " + (String(first || second || "").trim() !== "" ? filing.replace("file ", "") : "unfiled") + ")"
      return "stops the running HEY track, files it, then starts a fresh one that will " + filing
    }
    return root.actionCaptions[type] || ""
  }
  property var pickerTarget: null
  property string pickerQuery: ""
  property int pickerIndex: 0
  readonly property var pickerFiltered: {
    if (pickerTarget === null) return []
    var types = pickerTarget.kind === "trigger" ? triggerTypes : pickerTarget.kind === "until" ? untilTypes : pickerTarget.kind === "condition" ? conditionTypes : actionTypes
    var captions = pickerTarget.kind === "trigger" || pickerTarget.kind === "until" ? triggerCaptions : pickerTarget.kind === "condition" ? conditionCaptions : actionCaptions
    var query = pickerQuery.toLowerCase()
    var options = []
    for (var i = 0; i < types.length; i++) {
      var caption = captions[types[i]] || ""
      if (query === "" || types[i].indexOf(query) >= 0 || prettyType(types[i]).indexOf(query) >= 0 || caption.toLowerCase().indexOf(query) >= 0)
        options.push({ type: types[i], caption: caption })
    }
    return options
  }

  property var pickerReturn: null
  readonly property color pickerTint: pickerTarget === null ? accentColor
    : pickerTarget.kind === "trigger" ? flowTrigger
    : pickerTarget.kind === "until" ? flowUntil
    : pickerTarget.kind === "condition" ? flowCondition
    : flowAction

  function openTypePicker(kind, index, origin) {
    root.pickerQuery = ""
    root.pickerIndex = 0
    root.pickerReturn = origin || null
    root.pickerTarget = { kind: kind, index: index }
    Qt.callLater(function() { pickerInput.text = ""; pickerInput.forceActiveFocus() })
  }

  function closePicker() {
    root.pickerTarget = null
    if (root.pickerReturn) root.pickerReturn.forceActiveFocus()
    else editor.forceActiveFocus()
    root.pickerReturn = null
  }

  function applyPicker() {
    if (root.pickerTarget === null || root.pickerFiltered.length === 0) return
    var choice = root.pickerFiltered[Math.max(0, Math.min(root.pickerIndex, root.pickerFiltered.length - 1))].type
    if (root.pickerTarget.kind === "trigger") root.editorTrigger = root.defaultTrigger(choice)
    else if (root.pickerTarget.kind === "until") root.editorUntilTrigger = root.defaultTrigger(choice)
    else if (root.pickerTarget.kind === "until-action") editorUntilActions.set(root.pickerTarget.index, root.defaultAction(choice))
    else if (root.pickerTarget.kind === "condition") editorConditions.set(root.pickerTarget.index, root.defaultCondition(choice))
    else editorActions.set(root.pickerTarget.index, root.defaultAction(choice))
    root.closePicker()
  }
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
  ListModel { id: editorUntilActions; dynamicRoles: true }

  function open(payloadJson) {
    root.confirmDeleteId = ""
    root.editorMode = false
    promptInput.text = ""
    indexFile.reload()
    logFile.reload()
    stagingFile.reload()
    root.opened = true
    var payload = {}
    try { payload = JSON.parse(payloadJson || "{}") } catch (error) { payload = {} }
    if (payload && payload.editor === true) Qt.callLater(function() { root.startNewEditor() })
    else Qt.callLater(function() { promptInput.forceActiveFocus() })
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
    if (type === "file-created" || type === "folder-created") return { type: type, path: "~/Downloads" }
    if (type === "git-branch-changed") return { type: type, repo: "~/" }
    if (type === "custom") return { type: type, name: "" }
    return { type: type }
  }

  function defaultCondition(type) {
    var condition = { type: type, first: "", second: "", choice: "", selected: "" }
    if (type === "time-between") { condition.first = "09:00"; condition.second = "17:00" }
    else if (type === "weekday") condition.selected = root.weekdays.join(",")
    else if (type === "on-power") condition.choice = "ac"
    else if (type === "lid-state") condition.choice = "open"
    else if (type === "on-branch") condition.first = "~/"
    else if (type === "hey-events") condition.first = "1"
    return condition
  }

  function defaultAction(type) {
    var action = { type: type, first: "", second: "", choice: "on", number: "", selected: "" }
    if (type === "hey-timetrack") action.choice = "switch"
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
    editorUntilActions.clear()
    root.editorUntilTrigger = null
    root.editorUntilRevert = false
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

  function loadActionsInto(store, actions) {
    store.clear()
    for (var a = 0; a < actions.length; a++) {
      var action = root.defaultAction(String(actions[a].type || "notify"))
      if (action.type === "theme" || action.type === "script") action.first = String(actions[a].name || "")
      else if (action.type === "dnd" || action.type === "nightlight" || action.type === "stay-awake") action.choice = String(actions[a].state || "on")
      else if (action.type === "launch") { action.first = String(actions[a].app || ""); action.number = actions[a].workspace === undefined ? "" : String(actions[a].workspace) }
      else if (action.type === "workspace") action.number = String(actions[a].number || "")
      else if (action.type === "hey-timetrack") {
        action.choice = String(actions[a].mode || "switch")
        action.first = String(actions[a].category || "")
        action.second = String(actions[a].categoryFromRepo || "")
      }
      else if (action.type === "hey-agenda") {
        action.first = String(actions[a].title || "")
        action.choice = actions[a].skipWhenEmpty === false ? "always" : "skip empty"
      }
      else if (action.type === "audio-output") action.first = String(actions[a].match || "")
      else if (action.type === "webhook") { action.first = String(actions[a].endpoint || ""); action.second = String(actions[a].message || "") }
      else if (action.type === "notify") { action.first = String(actions[a].title || ""); action.second = String(actions[a].message || "") }
      else if (action.type === "agent") {
        action.first = String(actions[a].task || "")
        action.selected = (actions[a].can || []).join(",")
        action.number = actions[a].timeoutSeconds === undefined ? "" : String(actions[a].timeoutSeconds)
      }
      store.append(action)
    }
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
      else if (condition.type === "on-branch") {
        condition.first = String(conditions[i].repo || "")
        condition.second = String(conditions[i].branch || "")
      }
      else if (condition.type === "hey-events") condition.first = String(conditions[i].atLeast || "1")
      else if (condition.type === "on-ssid") condition.first = String(conditions[i].ssid || "")
      editorConditions.append(condition)
    }
    root.loadActionsInto(editorActions, rule.actions || [])
    editorUntilActions.clear()
    root.editorUntilTrigger = null
    root.editorUntilRevert = false
    if (rule.until && rule.until.trigger) {
      root.editorUntilTrigger = root.clone(rule.until.trigger)
      root.editorUntilRevert = rule.until.revert === true
      root.loadActionsInto(editorUntilActions, rule.until.actions || [])
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
    if (condition.type === "on-branch") return { type: condition.type, repo: condition.first, branch: condition.second }
    if (condition.type === "hey-events") return { type: condition.type, atLeast: root.integerOrText(condition.first) }
    return { type: condition.type, ssid: condition.first }
  }

  function actionRule(action) {
    if (action.type === "theme" || action.type === "script") return { type: action.type, name: action.first }
    if (action.type === "hey-timetrack") {
      var track = { type: action.type, mode: action.choice }
      if (String(action.second || "").trim() !== "") track.categoryFromRepo = action.second
      else if (String(action.first || "").trim() !== "") track.category = action.first
      return track
    }
    if (action.type === "hey-agenda") {
      var agenda = { type: action.type, skipWhenEmpty: action.choice !== "always" }
      if (String(action.first || "").trim() !== "") agenda.title = action.first
      return agenda
    }
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
    if (root.editorUntilTrigger !== null && (editorUntilActions.count > 0 || root.editorUntilRevert)) {
      var untilTrigger = root.clone(root.editorUntilTrigger)
      if (untilTrigger.type === "interval") untilTrigger.minutes = root.integerOrText(untilTrigger.minutes)
      var untilBlock = { trigger: untilTrigger }
      if (root.editorUntilRevert) untilBlock.revert = true
      if (editorUntilActions.count > 0) {
        var untilActions = []
        for (var u = 0; u < editorUntilActions.count; u++) untilActions.push(root.actionRule(editorUntilActions.get(u)))
        untilBlock.actions = untilActions
      }
      rule.until = untilBlock
    }
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
    if (t.path) when += ": " + t.path
    if (t.repo) when += ": " + t.repo
    if (t.source) when += ": " + t.source
    lines.push("When   " + when)
    var conds = rule.conditions || []
    for (var c = 0; c < conds.length; c++) {
      var cond = conds[c]
      var text = String(cond.type || "?")
      if (cond.from) text += " " + cond.from + "–" + cond.to
      if (cond.days) text += " " + cond.days.join(", ")
      if (cond.source) text += " " + cond.source
      if (cond.repo) text += " " + cond.repo + (cond.branch ? " on " + cond.branch : "")
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
      if (action.mode) atext += " → " + action.mode
      if (action.category) atext += " (file under: " + action.category + ")"
      if (action.categoryFromRepo) atext += " (file under current branch of " + action.categoryFromRepo + ")"
      if (action.skipWhenEmpty === false) atext += " (notify even when empty)"
      if (action.atLeast) atext += " ≥ " + action.atLeast
      if (action.task) atext += " → " + action.task
      if (action.can) atext += " [can: " + action.can.join(", ") + "]"
      lines.push((a === 0 ? "Do     " : "       ") + atext)
    }
    if (rule.until && rule.until.trigger) {
      var ut = rule.until.trigger
      var uwhen = String(ut.type || "?")
      if (ut.match) uwhen += ": " + (ut.match.description || ut.match.name || ut.match.class || ut.match.title || ut.match.ssid || ut.match.branch || "")
      if (ut.minutes) uwhen += " after " + ut.minutes + " min"
      if (ut.path) uwhen += ": " + ut.path
      if (ut.repo) uwhen += ": " + ut.repo
      if (ut.name) uwhen += ": " + ut.name
      lines.push("Until  " + uwhen)
      if (rule.until.revert === true) lines.push("  then restore what this rule changed")
      var uacts = rule.until.actions || []
      for (var ua = 0; ua < uacts.length; ua++) {
        var uaction = uacts[ua]
        var uatext = String(uaction.type || "?")
        if (uaction.name) uatext += " → " + uaction.name
        if (uaction.mode) uatext += " → " + uaction.mode
        if (uaction.category) uatext += " (file under: " + uaction.category + ")"
        if (uaction.categoryFromRepo) uatext += " (file under current branch of " + uaction.categoryFromRepo + ")"
        if (uaction.endpoint) uatext += " → " + uaction.endpoint
        if (uaction.message) uatext += " \"" + uaction.message + "\""
        lines.push("  then " + uatext)
      }
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
    property bool ghost: false
    property bool accented: false
    property color tintColor: root.accentColor
    property bool tabFocus: true
    signal clicked()

    activeFocusOnTab: tabFocus
    implicitWidth: buttonLabel.implicitWidth + Style.spacing.md * 2
    implicitHeight: Math.max(Style.space(30), buttonLabel.implicitHeight + Style.spacing.sm)
    radius: height / 2
    color: strong ? root.accentColor
      : ghost && accented ? (activeFocus || buttonMouse.containsMouse ? Qt.alpha(tintColor, 0.12) : "transparent")
      : ghost ? (activeFocus || buttonMouse.containsMouse ? Qt.alpha(root.foreground, 0.08) : "transparent")
      : Style.controlFill(activeFocus, buttonMouse.containsMouse, root.foreground, root.accentColor)
    border.width: strong ? 0 : 1
    border.color: activeFocus ? Qt.alpha(root.accentColor, 0.9)
      : ghost && accented ? Qt.alpha(tintColor, 0.4)
      : ghost ? (buttonMouse.containsMouse ? root.editorHairline : "transparent")
      : root.editorHairline

    Text {
      id: buttonLabel
      anchors.centerIn: parent
      text: editorButton.label
      textFormat: Text.PlainText
      color: editorButton.strong ? (root.accentColor.hslLightness > 0.55 ? Qt.rgba(0, 0, 0, 0.85) : "#ffffff")
        : editorButton.accented ? Qt.alpha(editorButton.tintColor, editorButton.activeFocus || buttonMouse.containsMouse ? 1 : 0.9)
        : editorButton.ghost && !(editorButton.activeFocus || buttonMouse.containsMouse) ? root.editorInkMuted
        : root.foreground
      font.family: Style.font.menuFamily
      font.pixelSize: Style.font.caption
      font.weight: editorButton.strong ? Font.DemiBold : Font.Normal
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
    property int preferredHeight: Style.space(32)

    implicitHeight: Math.max(preferredHeight, Math.ceil(fieldInput.contentHeight) + Style.spacing.sm * 2)
    radius: Style.space(6)
    color: fieldInput.activeFocus ? Qt.alpha(root.foreground, 0.07) : Qt.alpha(root.foreground, 0.045)
    border.width: 1
    border.color: fieldInput.activeFocus ? Qt.alpha(root.accentColor, 0.9)
      : fieldMouse.containsMouse ? Qt.alpha(root.foreground, 0.28)
      : root.editorHairline

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

  component FieldLabel: Text {
    width: Style.space(76)
    anchors.verticalCenter: parent.verticalCenter
    textFormat: Text.PlainText
    color: root.editorInkMuted
    font.family: Style.font.menuFamily
    font.pixelSize: Math.round(Style.font.caption * 0.9)
    font.capitalization: Font.AllUppercase
    font.letterSpacing: 0.8
  }

  component NodeBadge: Rectangle {
    id: nodeBadge
    property string label: ""
    property color tint: root.accentColor
    property bool filled: true

    implicitWidth: badgeText.implicitWidth + Style.space(20)
    implicitHeight: Style.space(22)
    radius: height / 2
    color: filled ? Qt.alpha(tint, 0.16) : "transparent"
    border.width: filled ? 0 : 1
    border.color: Qt.alpha(tint, 0.55)

    Text {
      id: badgeText
      anchors.centerIn: parent
      anchors.horizontalCenterOffset: 1
      text: nodeBadge.label
      textFormat: Text.PlainText
      color: nodeBadge.tint
      font.family: Style.font.menuFamily
      font.pixelSize: Math.round(Style.font.caption * 0.85)
      font.weight: Font.Bold
      font.letterSpacing: 1.4
    }
  }

  component NodeCard: Rectangle {
    id: nodeCard
    property bool focusedNode: false
    property color rail: root.accentColor
    default property alias content: cardInner.data

    width: parent.width
    height: cardInner.implicitHeight + Style.spacing.md * 2
    radius: root.cornerRadius
    color: focusedNode ? Qt.alpha(rail, 0.1) : Qt.alpha(rail, 0.05)
    border.width: 1
    border.color: focusedNode ? Qt.alpha(rail, 0.85) : root.editorHairline

    Rectangle {
      anchors.left: parent.left
      anchors.leftMargin: Style.space(10)
      anchors.top: parent.top
      anchors.bottom: parent.bottom
      anchors.topMargin: Style.spacing.md
      anchors.bottomMargin: Style.spacing.md
      width: Style.space(3)
      radius: width / 2
      color: nodeCard.focusedNode ? nodeCard.rail : Qt.alpha(nodeCard.rail, 0.45)
    }

    Column {
      id: cardInner
      anchors.top: parent.top
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.topMargin: Style.spacing.md
      anchors.leftMargin: Style.space(26)
      anchors.rightMargin: Style.space(18)
      spacing: Style.spacing.sm
    }
  }

  component Connector: Item {
    id: connectorItem
    property bool arrow: false
    property string label: ""
    property color tint: root.flowLine

    width: parent.width
    implicitHeight: Style.space(label !== "" ? 32 : arrow ? 26 : 20)

    Rectangle {
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.top: parent.top
      anchors.bottom: parent.bottom
      anchors.bottomMargin: connectorItem.arrow ? Style.space(7) : 0
      width: 1
      color: Qt.alpha(root.flowLine, 0.55)
    }

    Text {
      visible: connectorItem.arrow
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.bottom: parent.bottom
      anchors.bottomMargin: -Style.space(2)
      text: "▾"
      textFormat: Text.PlainText
      color: Qt.alpha(root.flowLine, 0.9)
      font.family: Style.font.menuFamily
      font.pixelSize: Math.round(Style.font.caption * 0.9)
    }

    Rectangle {
      visible: connectorItem.label !== ""
      anchors.centerIn: parent
      width: connectorLabel.implicitWidth + Style.space(16)
      height: Style.space(18)
      radius: height / 2
      color: root.background
      border.width: 1
      border.color: Qt.alpha(connectorItem.tint, 0.55)

      Text {
        id: connectorLabel
        anchors.centerIn: parent
        anchors.horizontalCenterOffset: 1
        text: connectorItem.label
        textFormat: Text.PlainText
        color: connectorItem.tint
        font.family: Style.font.menuFamily
        font.pixelSize: Math.round(Style.font.caption * 0.8)
        font.weight: Font.Bold
        font.letterSpacing: 1.2
      }
    }
  }

  component ActionNode: Column {
    id: actionDelegate
    property var store: editorActions
    property color sectionTint: root.flowAction
    required property int index
    required property var model
    property string selectedWords: String(model.selected || "")
    width: parent.width

    FocusScope {
      id: actionNode
      width: parent.width
      height: actionCard.height
      onActiveFocusChanged: root.revealEditorNode(actionNode)

      NodeCard {
        id: actionCard
        focusedNode: actionNode.activeFocus
        rail: actionDelegate.sectionTint

        Row {
          width: parent.width
          spacing: Style.spacing.sm

          NodeBadge {
            id: doBadge
            anchors.top: parent.top
            label: "DO " + (actionDelegate.index + 1)
            tint: actionDelegate.sectionTint
          }

          TypeSelector {
            id: actionTypeSelector
            width: parent.width - doBadge.width - actionControls.width - parent.spacing * 2
            value: String(actionDelegate.model.type)
            caption: root.describeAction(actionDelegate.model.type, actionDelegate.model.first, actionDelegate.model.second, actionDelegate.model.choice, actionDelegate.model.number, actionDelegate.model.selected)
            onCycle: function(delta) {
              actionDelegate.store.set(actionDelegate.index, root.defaultAction(root.cycleValue(root.actionTypes, value, delta)))
            }
            onOpenPicker: root.openTypePicker(actionDelegate.store === editorActions ? "action" : "until-action", actionDelegate.index, actionTypeSelector)
          }

          Row {
            id: actionControls
            anchors.top: parent.top
            spacing: Style.space(6)

            EditorButton {
              label: "↑"
              ghost: true
              enabled: actionDelegate.index > 0
              opacity: enabled ? 1 : 0.25
              onClicked: if (enabled) actionDelegate.store.move(actionDelegate.index, actionDelegate.index - 1, 1)
            }

            EditorButton {
              label: "↓"
              ghost: true
              enabled: actionDelegate.index < actionDelegate.store.count - 1
              opacity: enabled ? 1 : 0.25
              onClicked: if (enabled) actionDelegate.store.move(actionDelegate.index, actionDelegate.index + 1, 1)
            }

            EditorButton {
              label: "×"
              ghost: true
              enabled: actionDelegate.store.count > 1
              opacity: enabled ? 1 : 0.25
              onClicked: if (enabled) actionDelegate.store.remove(actionDelegate.index)
            }
          }
        }

        EditorField {
          width: parent.width
          visible: actionDelegate.model.type === "theme" || actionDelegate.model.type === "audio-output" || actionDelegate.model.type === "script"
          text: String(actionDelegate.model.first || "")
          placeholder: actionDelegate.model.type === "theme" ? "theme name" : actionDelegate.model.type === "script" ? "allowed script name" : "sink match"
          onTextChanged: actionDelegate.store.setProperty(actionDelegate.index, "first", text)
        }

        ChoiceSelector {
          width: parent.width
          visible: actionDelegate.model.type === "dnd" || actionDelegate.model.type === "nightlight" || actionDelegate.model.type === "stay-awake"
          first: "on"
          second: "off"
          value: String(actionDelegate.model.choice || "on")
          onSelected: function(value) { actionDelegate.store.setProperty(actionDelegate.index, "choice", value) }
        }

        Row {
          width: parent.width
          spacing: Style.spacing.sm
          visible: actionDelegate.model.type === "launch"

          EditorField {
            width: parent.width * 0.7 - parent.spacing
            text: String(actionDelegate.model.first || "")
            placeholder: "app"
            onTextChanged: actionDelegate.store.setProperty(actionDelegate.index, "first", text)
          }

          EditorField {
            width: parent.width * 0.3
            text: String(actionDelegate.model.number || "")
            placeholder: "workspace (optional)"
            onTextChanged: actionDelegate.store.setProperty(actionDelegate.index, "number", text)
          }
        }

        EditorField {
          width: parent.width
          visible: actionDelegate.model.type === "workspace"
          text: String(actionDelegate.model.number || "")
          placeholder: "workspace 1–10"
          onTextChanged: actionDelegate.store.setProperty(actionDelegate.index, "number", text)
        }

        Row {
          width: parent.width
          spacing: Style.spacing.sm
          visible: actionDelegate.model.type === "webhook"

          EditorField {
            width: parent.width * 0.35 - parent.spacing
            text: String(actionDelegate.model.first || "")
            placeholder: "endpoint"
            onTextChanged: actionDelegate.store.setProperty(actionDelegate.index, "first", text)
          }

          EditorField {
            width: parent.width * 0.65
            text: String(actionDelegate.model.second || "")
            placeholder: "message"
            onTextChanged: actionDelegate.store.setProperty(actionDelegate.index, "second", text)
          }
        }

        Column {
          width: parent.width
          spacing: Style.spacing.sm
          visible: actionDelegate.model.type === "hey-timetrack"

          Flow {
            width: parent.width
            spacing: Style.spacing.xs

            Repeater {
              model: ["start", "stop", "switch"]

              WordToggle {
                required property string modelData
                label: modelData
                checked: String(actionDelegate.model.choice || "switch") === modelData
                onToggled: actionDelegate.store.setProperty(actionDelegate.index, "choice", modelData)
              }
            }
          }

          Row {
            width: parent.width
            spacing: Style.spacing.sm

            FieldLabel { text: "file under" }

            EditorField {
              width: parent.width - Style.space(76) - parent.spacing
              text: String(actionDelegate.model.first || "")
              placeholder: "e.g. Deep work, Meetings, or {{branch}} (optional)"
              onTextChanged: actionDelegate.store.setProperty(actionDelegate.index, "first", text)
            }
          }

          Row {
            width: parent.width
            spacing: Style.spacing.sm

            FieldLabel { text: "or repo" }

            EditorField {
              width: parent.width - Style.space(76) - parent.spacing
              text: String(actionDelegate.model.second || "")
              placeholder: "repo path \u2014 file under its branch at that moment"
              onTextChanged: actionDelegate.store.setProperty(actionDelegate.index, "second", text)
            }
          }
        }

        Column {
          width: parent.width
          spacing: Style.spacing.sm
          visible: actionDelegate.model.type === "hey-agenda"

          Row {
            width: parent.width
            spacing: Style.spacing.sm

            FieldLabel { text: "title" }

            EditorField {
              width: parent.width - Style.space(76) - parent.spacing
              text: String(actionDelegate.model.first || "")
              placeholder: "Today (optional)"
              onTextChanged: actionDelegate.store.setProperty(actionDelegate.index, "first", text)
            }
          }

          ChoiceSelector {
            width: parent.width
            first: "skip empty"
            second: "always"
            value: String(actionDelegate.model.choice || "skip empty")
            onSelected: function(value) { actionDelegate.store.setProperty(actionDelegate.index, "choice", value) }
          }
        }

        Column {
          width: parent.width
          spacing: Style.spacing.sm
          visible: actionDelegate.model.type === "notify"

          EditorField {
            width: parent.width
            text: String(actionDelegate.model.first || "")
            placeholder: "title (optional)"
            onTextChanged: actionDelegate.store.setProperty(actionDelegate.index, "first", text)
          }

          EditorField {
            width: parent.width
            text: String(actionDelegate.model.second || "")
            placeholder: "message"
            multiline: true
            preferredHeight: Style.space(48)
            onTextChanged: actionDelegate.store.setProperty(actionDelegate.index, "second", text)
          }
        }

        Column {
          width: parent.width
          spacing: Style.spacing.sm
          visible: actionDelegate.model.type === "agent"

          EditorField {
            width: parent.width
            text: String(actionDelegate.model.first || "")
            placeholder: "agent task"
            multiline: true
            preferredHeight: Style.space(48)
            onTextChanged: actionDelegate.store.setProperty(actionDelegate.index, "first", text)
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
                onToggled: actionDelegate.store.setProperty(actionDelegate.index, "selected", root.toggleWord(actionDelegate.selectedWords, modelData))
              }
            }
          }

          EditorField {
            width: parent.width
            text: String(actionDelegate.model.number || "")
            placeholder: "timeoutSeconds (optional)"
            onTextChanged: actionDelegate.store.setProperty(actionDelegate.index, "number", text)
          }
        }
      }
    }

    Connector {
      arrow: true
      visible: actionDelegate.index < actionDelegate.store.count - 1
    }
  }


  component TriggerFields: Column {
    id: triggerFields
    property var trigger: ({})
    signal edited(var trigger)
    spacing: Style.spacing.sm

    Row {
      width: parent.width
      spacing: Style.spacing.sm
      visible: triggerFields.trigger.type === "time"

      FieldLabel { text: "at" }

      EditorField {
        width: parent.width - Style.space(76) - parent.spacing
        text: String(triggerFields.trigger.at || "")
        placeholder: "HH:MM"
        onTextChanged: {
          if (triggerFields.trigger.type !== "time") return
          var trigger = root.clone(triggerFields.trigger)
          trigger.at = text
          triggerFields.edited(trigger)
        }
      }
    }

    Flow {
      width: parent.width
      spacing: Style.spacing.xs
      visible: triggerFields.trigger.type === "time"

      Repeater {
        model: root.weekdays

        WordToggle {
          required property string modelData
          label: modelData
          checked: (triggerFields.trigger.days || []).indexOf(modelData) >= 0
          onToggled: {
            var trigger = root.clone(triggerFields.trigger)
            var days = (trigger.days || []).slice()
            var dayIndex = days.indexOf(modelData)
            if (dayIndex >= 0) days.splice(dayIndex, 1)
            else days.push(modelData)
            trigger.days = days
            triggerFields.edited(trigger)
          }
        }
      }
    }

    Row {
      width: parent.width
      spacing: Style.spacing.sm
      visible: triggerFields.trigger.type === "interval"

      FieldLabel { text: "minutes" }

      EditorField {
        width: parent.width - Style.space(76) - parent.spacing
        text: String(triggerFields.trigger.minutes || "")
        placeholder: "1–1440"
        onTextChanged: {
          if (triggerFields.trigger.type !== "interval") return
          var trigger = root.clone(triggerFields.trigger)
          trigger.minutes = text
          triggerFields.edited(trigger)
        }
      }
    }

    Row {
      width: parent.width
      spacing: Style.spacing.sm
      visible: triggerFields.trigger.type === "monitor-connected" || triggerFields.trigger.type === "monitor-disconnected" || triggerFields.trigger.type === "wifi-connected" || triggerFields.trigger.type === "custom"

      FieldLabel { text: triggerFields.trigger.type === "custom" ? "name" : "match" }

      EditorField {
        width: parent.width - Style.space(76) - parent.spacing
        text: triggerFields.trigger.type === "custom" ? String(triggerFields.trigger.name || "")
          : triggerFields.trigger.type === "wifi-connected" && (triggerFields.trigger.match || {}).known === false ? "unknown"
          : triggerFields.trigger.type === "wifi-connected" ? String((triggerFields.trigger.match || {}).ssid || "")
          : String((triggerFields.trigger.match || {}).description || "")
        placeholder: triggerFields.trigger.type === "wifi-connected" ? "SSID, *, or unknown"
          : triggerFields.trigger.type === "custom" ? "event name"
          : "name or description"
        onTextChanged: {
          if (triggerFields.trigger.type !== "custom" && triggerFields.trigger.type !== "wifi-connected"
              && triggerFields.trigger.type !== "monitor-connected" && triggerFields.trigger.type !== "monitor-disconnected") return
          var trigger = root.clone(triggerFields.trigger)
          if (trigger.type === "custom") trigger.name = text
          else if (trigger.type === "wifi-connected") trigger.match = text === "unknown" ? { known: false } : { ssid: text }
          else trigger.match = { description: text }
          triggerFields.edited(trigger)
        }
      }
    }

    Column {
      width: parent.width
      spacing: Style.spacing.sm
      visible: triggerFields.trigger.type === "app-opened" || triggerFields.trigger.type === "app-closed"

      Row {
        width: parent.width
        spacing: Style.spacing.sm

        FieldLabel { text: "class" }

        EditorField {
          width: parent.width - Style.space(76) - parent.spacing
          text: String((triggerFields.trigger.match || {}).class || "")
          placeholder: "class match"
          onTextChanged: {
            if (triggerFields.trigger.type !== "app-opened" && triggerFields.trigger.type !== "app-closed") return
            var trigger = root.clone(triggerFields.trigger)
            if (String((trigger.match || {}).class || "") === text) return
            trigger.match = { class: text }
            triggerFields.edited(trigger)
          }
        }
      }

      Row {
        width: parent.width
        spacing: Style.spacing.sm

        FieldLabel { text: "title" }

        EditorField {
          width: parent.width - Style.space(76) - parent.spacing
          text: String((triggerFields.trigger.match || {}).title || "")
          placeholder: "title match"
          onTextChanged: {
            if (triggerFields.trigger.type !== "app-opened" && triggerFields.trigger.type !== "app-closed") return
            var trigger = root.clone(triggerFields.trigger)
            if (String((trigger.match || {}).title || "") === text) return
            trigger.match = { title: text }
            triggerFields.edited(trigger)
          }
        }
      }
    }

    Column {
      width: parent.width
      spacing: Style.spacing.sm
      visible: triggerFields.trigger.type === "file-created" || triggerFields.trigger.type === "folder-created"

      Row {
        width: parent.width
        spacing: Style.spacing.sm

        FieldLabel { text: "folder" }

        EditorField {
          width: parent.width - Style.space(76) - parent.spacing
          text: String(triggerFields.trigger.path || "")
          placeholder: "~/Downloads"
          onTextChanged: {
            if (triggerFields.trigger.type !== "file-created" && triggerFields.trigger.type !== "folder-created") return
            if (String(triggerFields.trigger.path || "") === text) return
            var trigger = root.clone(triggerFields.trigger)
            trigger.path = text
            triggerFields.edited(trigger)
          }
        }
      }

      Row {
        width: parent.width
        spacing: Style.spacing.sm

        FieldLabel { text: "name" }

        EditorField {
          width: parent.width - Style.space(76) - parent.spacing
          text: String((triggerFields.trigger.match || {}).name || "")
          placeholder: "name filter, e.g. .pdf (optional)"
          onTextChanged: {
            if (triggerFields.trigger.type !== "file-created" && triggerFields.trigger.type !== "folder-created") return
            if (String((triggerFields.trigger.match || {}).name || "") === text) return
            var trigger = root.clone(triggerFields.trigger)
            if (String(text).trim() === "") delete trigger.match
            else trigger.match = { name: text }
            triggerFields.edited(trigger)
          }
        }
      }
    }

    Column {
      width: parent.width
      spacing: Style.spacing.sm
      visible: triggerFields.trigger.type === "git-branch-changed"

      Row {
        width: parent.width
        spacing: Style.spacing.sm

        FieldLabel { text: "repo" }

        EditorField {
          width: parent.width - Style.space(76) - parent.spacing
          text: String(triggerFields.trigger.repo || "")
          placeholder: "~/Documents/code/project"
          onTextChanged: {
            if (triggerFields.trigger.type !== "git-branch-changed") return
            if (String(triggerFields.trigger.repo || "") === text) return
            var trigger = root.clone(triggerFields.trigger)
            trigger.repo = text
            triggerFields.edited(trigger)
          }
        }
      }

      Row {
        width: parent.width
        spacing: Style.spacing.sm

        FieldLabel { text: "branch" }

        EditorField {
          width: parent.width - Style.space(76) - parent.spacing
          text: String((triggerFields.trigger.match || {}).branch || "")
          placeholder: "branch filter, e.g. main (optional)"
          onTextChanged: {
            if (triggerFields.trigger.type !== "git-branch-changed") return
            if (String((triggerFields.trigger.match || {}).branch || "") === text) return
            var trigger = root.clone(triggerFields.trigger)
            if (String(text).trim() === "") delete trigger.match
            else trigger.match = { branch: text }
            triggerFields.edited(trigger)
          }
        }
      }
    }

    Flow {
      width: parent.width
      spacing: Style.spacing.xs
      visible: (root.triggerProvides[String(triggerFields.trigger.type)] || []).length > 0

      Text {
        text: "provides"
        textFormat: Text.PlainText
        color: root.editorInkMuted
        font.family: Style.font.menuFamily
        font.pixelSize: Math.round(Style.font.caption * 0.9)
        font.capitalization: Font.AllUppercase
        font.letterSpacing: 0.8
        anchors.verticalCenter: undefined
        topPadding: Style.space(3)
      }

      Repeater {
        model: root.triggerProvides[String(triggerFields.trigger.type)] || []

        Rectangle {
          required property string modelData
          implicitWidth: providesText.implicitWidth + Style.space(12)
          implicitHeight: Style.space(20)
          radius: height / 2
          color: Qt.alpha(root.flowTrigger, 0.1)
          border.width: 1
          border.color: Qt.alpha(root.flowTrigger, 0.3)

          Text {
            id: providesText
            anchors.centerIn: parent
            text: modelData.indexOf(" ") >= 0 ? modelData : "{{" + modelData + "}}"
            textFormat: Text.PlainText
            color: Qt.alpha(root.flowTrigger, 0.95)
            font.family: Style.font.menuFamily
            font.pixelSize: Math.round(Style.font.caption * 0.9)
          }
        }
      }

      Text {
        text: "usable in any text field below"
        textFormat: Text.PlainText
        color: root.editorInkMuted
        font.family: Style.font.menuFamily
        font.pixelSize: Math.round(Style.font.caption * 0.9)
        topPadding: Style.space(3)
      }
    }

    Row {
      width: parent.width
      spacing: Style.spacing.sm
      visible: triggerFields.trigger.type === "power-source"

      FieldLabel { text: "source" }

      ChoiceSelector {
        width: parent.width - Style.space(76) - parent.spacing
        first: "ac"
        second: "battery"
        value: String(triggerFields.trigger.source || "ac")
        onSelected: function(value) {
          if (triggerFields.trigger.type !== "power-source") return
          var trigger = root.clone(triggerFields.trigger)
          trigger.source = value
          triggerFields.edited(trigger)
        }
      }
    }
  }

  component TypeSelector: FocusScope {
    id: typeSelector
    property string value: ""
    property string caption: ""
    signal cycle(int delta)
    signal openPicker()

    activeFocusOnTab: true
    implicitHeight: selectorColumn.implicitHeight

    Column {
      id: selectorColumn
      anchors.left: parent.left
      anchors.right: dropAffordance.left
      anchors.rightMargin: Style.spacing.sm
      spacing: Style.space(2)

      Text {
        width: parent.width
        text: root.prettyType(typeSelector.value)
        textFormat: Text.PlainText
        color: typeSelector.activeFocus ? root.accentColor : root.foreground
        font.family: Style.font.menuFamily
        font.pixelSize: Style.font.body
        font.weight: Font.DemiBold
        elide: Text.ElideRight
      }

      Text {
        width: parent.width
        visible: typeSelector.caption !== ""
        text: typeSelector.caption
        textFormat: Text.PlainText
        color: root.editorInkMuted
        font.family: Style.font.menuFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.Wrap
        maximumLineCount: 2
        elide: Text.ElideRight
      }
    }

    MouseArea {
      anchors.fill: selectorColumn
      onClicked: {
        typeSelector.forceActiveFocus()
        typeSelector.openPicker()
      }
    }

    Rectangle {
      id: dropAffordance
      anchors.right: parent.right
      anchors.top: parent.top
      width: dropLabel.implicitWidth + Style.space(16)
      height: Style.space(22)
      radius: height / 2
      color: dropMouse.containsMouse ? Qt.alpha(root.accentColor, 0.12) : "transparent"
      border.width: 1
      border.color: typeSelector.activeFocus || dropMouse.containsMouse ? Qt.alpha(root.accentColor, 0.45) : root.editorHairline
      opacity: typeSelector.activeFocus || selectorHover.hovered ? 1 : 0.55

      Text {
        id: dropLabel
        anchors.centerIn: parent
        text: "change ▾"
        textFormat: Text.PlainText
        color: typeSelector.activeFocus || dropMouse.containsMouse ? Qt.alpha(root.accentColor, 0.9) : root.editorInkMuted
        font.family: Style.font.menuFamily
        font.pixelSize: Math.round(Style.font.caption * 0.9)
      }

      MouseArea {
        id: dropMouse
        anchors.fill: parent
        hoverEnabled: true
        onClicked: {
          typeSelector.forceActiveFocus()
          typeSelector.openPicker()
        }
      }
    }

    HoverHandler { id: selectorHover }

    Keys.onPressed: function(event) {
      if (event.key === Qt.Key_Left || event.key === Qt.Key_Right) {
        typeSelector.cycle(event.key === Qt.Key_Left ? -1 : 1)
        event.accepted = true
      } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space || event.key === Qt.Key_Down) {
        typeSelector.openPicker()
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
    implicitHeight: Style.space(30)

    Rectangle {
      anchors.fill: parent
      radius: height / 2
      color: Qt.alpha(root.foreground, 0.045)
      border.width: 1
      border.color: choiceSelector.activeFocus ? Qt.alpha(root.accentColor, 0.9) : root.editorHairline
    }

    Row {
      anchors.fill: parent
      anchors.margins: Style.space(3)

      Repeater {
        model: [choiceSelector.first, choiceSelector.second]

        Rectangle {
          required property string modelData
          width: parent.width / 2
          height: parent.height
          radius: height / 2
          color: choiceSelector.value === modelData ? Qt.alpha(root.accentColor, 0.2) : "transparent"

          Text {
            anchors.centerIn: parent
            text: modelData
            textFormat: Text.PlainText
            color: choiceSelector.value === modelData ? root.accentColor : root.editorInkMuted
            font.family: Style.font.menuFamily
            font.pixelSize: Style.font.caption
            font.weight: choiceSelector.value === modelData ? Font.DemiBold : Font.Normal
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
    implicitHeight: Style.space(26)
    radius: height / 2
    color: checked ? Qt.alpha(root.accentColor, 0.18)
      : activeFocus || toggleMouse.containsMouse ? Qt.alpha(root.foreground, 0.07)
      : "transparent"
    border.width: 1
    border.color: activeFocus ? Qt.alpha(root.accentColor, 0.9)
      : checked ? Qt.alpha(root.accentColor, 0.5)
      : root.editorHairline

    Text {
      id: toggleText
      anchors.centerIn: parent
      text: wordToggle.label
      textFormat: Text.PlainText
      color: wordToggle.checked ? root.accentColor
        : toggleMouse.containsMouse || wordToggle.activeFocus ? root.foreground
        : root.editorInkMuted
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
    id: themeColorsFile
    path: root.stateHome + "/omarchy/current/theme/colors.toml"
    watchChanges: true
    printErrors: false
    onLoaded: root.loadPalette(text())
    onFileChanged: reload()
    onLoadFailed: root.loadPalette("")
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
        root.editorMode
          ? editorHeader.implicitHeight + editorChain.implicitHeight + editorFooter.implicitHeight
            + Style.spacing.md * 2 + card.contentTopInset + card.contentBottomInset
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
            if (root.pickerTarget !== null) root.closePicker()
            else root.cancelEditor()
            event.accepted = true
          }
        }

        Column {
          id: editorHeader
          anchors.top: parent.top
          anchors.left: parent.left
          anchors.right: parent.right
          spacing: Style.spacing.sm

          Row {
            width: parent.width
            spacing: Style.spacing.sm

            NodeBadge {
              id: editorModeBadge
              anchors.verticalCenter: parent.verticalCenter
              label: root.editorId === "" ? "NEW" : "EDIT"
              filled: false
              tint: root.editorInkMuted
            }

            Item {
              width: parent.width - editorModeBadge.width - parent.spacing
              height: Math.max(Style.space(30), editorName.implicitHeight + Style.space(6))

              Text {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                visible: editorName.text.length === 0
                text: "Name this automation"
                textFormat: Text.PlainText
                color: root.foreground
                opacity: 0.3
                font.family: Style.font.menuFamily
                font.pixelSize: Math.round(Style.font.body * 1.25)
                font.weight: Font.DemiBold
              }

              TextEdit {
                id: editorName
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                activeFocusOnTab: true
                textFormat: TextEdit.PlainText
                wrapMode: TextEdit.NoWrap
                color: root.foreground
                selectionColor: root.selectedBackground
                selectedTextColor: root.selectedText
                font.family: Style.font.menuFamily
                font.pixelSize: Math.round(Style.font.body * 1.25)
                font.weight: Font.DemiBold

                Keys.onPressed: function(event) {
                  if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
                    var forward = event.key === Qt.Key_Tab && (event.modifiers & Qt.ShiftModifier) === 0
                    editorName.nextItemInFocusChain(forward).forceActiveFocus()
                    event.accepted = true
                  }
                }
              }

              Rectangle {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                height: 1
                color: editorName.activeFocus ? Qt.alpha(root.accentColor, 0.9) : root.editorHairline
              }
            }
          }

          Text {
            width: parent.width
            topPadding: Style.space(2)
            text: "Enter on a step searches types  ·  Tab between fields  ·  Save stages for review, nothing runs yet"
            textFormat: Text.PlainText
            color: root.editorInkMuted
            font.family: Style.font.menuFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }

        Flickable {
          id: editorScroll
          anchors.top: editorHeader.bottom
          anchors.bottom: editorFooter.top
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.topMargin: Style.space(20)
          anchors.bottomMargin: Style.space(20)
          contentHeight: editorChain.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          visible: !root.editorLoading

          Column {
            id: editorChain
            width: editorScroll.width

            FocusScope {
              id: triggerNode
              width: parent.width
              height: triggerCard.height
              onActiveFocusChanged: root.revealEditorNode(triggerNode)

              NodeCard {
                id: triggerCard
                focusedNode: triggerNode.activeFocus
                rail: root.flowTrigger

                Row {
                  width: parent.width
                  spacing: Style.spacing.sm

                  NodeBadge {
                    id: whenBadge
                    anchors.top: parent.top
                    label: "WHEN"
                    tint: root.flowTrigger
                  }

                  TypeSelector {
                    id: triggerSelector
                    width: parent.width - whenBadge.width - parent.spacing
                    value: String(root.editorTrigger.type || "manual")
                    caption: root.describeTrigger(root.editorTrigger)
                    onCycle: function(delta) {
                      root.editorTrigger = root.defaultTrigger(root.cycleValue(root.triggerTypes, value, delta))
                    }
                    onOpenPicker: root.openTypePicker("trigger", 0, triggerSelector)
                  }
                }

                TriggerFields {
                  width: parent.width
                  trigger: root.editorTrigger
                  onEdited: function(trigger) { root.editorTrigger = trigger }
                }
              }
            }

            Connector {}

            Repeater {
              model: editorConditions

              Column {
                id: conditionDelegate
                required property int index
                required property var model
                property string selectedWords: String(model.selected || "")
                width: editorChain.width

                FocusScope {
                  id: conditionNode
                  width: parent.width
                  height: conditionCard.height
                  onActiveFocusChanged: root.revealEditorNode(conditionNode)

                  NodeCard {
                    id: conditionCard
                    focusedNode: conditionNode.activeFocus
                    rail: root.flowCondition

                    Row {
                      width: parent.width
                      spacing: Style.spacing.sm

                      NodeBadge {
                        id: ifBadge
                        anchors.top: parent.top
                        label: "ONLY IF"
                        tint: root.flowCondition
                        filled: false
                      }

                      TypeSelector {
                        id: conditionTypeSelector
                        width: parent.width - ifBadge.width - removeCondition.width - parent.spacing * 2
                        value: String(conditionDelegate.model.type)
                        caption: root.describeCondition(conditionDelegate.model.type, conditionDelegate.model.first, conditionDelegate.model.second, conditionDelegate.model.choice, conditionDelegate.model.selected)
                        onCycle: function(delta) {
                          editorConditions.set(conditionDelegate.index, root.defaultCondition(root.cycleValue(root.conditionTypes, value, delta)))
                        }
                        onOpenPicker: root.openTypePicker("condition", conditionDelegate.index, conditionTypeSelector)
                      }

                      EditorButton {
                        id: removeCondition
                        anchors.top: parent.top
                        label: "×"
                        ghost: true
                        onClicked: editorConditions.remove(conditionDelegate.index)
                      }
                    }

                    Row {
                      width: parent.width
                      spacing: Style.spacing.sm
                      visible: conditionDelegate.model.type === "time-between"

                      EditorField {
                        width: (parent.width - parent.spacing) / 2
                        text: String(conditionDelegate.model.first || "")
                        placeholder: "from HH:MM"
                        onTextChanged: editorConditions.setProperty(conditionDelegate.index, "first", text)
                      }

                      EditorField {
                        width: (parent.width - parent.spacing) / 2
                        text: String(conditionDelegate.model.second || "")
                        placeholder: "to HH:MM"
                        onTextChanged: editorConditions.setProperty(conditionDelegate.index, "second", text)
                      }
                    }

                    Flow {
                      width: parent.width
                      spacing: Style.spacing.xs
                      visible: conditionDelegate.model.type === "weekday"

                      Repeater {
                        model: root.weekdays

                        WordToggle {
                          required property string modelData
                          label: modelData
                          checked: root.wordsContain(conditionDelegate.selectedWords, modelData)
                          onToggled: editorConditions.setProperty(conditionDelegate.index, "selected", root.toggleWord(conditionDelegate.selectedWords, modelData))
                        }
                      }
                    }

                    ChoiceSelector {
                      width: parent.width
                      visible: conditionDelegate.model.type === "on-power" || conditionDelegate.model.type === "lid-state"
                      first: conditionDelegate.model.type === "on-power" ? "ac" : "open"
                      second: conditionDelegate.model.type === "on-power" ? "battery" : "closed"
                      value: String(conditionDelegate.model.choice || first)
                      onSelected: function(value) { editorConditions.setProperty(conditionDelegate.index, "choice", value) }
                    }

                    EditorField {
                      width: parent.width
                      visible: conditionDelegate.model.type === "monitor-present" || conditionDelegate.model.type === "on-ssid"
                      text: String(conditionDelegate.model.first || "")
                      placeholder: conditionDelegate.model.type === "on-ssid" ? "SSID match" : "monitor name or description"
                      onTextChanged: editorConditions.setProperty(conditionDelegate.index, "first", text)
                    }

                    Row {
                      width: parent.width
                      spacing: Style.spacing.sm
                      visible: conditionDelegate.model.type === "hey-events"

                      FieldLabel { text: "at least" }

                      EditorField {
                        width: parent.width - Style.space(76) - parent.spacing
                        text: String(conditionDelegate.model.first || "")
                        placeholder: "number of events today, 1\u201350"
                        onTextChanged: editorConditions.setProperty(conditionDelegate.index, "first", text)
                      }
                    }

                    Column {
                      width: parent.width
                      spacing: Style.spacing.sm
                      visible: conditionDelegate.model.type === "on-branch"

                      Row {
                        width: parent.width
                        spacing: Style.spacing.sm

                        FieldLabel { text: "repo" }

                        EditorField {
                          width: parent.width - Style.space(76) - parent.spacing
                          text: String(conditionDelegate.model.first || "")
                          placeholder: "~/Documents/code/project"
                          onTextChanged: editorConditions.setProperty(conditionDelegate.index, "first", text)
                        }
                      }

                      Row {
                        width: parent.width
                        spacing: Style.spacing.sm

                        FieldLabel { text: "branch" }

                        EditorField {
                          width: parent.width - Style.space(76) - parent.spacing
                          text: String(conditionDelegate.model.second || "")
                          placeholder: "branch, e.g. main"
                          onTextChanged: editorConditions.setProperty(conditionDelegate.index, "second", text)
                        }
                      }
                    }

                    Column {
                      width: parent.width
                      spacing: Style.spacing.sm
                      visible: conditionDelegate.model.type === "app-running"

                      Row {
                        width: parent.width
                        spacing: Style.spacing.sm

                        FieldLabel { text: "class" }

                        EditorField {
                          width: parent.width - Style.space(76) - parent.spacing
                          text: String(conditionDelegate.model.first || "")
                          placeholder: "class match"
                          onTextChanged: {
                            if (conditionDelegate.model.type !== "app-running" || String(conditionDelegate.model.first || "") === text) return
                            editorConditions.setProperty(conditionDelegate.index, "first", text)
                            if (String(text).trim() !== "") editorConditions.setProperty(conditionDelegate.index, "second", "")
                          }
                        }
                      }

                      Row {
                        width: parent.width
                        spacing: Style.spacing.sm

                        FieldLabel { text: "title" }

                        EditorField {
                          width: parent.width - Style.space(76) - parent.spacing
                          text: String(conditionDelegate.model.second || "")
                          placeholder: "title match"
                          onTextChanged: {
                            if (conditionDelegate.model.type !== "app-running" || String(conditionDelegate.model.second || "") === text) return
                            editorConditions.setProperty(conditionDelegate.index, "second", text)
                            if (String(text).trim() !== "") editorConditions.setProperty(conditionDelegate.index, "first", "")
                          }
                        }
                      }
                    }
                  }
                }

                Connector {
                  label: conditionDelegate.index < editorConditions.count - 1 ? "AND" : ""
                  tint: root.flowCondition
                }
              }
            }

            Item {
              width: parent.width
              height: addConditionButton.height

              EditorButton {
                id: addConditionButton
                anchors.horizontalCenter: parent.horizontalCenter
                label: editorConditions.count >= 5 ? "5 conditions maximum" : "＋ only if…"
                ghost: true
                accented: true
                tintColor: root.flowCondition
                enabled: editorConditions.count < 5
                opacity: enabled ? 1 : 0.4
                onClicked: if (enabled) editorConditions.append(root.defaultCondition("time-between"))
              }
            }

            Connector {
              arrow: true
              label: editorConditions.count > 0 ? "ALL PASS" : "THEN"
            }

            Repeater {
              model: editorActions

              ActionNode { store: editorActions }
            }

            Item {
              width: parent.width
              height: addActionButton.height + Style.spacing.sm

              EditorButton {
                id: addActionButton
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.top: parent.top
                anchors.topMargin: Style.spacing.sm
                label: editorActions.count >= 10 ? "10 actions maximum" : "＋ do…"
                ghost: true
                accented: true
                tintColor: root.flowAction
                enabled: editorActions.count < 10
                opacity: enabled ? 1 : 0.4
                onClicked: if (enabled) editorActions.append(root.defaultAction("notify"))
              }
            }

            Item {
              width: parent.width
              visible: root.editorUntilTrigger === null
              height: addUntilButton.height + Style.spacing.sm

              EditorButton {
                id: addUntilButton
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.top: parent.top
                anchors.topMargin: Style.spacing.sm
                label: "＋ until…"
                ghost: true
                accented: true
                tintColor: root.flowUntil
                onClicked: {
                  root.editorUntilTrigger = root.defaultTrigger("wifi-disconnected")
                  root.editorUntilRevert = true
                }
              }
            }

            Connector {
              visible: root.editorUntilTrigger !== null
              arrow: true
              label: "UNTIL"
              tint: root.flowUntil
            }

            FocusScope {
              id: untilTriggerNode
              width: parent.width
              visible: root.editorUntilTrigger !== null
              height: root.editorUntilTrigger === null ? 0 : untilCard.height
              onActiveFocusChanged: root.revealEditorNode(untilTriggerNode)

              NodeCard {
                id: untilCard
                focusedNode: untilTriggerNode.activeFocus
                rail: root.flowUntil

                Row {
                  width: parent.width
                  spacing: Style.spacing.sm

                  NodeBadge {
                    id: untilBadge
                    anchors.top: parent.top
                    label: "UNTIL"
                    tint: root.flowUntil
                  }

                  TypeSelector {
                    id: untilSelector
                    width: parent.width - untilBadge.width - removeUntil.width - parent.spacing * 2
                    value: String((root.editorUntilTrigger || {}).type || "")
                    caption: root.editorUntilTrigger === null ? "" : root.describeTrigger(root.editorUntilTrigger).replace("fires", "closes this rule")
                    onCycle: function(delta) {
                      root.editorUntilTrigger = root.defaultTrigger(root.cycleValue(root.untilTypes, value, delta))
                    }
                    onOpenPicker: root.openTypePicker("until", 0, untilSelector)
                  }

                  EditorButton {
                    id: removeUntil
                    anchors.top: parent.top
                    label: "×"
                    ghost: true
                    onClicked: {
                      root.editorUntilTrigger = null
                      root.editorUntilRevert = false
                      editorUntilActions.clear()
                    }
                  }
                }

                TriggerFields {
                  width: parent.width
                  trigger: root.editorUntilTrigger || ({})
                  onEdited: function(trigger) { root.editorUntilTrigger = trigger }
                }

                Row {
                  width: parent.width
                  spacing: Style.spacing.sm

                  WordToggle {
                    label: "restore what this rule changed"
                    checked: root.editorUntilRevert
                    onToggled: root.editorUntilRevert = !root.editorUntilRevert
                  }

                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width - Style.space(230)
                    visible: root.editorUntilRevert
                    text: "theme, dnd, nightlight, stay-awake, and audio go back to how they were before this rule fired"
                    textFormat: Text.PlainText
                    color: root.editorInkMuted
                    font.family: Style.font.menuFamily
                    font.pixelSize: Math.round(Style.font.caption * 0.9)
                    wrapMode: Text.Wrap
                    maximumLineCount: 2
                    elide: Text.ElideRight
                  }
                }
              }
            }

            Connector {
              visible: root.editorUntilTrigger !== null
              tint: root.flowUntil
            }

            Repeater {
              model: root.editorUntilTrigger === null ? null : editorUntilActions

              ActionNode {
                store: editorUntilActions
                sectionTint: root.flowUntil
              }
            }

            Item {
              width: parent.width
              visible: root.editorUntilTrigger !== null
              height: root.editorUntilTrigger === null ? 0 : addUntilActionButton.height + Style.spacing.sm

              EditorButton {
                id: addUntilActionButton
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.top: parent.top
                anchors.topMargin: Style.spacing.sm
                label: editorUntilActions.count >= 10 ? "10 actions maximum" : "＋ do when it closes…"
                ghost: true
                accented: true
                tintColor: root.flowUntil
                enabled: editorUntilActions.count < 10
                opacity: enabled ? 1 : 0.4
                onClicked: if (enabled) editorUntilActions.append(root.defaultAction("notify"))
              }
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

          Row {
            id: cooldownGroup
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.spacing.xs

            FieldLabel { width: implicitWidth; text: "cooldown" }

            EditorField {
              id: editorCooldown
              width: Style.space(64)
              placeholder: "60"
            }

            FieldLabel { width: implicitWidth; text: "sec" }
          }

          Item {
            width: parent.width - cooldownGroup.width - cancelEditorButton.width - saveEditorButton.width - parent.spacing * 3
            height: 1
          }

          EditorButton {
            id: cancelEditorButton
            anchors.verticalCenter: parent.verticalCenter
            label: "Cancel"
            ghost: true
            onClicked: root.cancelEditor()
          }

          EditorButton {
            id: saveEditorButton
            anchors.verticalCenter: parent.verticalCenter
            label: "Save · review"
            strong: true
            onClicked: root.saveEditor()
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

        Rectangle {
          anchors.fill: parent
          z: 60
          visible: root.pickerTarget !== null
          color: root.scrim

          MouseArea {
            anchors.fill: parent
            onClicked: root.closePicker()
          }

          Rectangle {
            id: pickerCard
            anchors.horizontalCenter: parent.horizontalCenter
            y: Style.space(56)
            width: Math.min(Style.space(380), parent.width - Style.space(48))
            height: pickerSearchBox.height + pickerList.height + Style.spacing.md * 2 + Style.spacing.sm * 2
            radius: root.cornerRadius
            color: root.background
            border.width: 1
            border.color: Qt.alpha(root.pickerTint, 0.65)

            MouseArea { anchors.fill: parent; onClicked: {} }

            Rectangle {
              id: pickerSearchBox
              anchors.top: parent.top
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.topMargin: Style.spacing.md
              anchors.leftMargin: Style.spacing.md
              anchors.rightMargin: Style.spacing.md
              height: Style.space(34)
              radius: Style.space(6)
              color: Qt.alpha(root.foreground, 0.05)
              border.width: 1
              border.color: pickerInput.activeFocus ? Qt.alpha(root.pickerTint, 0.9) : root.editorHairline

              Text {
                anchors.left: parent.left
                anchors.leftMargin: Style.spacing.sm
                anchors.verticalCenter: parent.verticalCenter
                visible: pickerInput.text.length === 0
                text: root.pickerTarget !== null && root.pickerTarget.kind === "trigger" ? "search triggers…"
                  : root.pickerTarget !== null && root.pickerTarget.kind === "condition" ? "search conditions…"
                  : "search actions…"
                textFormat: Text.PlainText
                color: root.foreground
                opacity: 0.35
                font.family: Style.font.menuFamily
                font.pixelSize: Style.font.caption
              }

              TextEdit {
                id: pickerInput
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.leftMargin: Style.spacing.sm
                anchors.rightMargin: Style.spacing.sm
                anchors.verticalCenter: parent.verticalCenter
                textFormat: TextEdit.PlainText
                wrapMode: TextEdit.NoWrap
                color: root.foreground
                selectionColor: root.selectedBackground
                selectedTextColor: root.selectedText
                font.family: Style.font.menuFamily
                font.pixelSize: Style.font.caption
                onTextChanged: {
                  root.pickerQuery = text
                  root.pickerIndex = 0
                }

                Keys.onPressed: function(event) {
                  if (event.key === Qt.Key_Escape) {
                    root.closePicker()
                    event.accepted = true
                  } else if (event.key === Qt.Key_Down) {
                    root.pickerIndex = Math.min(root.pickerIndex + 1, root.pickerFiltered.length - 1)
                    event.accepted = true
                  } else if (event.key === Qt.Key_Up) {
                    root.pickerIndex = Math.max(root.pickerIndex - 1, 0)
                    event.accepted = true
                  } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                    root.applyPicker()
                    event.accepted = true
                  } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
                    event.accepted = true
                  }
                }
              }
            }

            ListView {
              id: pickerList
              anchors.top: pickerSearchBox.bottom
              anchors.topMargin: Style.spacing.sm
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.leftMargin: Style.spacing.md
              anchors.rightMargin: Style.spacing.md
              height: Math.max(1, Math.min(root.pickerFiltered.length, 7)) * Style.space(44)
              clip: true
              model: root.pickerFiltered
              boundsBehavior: Flickable.StopAtBounds

              onModelChanged: positionViewAtBeginning()

              delegate: Item {
                id: pickerRow
                required property var modelData
                required property int index
                width: pickerList.width
                height: Style.space(44)

                Rectangle {
                  anchors.fill: parent
                  radius: Style.space(6)
                  color: pickerRow.index === root.pickerIndex ? Qt.alpha(root.pickerTint, 0.12) : "transparent"
                }

                Rectangle {
                  visible: pickerRow.index === root.pickerIndex
                  anchors.left: parent.left
                  anchors.top: parent.top
                  anchors.bottom: parent.bottom
                  anchors.topMargin: Style.space(8)
                  anchors.bottomMargin: Style.space(8)
                  anchors.leftMargin: Style.space(4)
                  width: Style.space(2)
                  radius: 1
                  color: root.pickerTint
                }

                Column {
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.leftMargin: Style.space(14)
                  anchors.rightMargin: Style.spacing.sm

                  Text {
                    width: parent.width
                    text: root.prettyType(pickerRow.modelData.type)
                    textFormat: Text.PlainText
                    color: pickerRow.index === root.pickerIndex ? root.pickerTint : root.foreground
                    font.family: Style.font.menuFamily
                    font.pixelSize: Style.font.caption
                    font.weight: Font.DemiBold
                    elide: Text.ElideRight
                  }

                  Text {
                    width: parent.width
                    text: pickerRow.modelData.caption
                    textFormat: Text.PlainText
                    color: root.editorInkMuted
                    font.family: Style.font.menuFamily
                    font.pixelSize: Math.round(Style.font.caption * 0.9)
                    elide: Text.ElideRight
                  }
                }

                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  onEntered: root.pickerIndex = pickerRow.index
                  onClicked: {
                    root.pickerIndex = pickerRow.index
                    root.applyPicker()
                  }
                }
              }

              Text {
                visible: root.pickerFiltered.length === 0
                anchors.centerIn: parent
                text: "no matching steps"
                textFormat: Text.PlainText
                color: root.editorInkMuted
                font.family: Style.font.menuFamily
                font.pixelSize: Style.font.caption
              }
            }
          }
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
