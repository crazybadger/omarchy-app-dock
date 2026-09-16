import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui

// A macOS-Dock-style strip along the bottom of the screen: one icon per open
// window, ordered by workspace 1-9 (then any higher-numbered workspaces in
// use), then creation order within each workspace. Click an icon to jump
// straight to that window.
//
// Triggered by resting the cursor at the very bottom screen edge (see the
// dedicated block in ~/.config/hypr/input.lua), not a gesture -- deliberately
// independent of the crazybadger.workspace-ribbon plugin/trigger, though it
// shares the same icon-resolution approach (see comments below) and the same
// generic overlay IPC contract: `omarchy-shell shell toggle crazybadger.app-dock`
Item {
  id: root

  property var shell: null
  property var manifest: null

  property bool opened: false

  function open(payloadJson) {
    root.opened = true
  }

  function close() { root.opened = false }

  function dismiss() {
    root.opened = false
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "crazybadger.app-dock")
  }

  function toggle() { root.opened ? root.dismiss() : root.open("{}") }

  IpcHandler {
    target: (root.manifest && root.manifest.id) || "crazybadger.app-dock"
    function open(): void { root.open("{}") }
    function close(): void { root.dismiss() }
    function toggle(): void { root.toggle() }
  }

  // -------------------------------------------------------------- icons
  //
  // Verbatim from crazybadger.workspace-ribbon: Qt's themed icon lookup
  // (Quickshell.iconPath) misses plenty of apps even when their .desktop
  // Icon= exactly matches the WM class, so we index the XDG icon dirs
  // ourselves first, same fix the shell's own app library uses.
  property var iconIndex: ({})
  property var _pendingIconIndex: ({})

  function iconIndexScanCommand() {
    return [
      'dirs="$HOME/.icons $HOME/.local/share/icons";',
      'IFS=":"; for d in ${XDG_DATA_DIRS:-/usr/local/share:/usr/share}; do dirs="$dirs $d/icons"; done; unset IFS;',
      'for ext in svg png; do',
      '  for base in $dirs; do',
      '    [[ -d $base ]] && find "$base" \\( -path "*/apps/*" -o -path "*/devices/*" \\) -name "*.$ext" 2>/dev/null;',
      '  done;',
      '  find /usr/share/pixmaps -maxdepth 1 -name "*.$ext" 2>/dev/null;',
      'done'
    ].join(' ')
  }

  function indexIconLine(path) {
    var value = String(path || "").trim()
    if (value.length === 0) return
    var slash = value.lastIndexOf("/")
    var file = slash >= 0 ? value.slice(slash + 1) : value
    var dot = file.lastIndexOf(".")
    var name = dot > 0 ? file.slice(0, dot) : file
    if (name.length > 0 && root._pendingIconIndex[name] === undefined)
      root._pendingIconIndex[name] = value
  }

  Process {
    id: iconIndexScan
    command: ["bash", "-c", root.iconIndexScanCommand()]
    stdout: SplitParser { onRead: function(line) { root.indexIconLine(line) } }
    onStarted: root._pendingIconIndex = ({})
    onExited: root.iconIndex = root._pendingIconIndex
  }

  Component.onCompleted: iconIndexScan.running = true

  readonly property int _rescanCooldownMs: 8000
  property bool _rescanCoolingDown: false

  Timer {
    id: rescanCooldown
    interval: root._rescanCooldownMs
    onTriggered: root._rescanCoolingDown = false
  }

  function requestIconRescan() {
    if (root._rescanCoolingDown || iconIndexScan.running) return
    root._rescanCoolingDown = true
    rescanCooldown.restart()
    iconIndexScan.running = true
  }

  // Hyprland's own per-workspace toplevel objects only carry title/address/
  // workspace -- NOT the WM class. The class/appId only lives on the generic
  // Wayland toplevel type (ToplevelManager.toplevels). Cross-reference by
  // title for icon lookup (a title collision just means two windows briefly
  // share an icon guess -- harmless here).
  function titleToAppId() {
    var map = ({})
    var values = ToplevelManager.toplevels.values
    for (var i = 0; i < values.length; i++) {
      var t = values[i]
      var title = String(t.title || "")
      var appId = String(t.appId || "")
      if (title.length > 0 && appId.length > 0 && map[title] === undefined) map[title] = appId
    }
    return map
  }

  function appIdForToplevel(toplevel) {
    if (!toplevel) return ""
    var direct = String(toplevel.class || toplevel.appId || "")
    if (direct.length > 0) return direct
    var map = root.titleToAppId()
    return map[String(toplevel.title || "")] || ""
  }

  function lookupIconName(name) {
    var id = String(name || "")
    if (id.length === 0) return ""
    var indexed = root.iconIndex[id]
    if (indexed) return Util.fileUrl(indexed)
    var themed = Quickshell.iconPath(id, true)
    if (themed.length > 0) return themed
    var lower = id.toLowerCase()
    if (lower !== id) {
      var indexedLower = root.iconIndex[lower]
      if (indexedLower) return Util.fileUrl(indexedLower)
      var themedLower = Quickshell.iconPath(lower, true)
      if (themedLower.length > 0) return themedLower
    }
    return ""
  }

  // Some apps' running WM class has no relation to their installed icon
  // (webapps especially). Their window titles do carry the app name, so as a
  // last resort, match the title against installed .desktop entries.
  function desktopIconForTitle(title) {
    var t = String(title || "").toLowerCase()
    if (t.length === 0) return ""
    var entries = DesktopEntries.applications.values || []
    var bestIcon = ""
    var bestLen = 0
    for (var i = 0; i < entries.length; i++) {
      var e = entries[i]
      var name = String((e && e.name) || "").toLowerCase()
      if (name.length < 3 || t.indexOf(name) === -1) continue
      if (name.length > bestLen) { bestLen = name.length; bestIcon = String((e && e.icon) || "") }
    }
    return bestIcon
  }

  function resolveIconForToplevel(toplevel) {
    if (!toplevel) return Quickshell.iconPath("application-x-executable", true)
    var found = root.lookupIconName(root.appIdForToplevel(toplevel))
    if (found.length === 0) {
      var deIcon = root.desktopIconForTitle(toplevel.title)
      if (deIcon.length > 0) found = root.lookupIconName(deIcon)
    }
    if (found.length === 0) {
      Qt.callLater(root.requestIconRescan)
      return Quickshell.iconPath("application-x-executable", true)
    }
    return found
  }

  // ------------------------------------------------------------- windows

  // Always include 1-9 (the standard row every Omarchy keybind reaches) plus
  // whatever extra/higher-numbered workspaces are actually in use.
  function workspaceIds() {
    var ids = [1, 2, 3, 4, 5, 6, 7, 8, 9]
    var values = Hyprland.workspaces.values
    for (var i = 0; i < values.length; i++) {
      var id = values[i].id
      if (id > 0 && ids.indexOf(id) === -1) ids.push(id)
    }
    ids.sort(function(a, b) { return a - b })
    return ids
  }

  function workspaceById(id) {
    var values = Hyprland.workspaces.values
    for (var i = 0; i < values.length; i++) {
      if (values[i].id === id) return values[i]
    }
    return null
  }

  // Flatten every open window across those workspaces into one ordered list.
  function dockEntries() {
    var list = []
    var ids = root.workspaceIds()
    for (var i = 0; i < ids.length; i++) {
      var ws = root.workspaceById(ids[i])
      if (!ws) continue
      var tls = ws.toplevels.values
      for (var j = 0; j < tls.length; j++) {
        list.push({ toplevel: tls[j], workspaceId: ids[i] })
      }
    }
    return list
  }

  function isActive(entry) {
    var active = ToplevelManager.activeToplevel
    return active && entry && String(active.title || "") === String(entry.toplevel.title || "")
  }

  // Focus by address (unambiguous even when two windows share a title, unlike
  // the ribbon's title cross-reference above, which is fine for an icon guess
  // but not precise enough for "which exact window did they click"). Same
  // dispatcher confirmed live while designing this: hl.dsp.focus({ window =
  // "address:0x..." }) focuses that exact window and auto-switches workspace.
  Process { id: focusProcess; running: false }

  function focusEntry(entry) {
    var address = String((entry && entry.toplevel && entry.toplevel.address) || "")
    if (address.length === 0) return
    // Quickshell's Hyprland binding returns the bare hex address with no "0x"
    // prefix (confirmed live: "5bfb893eede0"), but Hyprland's window-selector
    // syntax requires it ("address:0x..."). Without this the dispatcher
    // silently matched nothing -- no error, just a no-op.
    if (address.indexOf("0x") !== 0) address = "0x" + address
    focusProcess.command = ["hyprctl", "dispatch", "hl.dsp.focus({ window = \"address:" + address + "\" })"]
    focusProcess.running = true
    root.dismiss()
  }

  // ---------------------------------------------------------------- style

  property color surfaceColor: Color.menu.background
  readonly property int cornerRadius: Style.cornerRadius
  property var borderSpec: Border.surfaceSpec("menu", "border", Color.menu.border, Math.max(1, Style.space(2)))

  // Bigger than the ribbon's 16px per-workspace summary icons (this is one
  // icon per window, not a multi-icon-per-tile summary), but not full macOS
  // Dock scale.
  readonly property int iconSize: Style.space(40)
  readonly property int tileSize: Style.space(60)

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "app-dock"
    WlrLayershell.layer: WlrLayer.Overlay
    // Deliberately no keyboard focus grab -- this overlay is triggered
    // passively by cursor position, not an explicit user action like the
    // ribbon's gesture, so stealing keyboard focus (e.g. mid-sentence in
    // another app) would be actively disruptive. Mouse-only.
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore

    // No full-screen scrim -- unlike the ribbon this isn't meant to feel
    // like a modal you invoked, just a Dock reveal, so the rest of the
    // screen stays exactly as it was.
    MouseArea {
      anchors.fill: parent
      onClicked: root.dismiss()
    }

    BorderSurface {
      id: dockBar
      width: row.implicitWidth + Style.spacing.xl * 2
      height: row.implicitHeight + Style.spacing.md * 2
      radius: root.cornerRadius
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.bottom: parent.bottom
      anchors.bottomMargin: Style.space(10)
      color: root.surfaceColor
      borderSpec: root.borderSpec
      padding: 0

      MouseArea { anchors.fill: parent; onClicked: {} }

      RowLayout {
        id: row
        anchors.centerIn: parent
        spacing: Style.spacing.sm

        Repeater {
          model: root.dockEntries()

          delegate: Rectangle {
            id: tile
            required property var modelData

            readonly property bool active: root.isActive(modelData)

            Layout.preferredWidth: root.tileSize
            Layout.preferredHeight: root.tileSize
            radius: root.cornerRadius
            color: hoverArea.containsMouse ? Color.menu.selectedBackground : "transparent"

            Behavior on color { ColorAnimation { duration: 100 } }

            Image {
              id: icon
              anchors.centerIn: parent
              // Re-evaluates once the icon index scan finishes, so tiles
              // upgrade from the generic fallback to the real icon.
              readonly property var _indexReady: root.iconIndex
              source: root.resolveIconForToplevel(tile.modelData.toplevel)
              sourceSize.width: root.iconSize
              sourceSize.height: root.iconSize
              width: root.iconSize
              height: root.iconSize
              fillMode: Image.PreserveAspectFit
              scale: hoverArea.containsMouse ? 1.12 : 1.0
              Behavior on scale { NumberAnimation { duration: 100; easing.type: Easing.OutCubic } }
            }

            Rectangle {
              visible: tile.active
              width: Style.space(5)
              height: Style.space(5)
              radius: width / 2
              color: Color.accent
              anchors.horizontalCenter: parent.horizontalCenter
              anchors.bottom: parent.bottom
              anchors.bottomMargin: Style.space(2)
            }

            MouseArea {
              id: hoverArea
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.focusEntry(tile.modelData)
            }
          }
        }
      }
    }
  }
}
