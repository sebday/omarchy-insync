import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "evo.insync"
  ipcTarget: "evo.insync"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color accent: Color.accent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property string statusScript: Qt.resolvedUrl("bin/insync-status").toString().replace("file://", "")
  readonly property string toggleHint: root.data && root.data.paused ? "Resume syncing" : "Pause syncing"
  readonly property int pollMs: 2000
  readonly property int maxFiles: 5

  property bool loading: true
  property bool filesLoading: false
  property var data: Model.emptyData()

  readonly property bool iconActive: Model.iconActive(data, loading)
  readonly property bool warningState: Model.hasWarning(data)
  readonly property bool iconError: warningState || !!(data && data.error)
  readonly property bool iconBusy: iconActive
  readonly property bool iconMuted: !loading && ((data && data.paused) || Model.isUnavailable(data))
  readonly property string barTooltip: Model.barTooltip(data, loading)
  readonly property string statusLine: Model.heroMeta(data, loading)
  readonly property color statusLineColor: Model.statusLineColor(data, loading, accent, urgent, foreground)
  readonly property var displayFiles: Array.isArray(data && data.files) ? data.files.slice(0, maxFiles) : []
  readonly property var displayAccounts: Array.isArray(data && data.accounts) ? data.accounts : []
  readonly property var displayErrors: Array.isArray(data && data.errors) ? data.errors : []

  function applyAccountFields(parsed) {
    if (!parsed || typeof parsed !== "object") return
    var current = data && typeof data === "object" ? data : Model.emptyData()
    data = {
      ok: parsed.ok === true,
      error: String(parsed.error || ""),
      status: String(parsed.status || ""),
      paused: parsed.paused === true,
      accounts: Array.isArray(parsed.accounts) ? parsed.accounts : [],
      files: parsed.paused === true ? [] : (Array.isArray(current.files) ? current.files : []),
      errors: Array.isArray(parsed.errors) ? parsed.errors : []
    }
    loading = false
  }

  function applyFiles(parsed) {
    if (!parsed || typeof parsed !== "object") return
    var current = data && typeof data === "object" ? data : Model.emptyData()
    data = {
      ok: parsed.ok === true,
      error: String(parsed.error || ""),
      status: String(parsed.status || ""),
      paused: parsed.paused === true,
      accounts: Array.isArray(parsed.accounts) ? parsed.accounts : (Array.isArray(current.accounts) ? current.accounts : []),
      files: Array.isArray(parsed.files) ? parsed.files : [],
      errors: Array.isArray(parsed.errors) ? parsed.errors : []
    }
    filesLoading = false
  }

  function applyPayload(raw, fromCache) {
    var parsed = Model.parsePayload(raw)
    if (fromCache) {
      applyAccountFields(parsed)
      filesLoading = false
      return
    }
    applyAccountFields(parsed)
    applyFiles(parsed)
    loading = false
  }

  function bootstrapFromCache() {
    if (!statusScript || cacheProc.running) return
    cacheProc.command = ["bash", statusScript, "account-cache"]
    cacheProc.running = true
  }

  function refresh(showFilesSpinner) {
    if (!statusScript || statusProc.running) return
    if (!data.ok && displayAccounts.length === 0) loading = true
    var wantFiles = showFilesSpinner === true && !(data && data.paused)
    if (wantFiles) filesLoading = true
    else filesLoading = false
    statusProc.command = ["bash", statusScript, "popup"]
    statusProc.running = true
  }

  function runAction(subcmd) {
    if (actionProc.running) return
    actionProc.command = ["bash", statusScript, subcmd]
    actionProc.running = true
  }

  function togglePaused() {
    if (actionProc.running) return
    var current = data && typeof data === "object" ? data : Model.emptyData()
    var wasPaused = current.paused === true
    data = {
      ok: current.ok,
      error: current.error,
      status: current.status,
      paused: !wasPaused,
      accounts: Array.isArray(current.accounts) ? current.accounts : [],
      files: [],
      errors: Array.isArray(current.errors) ? current.errors : []
    }
    root.runAction(wasPaused ? "resume" : "pause")
  }

  function showFloating() {
    if (!statusScript) return
    Quickshell.execDetached(["bash", statusScript, "show"])
  }

  function openFromHotkey() {
    root.controller.show()
    root.refresh(!(data && data.paused))
  }

  function toggle() {
    if (root.opened) root.close()
    else root.openFromHotkey()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  Component.onCompleted: {
    bootstrapFromCache()
    refresh(false)
  }

  onOpenedChanged: {
    if (opened) {
      refresh(!(data && data.paused))
      pollTimer.start()
      Qt.callLater(function() { keyCatcher.forceActiveFocus() })
    } else {
      pollTimer.stop()
      filesLoading = false
    }
  }

  Process {
    id: cacheProc
    onStarted: { stdoutBuf = ""; stderrBuf = "" }

    property string stdoutBuf: ""
    property string stderrBuf: ""
    stdout: SplitParser {
      splitMarker: ""
      onRead: function(chunk) {
        cacheProc.stdoutBuf += chunk
        if (cacheProc.stdoutBuf.length > 262144) {
          cacheProc.signal(15)
          cacheProc.stdoutBuf = ""
        }
      }
    }
    stderr: SplitParser {
      splitMarker: ""
      onRead: function(chunk) {
        cacheProc.stderrBuf += chunk
        if (cacheProc.stderrBuf.length > 4096) {
          cacheProc.signal(15)
          cacheProc.stderrBuf = ""
        }
      }
    }
      onExited: function(exitCode) {
      var raw = String(stdoutBuf || "").trim()
        if (!raw) return
        root.applyPayload(raw, true)
    }
  }

  Process {
    id: statusProc
    onStarted: { stdoutBuf = ""; stderrBuf = "" }

    property string stdoutBuf: ""
    property string stderrBuf: ""
    stdout: SplitParser {
      splitMarker: ""
      onRead: function(chunk) {
        statusProc.stdoutBuf += chunk
        if (statusProc.stdoutBuf.length > 262144) {
          statusProc.signal(15)
          statusProc.stdoutBuf = ""
        }
      }
    }
    stderr: SplitParser {
      splitMarker: ""
      onRead: function(chunk) {
        statusProc.stderrBuf += chunk
        if (statusProc.stderrBuf.length > 4096) {
          statusProc.signal(15)
          statusProc.stderrBuf = ""
        }
      }
    }
    onExited: {
      var raw = String(stdoutBuf || "").trim()
        if (!raw) {
          root.loading = false
          root.filesLoading = false
          return
        }
        root.applyPayload(raw, false)

      root.loading = false
      root.filesLoading = false
    }
  }

  Process {
    id: actionProc
    onExited: root.refresh(false)
  }

  Timer {
    id: pollTimer
    interval: root.pollMs
    repeat: true
    onTriggered: root.refresh(false)
  }

  IpcHandler {
    target: root.ipcTarget

    function open(): void { root.openFromHotkey() }
    function close(): void { root.close() }
    function show(): void { root.openFromHotkey() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refresh(false); return "ok" }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(520))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

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
          width: panelFlick.width
          spacing: Style.space(12)

          PanelHero {
            id: hero
            width: parent.width
            title: "Insync"
            meta: root.statusLine
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconOpacity: !root.data.paused ? (root.iconActive ? 1 : 0.7) : 0.5

            iconComponent: Component {
              Text {
                textFormat: Text.PlainText
                text: "󰋼"
                color: root.statusLineColor
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
                opacity: 0.92
              }
            }

            trailingControl: Component {
              ToggleSwitch {
                id: pauseSwitch
                checked: !root.data.paused
                busy: actionProc.running
                foreground: hero.foreground
                onToggled: root.togglePaused()

                PanelToolTip {
                  visible: pauseSwitch.containsMouse
                  text: root.toggleHint
                  fontFamily: hero.fontFamily
                }
              }
            }
          }

          PanelSeparator {
            visible: root.displayAccounts.length > 0
            foreground: root.foreground
          }

          PanelSectionHeader {
            visible: root.displayAccounts.length > 0
            width: parent.width
            text: "ACCOUNTS"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Repeater {
            model: root.displayAccounts

            AccountRow {
              required property var modelData
              width: column.width
              account: modelData
            }
          }

          PanelSeparator {
            visible: !root.data.paused && (root.displayFiles.length > 0 || root.filesLoading
              || (!root.loading && root.displayErrors.length === 0 && !(root.data && root.data.error)))
            foreground: root.foreground
          }

          PanelSectionHeader {
            visible: !root.data.paused && (root.displayFiles.length > 0 || root.filesLoading
              || (!root.loading && root.displayErrors.length === 0 && !(root.data && root.data.error)))
            width: parent.width
            text: "FILES"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Item {
            width: parent.width
            height: 56
            visible: !root.data.paused && root.filesLoading && root.displayFiles.length === 0

            Text {
              textFormat: Text.PlainText
              anchors.centerIn: parent
              text: "󰇘"
              color: root.accent
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              opacity: 0.85
              transformOrigin: Item.Center

              RotationAnimation on rotation {
                running: root.filesLoading && root.displayFiles.length === 0
                from: 0
                to: 360
                duration: 900
                loops: Animation.Infinite
              }
            }
          }

          Repeater {
            model: root.displayFiles

            FileRow {
              required property var modelData
              width: column.width
              file: modelData
            }
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            visible: !root.data.paused && !root.loading && root.displayFiles.length === 0 && !root.filesLoading
            text: Model.emptyFilesMessage(root.data, root.loading)
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            horizontalAlignment: Text.AlignHCenter
          }

          PanelSeparator {
            visible: root.displayErrors.length > 0
            foreground: root.foreground
          }

          PanelSectionHeader {
            visible: root.displayErrors.length > 0
            width: parent.width
            text: "ERRORS"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Repeater {
            model: root.displayErrors

            Text {
              textFormat: Text.PlainText
              required property var modelData
              width: column.width
              text: String(modelData)
              color: root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            visible: String(root.data && root.data.error ? root.data.error : "") !== "" && root.displayErrors.length === 0
            text: root.data && root.data.error ? String(root.data.error) : ""
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            wrapMode: Text.WordWrap
          }
        }
      }
    }
  }

  component AccountRow: Row {
    property var account: null
    spacing: Style.spacing.sm
    width: parent.width

    Item {
      id: iconSlot
      width: details.height
      height: details.height

      Text {
        textFormat: Text.PlainText
        anchors.centerIn: parent
        text: Model.providerIcon(account ? account.provider : "")
        color: root.foreground
        opacity: 0.72
        font.family: root.fontFamily
        font.pixelSize: Math.round(parent.height * 0.78)
      }
    }

    Column {
      id: details
      width: parent.width - iconSlot.width - parent.spacing
      spacing: Style.spacing.labelGap

      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: String(account && account.email ? account.email : "")
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: true
        elide: Text.ElideRight
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: String(account && account.provider ? account.provider : "Account")
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }
  }

  component FileRow: Column {
    property var file: null
    spacing: Style.spacing.labelGap
    width: parent.width

    Text {
      textFormat: Text.PlainText
      width: parent.width
      text: Model.basename(file ? file.path : "")
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      font.bold: true
      elide: Text.ElideRight
    }

    Text {
      textFormat: Text.PlainText
      width: parent.width
      text: Model.fileDetail(file)
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
    }

    Item {
      width: parent.width
      height: 4
      visible: file && Number(file.total || 0) > 0

      Rectangle {
        anchors.fill: parent
        radius: 2
        color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)
      }

      Rectangle {
        height: parent.height
        width: parent.width * Math.max(0, Math.min(1, Number(file ? file.percent : 0) / 100))
        radius: 2
        color: root.accent
      }
    }
  }

}
