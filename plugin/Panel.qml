import QtQuick
import QtQuick.Controls
import Qt.labs.folderlistmodel
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Omarchy Sounds on the bar.
//
//   left click    open the panel
//   right click   turn every sound on/off
//   middle click  open the sounds folder
//
// The panel is a thin front end over the `omarchy-sounds` CLI: it reads state
// with `omarchy-sounds json` and changes it with the same commands you'd type,
// so the bar, the CLI and ~/.config/omarchy-sounds/config never disagree. The
// event list itself (names, groups, icons) comes from events.tsv via that JSON,
// so new events show up here without touching this file.
Panel {
  id: root
  moduleName: "tomg.sounds"
  ipcTarget: "tomg.sounds"
  // manageIpc: false so this panel can own the single IpcHandler the target
  // permits — needed for the toggleSounds method below.
  manageIpc: false

  readonly property string configDir: (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")) + "/omarchy-sounds"

  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(fg, 1.4)
  readonly property string fontFamily: bar && bar.fontFamily !== "" ? bar.fontFamily : Style.font.family

  property bool installed: false
  property bool soundsOn: true
  property real volume: 0.6
  property string soundsDir: configDir + "/sounds"

  // [{ id, label, hint, group, icon, enabled, file }] in events.tsv order
  property var events: []

  // Consecutive events sharing a group become one section.
  readonly property var groups: {
    var out = []
    for (var i = 0; i < events.length; i++) {
      var ev = events[i]
      if (out.length === 0 || out[out.length - 1].name !== ev.group) out.push({ name: ev.group, items: [] })
      out[out.length - 1].items.push({ index: i, ev: ev })
    }
    return out
  }

  readonly property int loadedCount: {
    var n = 0
    for (var i = 0; i < events.length; i++) if (events[i].file) n++
    return n
  }

  readonly property string heroStatusText: {
    if (!installed) return "Not set up"
    if (!soundsOn) return "Muted"
    if (loadedCount === 0) return "No sounds added yet"
    return loadedCount + " of " + events.length + " sounds added"
  }
  readonly property string toggleHint: soundsOn ? "Turn sounds off" : "Turn sounds on"

  // Keyboard cursor: 0 = header switch, 1 = volume, then one slot per event
  // (in list order), then the folder button.
  property bool cursorActive: false
  property int cursorIndex: 0
  readonly property int volumeIndex: 1
  readonly property int eventBase: 2
  readonly property int folderIndex: eventBase + events.length
  readonly property bool headerHasCursor: cursorActive && cursorIndex === 0

  function eventAt(i) { return i >= 0 && i < events.length ? events[i] : null }

  function findEvent(id) {
    for (var i = 0; i < events.length; i++) if (events[i].id === id) return events[i]
    return null
  }

  // ---------- Reading state ----------

  property int stateGeneration: 0
  property int statusGeneration: 0
  property bool statusBusy: false
  property bool refreshPending: false
  property string errorText: ""

  function refresh() {
    refreshPending = true
    if (!installed || statusBusy || writeBusy || writeQueue.length > 0) return
    refreshPending = false
    statusGeneration = stateGeneration
    statusBusy = true
    statusProc.running = true
  }

  function finishStatus(exitCode, exitStatus) {
    if (!statusBusy) return
    statusBusy = false
    if (statusGeneration === stateGeneration) {
      if (exitCode !== 0 || exitStatus !== 0)
        errorText = "Could not read sounds settings. " + statusErrors.text.trim()
      else applyStatus(statusOutput.text)
    }
    if (refreshPending) refresh()
  }

  function applyStatus(raw) {
    if (statusGeneration !== stateGeneration || writeBusy || writeQueue.length > 0) return
    var data
    try {
      data = JSON.parse(raw)
      if (!data || typeof data.enabled !== "boolean" || !Array.isArray(data.events)
          || typeof data.volume !== "number" || !Number.isFinite(data.volume) || data.volume < 0 || data.volume > 1)
        throw new Error("Invalid settings")
    } catch (e) { errorText = "Could not read sounds settings: invalid response."; return }
    soundsOn = data.enabled === true
    if (!volumeSlider.dragging) volume = Number(data.volume)
    if (data.dir) soundsDir = data.dir
    var next = []
    for (var i = 0; i < (data.events || []).length; i++) {
      var ev = data.events[i]
      next.push({
        id: ev.id,
        label: ev.label || ev.id,
        hint: ev.hint || "",
        group: ev.group || "Other",
        icon: parseInt(ev.icon || "f075a", 16),
        enabled: ev.enabled === true,
        file: ev.file || ""
      })
    }
    events = next
    if (!writeFailed) errorText = ""
  }

  // ---------- Changing state ----------
  // Writes go through a queue so quick clicks can't race each other on the
  // config file. Each change is applied to the UI straight away and confirmed
  // by the refresh that follows the write.

  property var writeQueue: []
  property bool writeBusy: false
  property bool writeFailed: false
  property bool previewRequested: false

  function write(args) {
    if (!installed) return
    if (!writeBusy && writeQueue.length === 0) { writeFailed = false; errorText = "" }
    stateGeneration++
    refreshPending = true
    volumePreview.stop()
    if (args[0] === "volume") writeQueue = writeQueue.filter(function(command) { return command[0] !== "volume" })
    writeQueue = writeQueue.concat([args])
    pumpWrites()
  }

  function pumpWrites() {
    if (writeBusy || writeQueue.length === 0) return
    writeProc.command = ["omarchy-sounds"].concat(writeQueue[0])
    writeQueue = writeQueue.slice(1)
    writeBusy = true
    writeProc.running = true
  }

  function finishWrite(exitCode, exitStatus) {
    if (!writeBusy) return
    writeBusy = false
    if (exitCode !== 0 || exitStatus !== 0) {
      writeFailed = true
      previewRequested = false
      errorText = "Could not save sounds settings. " + writeErrors.text.trim()
    }
    if (writeQueue.length > 0) pumpWrites()
    else {
      if (previewRequested && !writeFailed) volumePreview.restart()
      refresh()
    }
  }

  function flushVolumePreview() {
    if (!installed || writeBusy || writeQueue.length > 0 || writeFailed || !previewRequested) return
    previewRequested = false
    previewVolume()
  }

  function setSoundsOn(on) {
    if (!installed) return
    soundsOn = on
    write([on ? "on" : "off"])
  }

  function toggleSounds() { setSoundsOn(!soundsOn) }

  function toggleEvent(id) {
    if (!installed || !findEvent(id)) return
    var next = []
    var on = false
    for (var i = 0; i < events.length; i++) {
      var ev = events[i]
      if (ev.id === id) {
        on = !ev.enabled
        ev = Object.assign({}, ev, { enabled: on })
      }
      next.push(ev)
    }
    events = next
    write([on ? "enable" : "disable", id])
  }

  function setVolume(v) {
    if (!installed || !Number.isFinite(v)) return
    v = Math.round(Math.max(0, Math.min(1, v)) * 20) / 20
    volume = v
    previewRequested = true
    write(["volume", v.toFixed(2)])
  }

  function preview(id) {
    var ev = findEvent(id)
    if (ev && ev.file) Util.execArgv(["omarchy-sounds-play", "--force", id])
  }

  // Volume changes preview the click sound (short, and what you'll hear most),
  // falling back to whichever sound has a file.
  function previewVolume() {
    var click = findEvent("click")
    if (click && click.file) { preview("click"); return }
    for (var i = 0; i < events.length; i++) {
      if (events[i].file) { preview(events[i].id); return }
    }
  }

  function openFolder() {
    Util.execArgv(["bash", "-c", 'mkdir -p "$1" && exec xdg-open "$1"', "bash", soundsDir])
    close()
  }

  // ---------- Keyboard ----------

  function moveCursor(delta) {
    cursorIndex = Math.max(0, Math.min(folderIndex, cursorIndex + delta))
  }

  function moveCursorH(delta) {
    if (cursorIndex === volumeIndex) setVolume(volume + delta * 0.05)
  }

  function activateCursor() {
    if (cursorIndex === 0) toggleSounds()
    else if (cursorIndex === volumeIndex) previewVolume()
    else if (cursorIndex === folderIndex) openFolder()
    else {
      var ev = eventAt(cursorIndex - eventBase)
      if (ev) toggleEvent(ev.id)
    }
  }

  function previewCursor() {
    var ev = eventAt(cursorIndex - eventBase)
    if (ev) preview(ev.id)
    else if (cursorIndex === volumeIndex) previewVolume()
  }

  // Scroll the list so the item under the keyboard cursor is on screen.
  function ensureVisible(item) {
    if (!item || !panelFlick.interactive) return
    var top = item.mapToItem(column, 0, 0).y
    var bottom = top + item.height
    var pad = Style.space(8)
    if (top < panelFlick.contentY) panelFlick.contentY = Math.max(0, top - pad)
    else if (bottom > panelFlick.contentY + panelFlick.height)
      panelFlick.contentY = Math.min(panelFlick.contentHeight - panelFlick.height, bottom - panelFlick.height + pad)
  }

  IpcHandler {
    target: "tomg.sounds"

    function open() { root.open() }
    function close() { root.close() }
    function show() { root.open() }
    function hide() { root.close() }
    function toggle() { root.toggle() }
    function toggleSounds() { root.toggleSounds() }
  }

  onOpenedChanged: {
    if (opened) {
      refresh()
      cursorActive = false
      cursorIndex = 0
      panelFlick.contentY = 0
    }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // The config file exists once install.sh has run; its changes (from this
  // panel or the CLI) trigger a refresh.
  FileView {
    path: root.configDir + "/config"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: { root.installed = true; root.refresh() }
    onLoadFailed: root.installed = false
  }

  Process {
    id: statusProc
    command: ["omarchy-sounds", "json"]
    stdout: StdioCollector { id: statusOutput; waitForEnd: true }
    stderr: StdioCollector { id: statusErrors; waitForEnd: true }
    onExited: function(code, status) { root.finishStatus(code, status) }
    // Process exposes no failedToStart signal. A failed launch only changes
    // running; defer so an ordinary exit can complete through onExited first.
    onRunningChanged: if (!running) Qt.callLater(function() {
      if (root.statusBusy && !statusProc.running) root.finishStatus(-1, 1)
    })
  }

  Process {
    id: writeProc
    stderr: StdioCollector { id: writeErrors; waitForEnd: true }
    onExited: function(code, status) { root.finishWrite(code, status) }
    onRunningChanged: if (!running) Qt.callLater(function() {
      if (root.writeBusy && !writeProc.running) root.finishWrite(-1, 1)
    })
  }

  Timer { id: volumePreview; interval: 180; onTriggered: root.flushVolumePreview() }

  // Native file notifications also catch renames that leave the count alone.
  FolderListModel {
    id: soundFiles
    folder: Util.fileUrl(root.soundsDir)
    showDirs: false
  }
  Connections {
    target: soundFiles
    function onRowsInserted() { directoryRefresh.restart() }
    function onRowsRemoved() { directoryRefresh.restart() }
    function onDataChanged() { directoryRefresh.restart() }
    function onModelReset() { directoryRefresh.restart() }
  }
  Timer { id: directoryRefresh; interval: 100; onTriggered: root.refresh() }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: String.fromCodePoint(root.soundsOn ? 0xF075A : 0xF075B)
    dimmed: !root.installed
    tooltipText: ""
    onPressed: function(b) {
      if (b === Qt.RightButton) root.toggleSounds()
      else if (b === Qt.MiddleButton) root.openFolder()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(640))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (dy !== 0) root.moveCursor(dy)
        else if (dx !== 0) root.moveCursorH(dx)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "s" || t === "S" || t === "m" || t === "M") root.toggleSounds()
        else if ((t === "p" || t === "P") && root.cursorActive) root.previewCursor()
        else if (t === "o" || t === "O") root.openFolder()
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width - (panelFlick.interactive ? Style.space(10) : 0)
          spacing: Style.space(14)

          // ---------- Hero: note icon · title/status · master switch ----------
          Item {
            id: hero
            width: parent.width
            implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, powerSwitch.implicitHeight)

            // Status only — the switch owns toggling, mouse and keyboard alike.
            Text {
              id: heroIcon
              textFormat: Text.PlainText
              text: String.fromCodePoint(root.soundsOn ? 0xF075A : 0xF075B)
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
              opacity: root.soundsOn && root.installed ? 1.0 : 0.5
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            // Compact on/off switch on the trailing edge of the hero, and the
            // header's only cursor target.
            ToggleSwitch {
              id: powerSwitch
              visible: root.installed
              checked: root.soundsOn
              hasCursor: root.headerHasCursor
              onHasCursorChanged: if (hasCursor) root.ensureVisible(hero)
              foreground: root.fg
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              onHovered: function(on) { if (on) { root.cursorActive = true; root.cursorIndex = 0 } }
              onToggled: root.toggleSounds()

              PanelToolTip {
                visible: powerSwitch.containsMouse
                text: root.toggleHint
                fontFamily: root.fontFamily
              }
            }

            Column {
              id: heroLabels
              anchors.left: heroIcon.right
              anchors.leftMargin: Style.space(14)
              anchors.right: parent.right
              anchors.rightMargin: powerSwitch.visible ? powerSwitch.width + Style.space(12) : 0
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                text: "Sounds"
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
                elide: Text.ElideRight
                width: parent.width
              }

              Text {
                textFormat: Text.PlainText
                text: root.heroStatusText.toUpperCase()
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.2
                elide: Text.ElideRight
                width: parent.width
              }
            }
          }

          Text {
            visible: !root.installed
            width: parent.width
            textFormat: Text.PlainText
            text: "Run install.sh from the omarchy-sounds folder to set up the sound hooks."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Text {
            visible: root.errorText !== ""
            width: parent.width
            textFormat: Text.PlainText
            text: root.errorText
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          // ---------- Volume ----------
          PanelSeparator {
            visible: root.installed
            foreground: root.fg
          }

          Column {
            visible: root.installed
            width: parent.width
            spacing: Style.space(10)

            Item {
              width: parent.width
              implicitHeight: Math.max(volumeHeader.implicitHeight, volumePercent.implicitHeight)

              PanelSectionHeader {
                id: volumeHeader
                text: "VOLUME"
                foreground: root.fg
                fontFamily: root.fontFamily
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: volumePercent
                textFormat: Text.PlainText
                text: Math.round((volumeSlider.dragging ? volumeSlider.liveValue : root.volume) * 100) + "%"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                anchors.right: parent.right
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            CursorSurface {
              id: volumeRow
              width: parent.width
              height: volumeSlider.implicitHeight + Style.spacing.controlGap
              hasCursor: root.cursorActive && root.cursorIndex === root.volumeIndex
              onHasCursorChanged: if (hasCursor) root.ensureVisible(volumeRow)
              foreground: root.fg
              outline: true
              opacity: root.soundsOn ? 1.0 : 0.5

              PanelSlider {
                id: volumeSlider
                bar: root.bar
                anchors.fill: parent
                anchors.leftMargin: Style.space(6)
                anchors.rightMargin: Style.space(6)
                minimum: 0
                maximum: 1
                step: 0.05
                value: root.volume
                onReleased: function(v) { root.setVolume(v) }
              }

              HoverHandler {
                onHoveredChanged: if (hovered) { root.cursorActive = true; root.cursorIndex = root.volumeIndex }
              }
            }
          }

          // ---------- Events, one section per group ----------
          Repeater {
            model: root.installed ? root.groups : []

            Column {
              id: section
              required property var modelData
              width: column.width
              spacing: Style.space(4)

              PanelSeparator {
                width: parent.width
                foreground: root.fg
              }

              Item { width: 1; height: Style.space(10) }

              PanelSectionHeader {
                text: section.modelData.name.toUpperCase()
                foreground: root.fg
                fontFamily: root.fontFamily
                bottomPadding: Style.space(6)
              }

              Repeater {
                model: section.modelData.items
                EventRow {
                  required property var modelData
                  width: section.width
                  ev: modelData.ev
                  slot: root.eventBase + modelData.index
                }
              }
            }
          }

          // ---------- Sounds folder ----------
          PanelSeparator {
            visible: root.installed
            foreground: root.fg
          }

          Column {
            visible: root.installed
            width: parent.width
            spacing: Style.space(8)

            Button {
              id: folderButton
              width: parent.width
              iconText: String.fromCodePoint(0xF1359)
              text: "Open sounds folder"
              foreground: root.fg
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              bordered: true
              hasCursor: root.cursorActive && root.cursorIndex === root.folderIndex
              onHasCursorChanged: if (hasCursor) root.ensureVisible(folderButton)
              onClicked: root.openFolder()
              onHovered: function(h) { if (h) { root.cursorActive = true; root.cursorIndex = root.folderIndex } }
            }

            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: "Name each file after its event, as shown in each empty row (e.g. window-open.wav). .wav .ogg .flac and .mp3 all work."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
              horizontalAlignment: Text.AlignHCenter
            }
          }
        }
      }
    }
  }

  // One event: icon · name + file · preview button · switch. Clicking the row
  // flips the switch; the play button previews the sound even when it's off.
  component EventRow: CursorSurface {
    id: row
    property var ev: ({})
    property int slot: 0

    readonly property bool hasFile: !!ev.file

    hasCursor: root.cursorActive && root.cursorIndex === slot
    onHasCursorChanged: if (hasCursor) root.ensureVisible(row)
    foreground: root.fg
    implicitHeight: rowContent.implicitHeight + Style.spacing.rowPaddingX
    opacity: root.soundsOn ? 1.0 : 0.5

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onContainsMouseChanged: if (containsMouse) { root.cursorActive = true; root.cursorIndex = row.slot }
      onClicked: root.toggleEvent(row.ev.id)
    }

    Item {
      id: rowContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      implicitHeight: Math.max(eventIcon.implicitHeight, info.implicitHeight, rowSwitch.implicitHeight)

      Text {
        id: eventIcon
        textFormat: Text.PlainText
        text: String.fromCodePoint(row.ev.icon || 0xF075A)
        color: row.ev.enabled ? root.fg : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.heading
        width: Style.space(22)
        horizontalAlignment: Text.AlignHCenter
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
      }

      Column {
        id: info
        spacing: Style.space(1)
        anchors.left: eventIcon.right
        anchors.leftMargin: Style.space(10)
        anchors.right: playButton.left
        anchors.rightMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter

        Text {
          textFormat: Text.PlainText
          text: row.ev.label || ""
          color: row.ev.enabled ? root.fg : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
          width: parent.width
        }

        Text {
          textFormat: Text.PlainText
          text: row.hasFile ? row.ev.file : row.ev.id + ".wav · " + row.ev.hint
          color: Qt.darker(root.fg, 1.5)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
          width: parent.width
        }
      }

      PanelActionButton {
        id: playButton
        iconText: String.fromCodePoint(0xF040A)
        tooltipText: row.hasFile ? "Preview" : "Add " + row.ev.id + ".wav to the sounds folder"
        enabled: row.hasFile
        foreground: root.fg
        fontFamily: root.fontFamily
        anchors.right: rowSwitch.left
        anchors.rightMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        onClicked: root.preview(row.ev.id)
      }

      // The row owns the click, so the switch is presentation only here.
      ToggleSwitch {
        id: rowSwitch
        checked: !!row.ev.enabled
        interactive: false
        foreground: root.fg
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
      }
    }
  }
}
