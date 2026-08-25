import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Services.UPower
import QtQuick

// The Omaflow engine host. Deliberately contains NO automation logic:
// it only converts change signals into `omaflow-eval` invocations. The
// evaluator re-derives all state itself, so redundant pokes are no-ops
// and the periodic tick guarantees at most ~45s latency even if a
// signal source misbehaves.
Item {
  id: root

  property var shell: null
  property var manifest: null

  readonly property string pluginDir: {
    var url = Qt.resolvedUrl(".").toString()
    return url.indexOf("file://") === 0 ? url.substring(7) : url
  }
  readonly property string evalPath: pluginDir + "bin/omaflow-eval"
  readonly property string omaflowPath: pluginDir + "bin/omaflow"
  readonly property string stateHome: Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state"

  property bool evalQueued: false
  property bool firstTick: true
  property var watchedDirs: []

  function applyWatchedDirs(text) {
    fileMonitor.running = false
    var dirs = []
    try {
      var payload = JSON.parse(String(text || "{}"))
      if (Array.isArray(payload.dirs))
        dirs = payload.dirs.filter(function(path) { return typeof path === "string" && path.length > 0 })
    } catch (error) {
      dirs = []
    }
    root.watchedDirs = dirs
    if (dirs.length > 0)
      Qt.callLater(function() {
        if (root.watchedDirs.length > 0)
          fileMonitor.running = true
      })
  }

  function poke(reason, immediate) {
    // Coalesce bursts: at most one queued eval at a time; the evaluator
    // itself serializes under a lock.
    if (root.evalQueued && !immediate)
      return
    root.evalQueued = true
    evalDelay.reason = reason
    evalDelay.interval = immediate ? 0 : 400
    evalDelay.restart()
  }

  Timer {
    id: evalDelay
    property string reason: "tick"
    interval: 400
    repeat: false
    onTriggered: {
      root.evalQueued = false
      Quickshell.execDetached([root.evalPath, reason])
    }
  }

  Process {
    id: firstRun
    command: [root.omaflowPath, "first-run"]
  }

  // Immediacy sources -------------------------------------------------------

  readonly property int monitorCount: Hyprland.monitors.values.length
  onMonitorCountChanged: root.poke("monitors")

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      var name = String(event.name || "")
      if (name.indexOf("monitor") === 0)
        root.poke("monitors")
      else if (name.indexOf("openwindow") === 0 || name.indexOf("closewindow") === 0)
        root.poke("windows")
    }
  }

  readonly property bool onBattery: UPower.onBattery
  onOnBatteryChanged: root.poke("power")

  Process {
    id: upowerMonitor
    running: true
    command: ["gdbus", "monitor", "--system", "--dest", "org.freedesktop.UPower", "--object-path", "/org/freedesktop/UPower"]
    stdout: SplitParser {
      onRead: root.poke("lid", true)
    }
    onExited: upowerRespawn.restart()
  }

  Timer {
    id: upowerRespawn
    interval: 5000
    repeat: false
    onTriggered: upowerMonitor.running = true
  }

  Process {
    id: networkMonitor
    running: true
    command: ["nmcli", "monitor"]
    stdout: SplitParser {
      onRead: function(line) {
        var text = String(line)
        if (text.indexOf("connect") >= 0 || text.indexOf("Connectivity") >= 0)
          root.poke("network")
      }
    }
    onExited: networkRespawn.restart()
  }

  Timer {
    id: networkRespawn
    interval: 5000
    repeat: false
    onTriggered: networkMonitor.running = true
  }

  FileView {
    id: watchedDirsFile
    path: root.stateHome + "/omaflow/watched-dirs.json"
    watchChanges: true
    printErrors: false
    onLoaded: root.applyWatchedDirs(text())
    onFileChanged: reload()
    onLoadFailed: root.applyWatchedDirs("")
  }

  Process {
    id: fileMonitor
    command: ["inotifywait", "-m", "-q", "-e", "create,moved_to", "--format", "%w"].concat(root.watchedDirs)
    stdout: SplitParser {
      onRead: root.poke("files")
    }
  }

  // Guaranteed heartbeat: time triggers + belt-and-braces re-diff.
  Timer {
    interval: 45000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: {
      root.poke("tick")
      if (root.firstTick) {
        root.firstTick = false
        firstRun.running = true
      }
    }
  }

  IpcHandler {
    target: "omaflow"

    function ping(): string {
      return "ok"
    }

    function poke(): string {
      root.poke("ipc")
      return "ok"
    }
  }
}
