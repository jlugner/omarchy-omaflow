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

  property bool evalQueued: false

  function poke(reason) {
    // Coalesce bursts: at most one queued eval at a time; the evaluator
    // itself serializes under a lock.
    if (root.evalQueued)
      return
    root.evalQueued = true
    evalDelay.reason = reason
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

  // Immediacy sources -------------------------------------------------------

  readonly property int monitorCount: Hyprland.monitors.values.length
  onMonitorCountChanged: root.poke("monitors")

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      var name = String(event.name || "")
      if (name.indexOf("monitor") === 0)
        root.poke("monitors")
    }
  }

  readonly property bool onBattery: UPower.onBattery
  onOnBatteryChanged: root.poke("power")

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

  // Guaranteed heartbeat: time triggers + belt-and-braces re-diff.
  Timer {
    interval: 45000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.poke("tick")
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
