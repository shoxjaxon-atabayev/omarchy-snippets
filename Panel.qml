import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import "SnippetStore.js" as SnippetStore

// Snippets (bar icon): save Name+Content text snippets locally and copy them
// back with one click. See docs/snippet-manager.md for the full spec. All
// mutation goes through the bin/omarchy-snippets-* CLI, never straight to
// snippets.json from here -- see that doc's storage section for why
// (permission preservation across the store's atomic writes).
//
// The four views (list/form/delete-confirm/import-preview) are one flat set
// of visibility-toggled siblings inside KeyboardPanel, not a Loader over
// per-view Components: a Component introduces its own id scope, which would
// make root-level functions like searchField.forceActiveFocus() unable to
// see ids declared inside it, and KeyboardPanel's default content property
// is typed list<Item> anyway (a bare Component isn't an Item). Audio/
// Bluetooth/Network all use this same flat-tree-with-visible-bindings shape.
Panel {
  id: root
  moduleName: "community.shoxjaxon.snippets"
  ipcTarget: "community.shoxjaxon.snippets"

  property var snippets: []
  // "list" | "form" | "delete-confirm" | "import-preview"
  property string view: "list"
  property string filterText: ""
  property int selectedIndex: -1

  property string editingId: ""
  property string formName: ""
  property string formContent: ""
  property string formError: ""
  property bool formSaving: false

  property string deleteId: ""
  property string deleteName: ""

  property string importFilePath: ""
  property var importConflicts: []
  property int importNewCount: 0
  property var importResolutions: ({})
  property string importError: ""
  property bool importBusy: false

  // Set right before reopenPanel() calls root.open() after the import/export
  // file-picker flow closed the panel, so onOpenedChanged's normal
  // reset-to-list behavior doesn't stomp the view reopenPanel just set.
  property bool suppressNextOpenReset: false

  readonly property var rows: SnippetStore.displayRows(root.snippets, root.filterText)
  readonly property color foreground: Color.popups.text
  readonly property color background: Color.popups.background
  readonly property color borderColor: Color.popups.border
  readonly property string fontFamily: Style.font.family

  // Third-party plugins are not installed into core bin/ and are not on
  // PATH, so the bundled CLI scripts have to be addressed by an absolute
  // path resolved relative to this file, the same way sibling QML/assets are
  // already resolved elsewhere in Omarchy (e.g. Qt.resolvedUrl("Panel.qml"),
  // Qt.resolvedUrl("assets/...")) -- just applied to a plain executable
  // instead of a QML/image resource.
  readonly property string binDir: Qt.resolvedUrl("bin/").toString().replace("file://", "")

  function binPath(name) {
    return root.binDir + name
  }

  // Reading happens through readProc (bin/omarchy-snippets-read) rather than
  // a FileView pointed at snippets.json directly: that path is predictable
  // and FileView offers no way to require O_NOFOLLOW/O_NONBLOCK, a regular
  // file, our own ownership, or a size cap on what it opens, so a planted
  // symlink/FIFO/oversized file there could block the shell or substitute
  // content. readProc.checkFinished() sets root.snippets once the read
  // comes back, which is why selection/list state that depends on
  // root.snippets is settled there rather than right after loadSnippets().
  function loadSnippets() {
    readProc.running = true
  }

  onOpenedChanged: {
    if (root.opened) {
      if (root.suppressNextOpenReset) {
        root.suppressNextOpenReset = false
      } else {
        root.view = "list"
        root.filterText = ""
      }
      root.loadSnippets()
      Qt.callLater(function() { if (root.opened && root.view === "list") searchField.forceActiveFocus() })
    }
  }

  // Reopens the panel showing `view` after the import/export file-picker
  // flow closed it (see beginImport/beginExport below). If the user already
  // reopened it by hand while that picker/CLI process was still running in
  // the background, onOpenedChanged already ran once and reset the view --
  // this just updates it in place instead of calling open() again, since
  // PanelController.show() is a no-op (and fires no change signal) when
  // already open.
  function reopenPanel(view) {
    root.view = view
    if (view === "list") root.filterText = ""
    if (root.opened) return
    root.suppressNextOpenReset = true
    root.open()
  }

  onFilterTextChanged: {
    root.selectedIndex = root.rows.length > 0 ? 0 : -1
  }

  function moveSelection(delta) {
    if (root.rows.length === 0) { root.selectedIndex = -1; return }
    if (root.selectedIndex < 0) { root.selectedIndex = delta > 0 ? 0 : root.rows.length - 1 }
    else root.selectedIndex = (root.selectedIndex + delta + root.rows.length) % root.rows.length
    resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
  }

  function activateSelected() {
    if (root.selectedIndex < 0 || root.selectedIndex >= root.rows.length) return
    var row = root.rows[root.selectedIndex]
    root.copySnippet(row.id, row.name)
  }

  function copySnippet(id, name) {
    copyProc.pendingName = name
    copyProc.command = [root.binPath("omarchy-snippets-copy"), id]
    copyProc.running = true
  }

  function snippetById(id) {
    for (var i = 0; i < root.snippets.length; i++)
      if (root.snippets[i].id === id) return root.snippets[i]
    return null
  }

  // Row text mixes a dimmed preview into the name via StyledText (see
  // rowLabel below), so anything user-typed has to be escaped first --
  // otherwise a name or content containing "<" or "&" would corrupt the
  // rendered rich text instead of just displaying literally.
  function escapeRowText(text) {
    return String(text || "")
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
  }

  // Qt.darker (not Util.alpha) so the dimmed segment is a plain opaque
  // "#RRGGBB" once stringified into the HTML -- an alpha-inclusive color
  // is not guaranteed to parse in Qt's rich-text color attribute.
  readonly property color rowPreviewColor: Qt.darker(root.foreground, 2.2)

  // The Text item's base `color` (not a span color) is what elide's "…"
  // renders in, so the base has to be the dimmed color and the name gets
  // its own explicit span -- otherwise the ellipsis stays white no matter
  // what color the text it's replacing was.
  function rowLabel(name, preview) {
    var label = "<font color=\"" + root.foreground + "\">" + escapeRowText(name) + "</font>"
    if (preview) label += "&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;" + escapeRowText(preview)
    return label
  }

  // ---- form (create/edit) -------------------------------------------------

  function beginCreate() {
    root.editingId = ""
    root.formName = ""
    root.formContent = ""
    root.formError = ""
    root.view = "form"
    Qt.callLater(function() { nameField.forceActiveFocus() })
  }

  function beginEdit(id) {
    var snippet = root.snippetById(id)
    if (!snippet) return
    root.editingId = id
    root.formName = snippet.name
    root.formContent = snippet.content
    root.formError = ""
    root.view = "form"
    Qt.callLater(function() { nameField.forceActiveFocus() })
  }

  function cancelForm() {
    root.view = "list"
    Qt.callLater(function() { searchField.forceActiveFocus() })
  }

  function saveForm() {
    if (SnippetStore.blank(root.formName)) { root.formError = "A snippet needs a name."; return }
    if (SnippetStore.blank(root.formContent)) { root.formError = "A snippet needs content."; return }
    root.formError = ""
    root.formSaving = true
    var payload = JSON.stringify({ id: root.editingId, name: root.formName, content: root.formContent })
    saveProc.command = [root.binPath("omarchy-snippets-save"), payload]
    saveProc.running = true
  }

  function onSaveFinished(exitCode, errorText) {
    root.formSaving = false
    if (exitCode !== 0) {
      root.formError = errorText.trim() || "Could not save snippet."
      return
    }
    root.loadSnippets()
    root.view = "list"
    root.filterText = ""
    Qt.callLater(function() { searchField.forceActiveFocus() })
  }

  // ---- delete ---------------------------------------------------------

  function beginDelete(id) {
    var snippet = root.snippetById(id)
    if (!snippet) return
    root.deleteId = id
    root.deleteName = snippet.name
    root.view = "delete-confirm"
  }

  function cancelDelete() {
    root.view = "list"
    Qt.callLater(function() { searchField.forceActiveFocus() })
  }

  function confirmDelete() {
    deleteProc.command = [root.binPath("omarchy-snippets-delete"), root.deleteId]
    deleteProc.running = true
  }

  function onDeleteFinished() {
    root.loadSnippets()
    root.view = "list"
    Qt.callLater(function() { searchField.forceActiveFocus() })
  }

  // ---- import / export -------------------------------------------------

  // Both begin* functions close the panel before the desktop portal's file
  // chooser opens: this panel is a full-screen, always-on-top layer-shell
  // surface with a screen-wide click-catching overlay (see
  // KeyboardPanel.qml's dismissArea) whenever it's open, which can sit above
  // and swallow input meant for a separate top-level picker window. Closing
  // it first hands the compositor back to the picker cleanly; reopenPanel()
  // (used by every completion path below) brings the panel back once the
  // picker (and, for import, the preview) has a result to show.
  function beginExport() {
    root.close()
    exportPickProc.command = [root.binPath("omarchy-snippets-file-select"), "--save-as", "snippets.json", "--title", "Export Snippets", "--extensions", "json"]
    exportPickProc.running = true
  }

  function onExportPathPicked(path) {
    if (!path) { root.reopenPanel("list"); return }
    exportProc.command = [root.binPath("omarchy-snippets-export"), path]
    exportProc.running = true
  }

  function beginImport() {
    root.close()
    importPickProc.command = [root.binPath("omarchy-snippets-file-select"), "--title", "Import Snippets", "--extensions", "json"]
    importPickProc.running = true
  }

  function onImportPathPicked(path) {
    if (!path) { root.reopenPanel("list"); return }
    root.importFilePath = path
    root.importBusy = true
    importPreviewProc.command = [root.binPath("omarchy-snippets-import-preview"), path]
    importPreviewProc.running = true
  }

  function onImportPreviewFinished(exitCode, text, errorText) {
    root.importBusy = false
    if (exitCode !== 0) {
      root.importError = errorText.trim() || "Invalid snippet file."
      root.importConflicts = []
      root.importNewCount = 0
      root.reopenPanel("import-preview")
      return
    }
    var parsed = JSON.parse(text)
    root.importError = ""
    root.importConflicts = parsed.conflicts || []
    root.importNewCount = parsed.newCount || 0
    var resolutions = {}
    for (var i = 0; i < root.importConflicts.length; i++) resolutions[root.importConflicts[i].name] = "skip"
    root.importResolutions = resolutions
    root.reopenPanel("import-preview")
  }

  function setImportResolution(name, action) {
    var next = {}
    for (var key in root.importResolutions) next[key] = root.importResolutions[key]
    next[name] = action
    root.importResolutions = next
  }

  function applyImportResolutionToAll(action) {
    var next = {}
    for (var i = 0; i < root.importConflicts.length; i++) next[root.importConflicts[i].name] = action
    root.importResolutions = next
  }

  function cancelImport() {
    root.importFilePath = ""
    root.importError = ""
    root.importConflicts = []
    root.view = "list"
    Qt.callLater(function() { searchField.forceActiveFocus() })
  }

  function confirmImport() {
    var resolutions = []
    for (var name in root.importResolutions) resolutions.push({ name: name, action: root.importResolutions[name] })
    root.importBusy = true
    importApplyProc.command = [root.binPath("omarchy-snippets-import-apply"), root.importFilePath, JSON.stringify(resolutions)]
    importApplyProc.running = true
  }

  function onImportApplyFinished(exitCode, errorText) {
    root.importBusy = false
    if (exitCode !== 0) {
      root.importError = errorText.trim() || "Could not import snippets."
      return
    }
    root.loadSnippets()
    root.cancelImport()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // See loadSnippets() above for why this reads through a CLI helper
  // instead of a FileView. Same completion pattern as every Process below:
  // onExited and the stdout stream can resolve in either order, so state is
  // only acted on once both have reported in via checkFinished().
  Process {
    id: readProc
    property bool exited: false
    property bool stdoutFinished: false
    property int finalExitCode: -1
    property string stdoutText: ""

    command: [root.binPath("omarchy-snippets-read")]

    function checkFinished() {
      if (exited && stdoutFinished) {
        root.snippets = finalExitCode === 0 ? SnippetStore.parseStore(stdoutText) : []
        root.selectedIndex = root.rows.length > 0 ? 0 : -1
      }
    }

    onRunningChanged: {
      if (running) {
        exited = false; stdoutFinished = false;
        finalExitCode = -1; stdoutText = "";
      }
    }

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        readProc.stdoutText = text
        readProc.stdoutFinished = true
        readProc.checkFinished()
      }
    }
    stderr: StdioCollector {}

    onExited: function(exitCode) {
      readProc.finalExitCode = exitCode
      readProc.exited = true
      readProc.checkFinished()
    }
  }

  // copyProc is separate from the detached pattern so the UI can confirm
  // success or surface a failure notification only after the clipboard write
  // completes. pendingName carries the display name through to completion.
  //
  // Reading Process.exitCode from inside a StdioCollector's onStreamFinished
  // is not safe on its own: Quickshell can fire a stream's onStreamFinished
  // before Process.onExited has run, in which case exitCode reads back as
  // undefined (confirmed against Quickshell 0.3.1). Every Process below
  // instead captures the exit code from onExited's own parameter -- which is
  // always correct, ordering aside -- and only acts once both onExited and
  // the stream have reported in, the same checkFinished() gate already used
  // by exportPickProc/importPickProc/importPreviewProc/importApplyProc.
  Process {
    id: copyProc
    property string pendingName: ""
    property bool exited: false
    property bool stderrFinished: false
    property int finalExitCode: -1
    property string stderrText: ""

    function checkFinished() {
      if (exited && stderrFinished) {
        var name = copyProc.pendingName
        if (finalExitCode === 0) {
          root.close()
          Quickshell.execDetached(["omarchy-notification-send", "Copied \"" + name + "\"", "-t", "1500"])
        } else {
          Quickshell.execDetached(["omarchy-notification-send", stderrText.trim() || "Could not copy snippet.", "-u", "critical", "-t", "3000"])
        }
      }
    }

    onRunningChanged: {
      if (running) {
        exited = false; stderrFinished = false;
        finalExitCode = -1; stderrText = "";
      }
    }

    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        copyProc.stderrText = text
        copyProc.stderrFinished = true
        copyProc.checkFinished()
      }
    }

    onExited: function(exitCode) {
      copyProc.finalExitCode = exitCode
      copyProc.exited = true
      copyProc.checkFinished()
    }
  }

  Process {
    id: saveProc
    property bool exited: false
    property bool stderrFinished: false
    property int finalExitCode: -1
    property string stderrText: ""

    function checkFinished() {
      if (exited && stderrFinished) {
        root.onSaveFinished(finalExitCode, stderrText)
      }
    }

    onRunningChanged: {
      if (running) {
        exited = false; stderrFinished = false;
        finalExitCode = -1; stderrText = "";
      }
    }

    stdout: StdioCollector {}
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        saveProc.stderrText = text
        saveProc.stderrFinished = true
        saveProc.checkFinished()
      }
    }

    onExited: function(exitCode) {
      saveProc.finalExitCode = exitCode
      saveProc.exited = true
      saveProc.checkFinished()
    }
  }

  Process {
    id: deleteProc
    property bool exited: false
    property bool stderrFinished: false
    property int finalExitCode: -1
    property string stderrText: ""

    function checkFinished() {
      if (exited && stderrFinished) {
        if (finalExitCode === 0) {
          root.onDeleteFinished()
        } else {
          Quickshell.execDetached(["omarchy-notification-send", stderrText.trim() || "Could not delete snippet.", "-u", "critical", "-t", "3000"])
          root.view = "list"
          Qt.callLater(function() { searchField.forceActiveFocus() })
        }
      }
    }

    onRunningChanged: {
      if (running) {
        exited = false; stderrFinished = false;
        finalExitCode = -1; stderrText = "";
      }
    }

    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        deleteProc.stderrText = text
        deleteProc.stderrFinished = true
        deleteProc.checkFinished()
      }
    }

    onExited: function(exitCode) {
      deleteProc.finalExitCode = exitCode
      deleteProc.exited = true
      deleteProc.checkFinished()
    }
  }

  Process {
    id: exportPickProc
    property bool exited: false
    property bool stdoutFinished: false
    property int finalExitCode: -1
    property string stdoutText: ""

    function checkFinished() {
      if (exited && stdoutFinished) {
        if (finalExitCode === 0) {
          root.onExportPathPicked(stdoutText.trim())
        } else if (finalExitCode !== 1) {
          root.onExportPathPicked("")
          Quickshell.execDetached(["omarchy-notification-send", "File selection failed.", "-u", "critical", "-t", "3000"])
        } else {
          root.onExportPathPicked("")
        }
      }
    }

    onRunningChanged: {
      if (running) {
        exited = false; stdoutFinished = false;
        finalExitCode = -1; stdoutText = "";
      }
    }

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        exportPickProc.stdoutText = text
        exportPickProc.stdoutFinished = true
        exportPickProc.checkFinished()
      }
    }

    onExited: function(exitCode) {
      exportPickProc.finalExitCode = exitCode
      exportPickProc.exited = true
      exportPickProc.checkFinished()
    }
  }

  Process {
    id: exportProc
    property bool exited: false
    property bool stderrFinished: false
    property int finalExitCode: -1
    property string stderrText: ""

    function checkFinished() {
      if (exited && stderrFinished) {
        if (finalExitCode !== 0) {
          Quickshell.execDetached(["omarchy-notification-send", stderrText.trim() || "Export failed.", "-u", "critical", "-t", "3000"])
        }
        root.reopenPanel("list")
      }
    }

    onRunningChanged: {
      if (running) {
        exited = false; stderrFinished = false;
        finalExitCode = -1; stderrText = "";
      }
    }

    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        exportProc.stderrText = text
        exportProc.stderrFinished = true
        exportProc.checkFinished()
      }
    }

    onExited: function(exitCode) {
      exportProc.finalExitCode = exitCode
      exportProc.exited = true
      exportProc.checkFinished()
    }
  }

  Process {
    id: importPickProc
    property bool exited: false
    property bool stdoutFinished: false
    property int finalExitCode: -1
    property string stdoutText: ""

    function checkFinished() {
      if (exited && stdoutFinished) {
        if (finalExitCode === 0) {
          root.onImportPathPicked(stdoutText.trim())
        } else if (finalExitCode !== 1) {
          root.onImportPathPicked("")
          Quickshell.execDetached(["omarchy-notification-send", "File selection failed.", "-u", "critical", "-t", "3000"])
        } else {
          root.onImportPathPicked("")
        }
      }
    }

    onRunningChanged: {
      if (running) {
        exited = false; stdoutFinished = false;
        finalExitCode = -1; stdoutText = "";
      }
    }

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        importPickProc.stdoutText = text
        importPickProc.stdoutFinished = true
        importPickProc.checkFinished()
      }
    }

    onExited: function(exitCode) {
      importPickProc.finalExitCode = exitCode
      importPickProc.exited = true
      importPickProc.checkFinished()
    }
  }

  Process {
    id: importPreviewProc
    property bool exited: false
    property bool stdoutFinished: false
    property bool stderrFinished: false
    property int finalExitCode: -1
    property string stdoutText: ""
    property string stderrText: ""

    function checkFinished() {
      if (exited && stdoutFinished && stderrFinished) {
        root.onImportPreviewFinished(finalExitCode, stdoutText, stderrText)
      }
    }

    onRunningChanged: {
      if (running) {
        exited = false; stdoutFinished = false; stderrFinished = false;
        finalExitCode = -1; stdoutText = ""; stderrText = "";
      }
    }

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        importPreviewProc.stdoutText = text
        importPreviewProc.stdoutFinished = true
        importPreviewProc.checkFinished()
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        importPreviewProc.stderrText = text
        importPreviewProc.stderrFinished = true
        importPreviewProc.checkFinished()
      }
    }
    onExited: function(exitCode) {
      importPreviewProc.finalExitCode = exitCode
      importPreviewProc.exited = true
      importPreviewProc.checkFinished()
    }
  }

  Process {
    id: importApplyProc
    property bool exited: false
    property bool stderrFinished: false
    property int finalExitCode: -1
    property string stderrText: ""

    function checkFinished() {
      if (exited && stderrFinished) {
        root.onImportApplyFinished(finalExitCode, stderrText)
      }
    }

    onRunningChanged: {
      if (running) {
        exited = false; stderrFinished = false;
        finalExitCode = -1; stderrText = "";
      }
    }

    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        importApplyProc.stderrText = text
        importApplyProc.stderrFinished = true
        importApplyProc.checkFinished()
      }
    }

    onExited: function(exitCode) {
      importApplyProc.finalExitCode = exitCode
      importApplyProc.exited = true
      importApplyProc.checkFinished()
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰠮"
    onPressed: root.toggle()
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(
      root.view === "form" ? formColumn.implicitHeight
        : root.view === "delete-confirm" ? deleteConfirmItem.implicitHeight
        : root.view === "import-preview" ? importColumn.implicitHeight
        : listColumn.implicitHeight,
      Style.space(520)
    )

    // ---------------- list ----------------
    Column {
      id: listColumn
      width: parent.width
      visible: root.view === "list"
      spacing: Style.space(8)

      Row {
        width: parent.width
        spacing: Style.space(6)

        TextField {
          id: searchField
          width: parent.width - newButton.width - importButton.width - exportButton.width - Style.space(18)
          placeholderText: "Search snippets…"
          text: root.filterText
          onTextChanged: root.filterText = text
          foreground: root.foreground

          Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Down) { root.moveSelection(1); event.accepted = true }
            else if (event.key === Qt.Key_Up) { root.moveSelection(-1); event.accepted = true }
            else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { root.activateSelected(); event.accepted = true }
            else if (event.key === Qt.Key_F2) {
              if (root.selectedIndex >= 0 && root.selectedIndex < root.rows.length)
                root.beginEdit(root.rows[root.selectedIndex].id)
              event.accepted = true
            } else if (event.key === Qt.Key_Delete) {
              if (root.selectedIndex >= 0 && root.selectedIndex < root.rows.length)
                root.beginDelete(root.rows[root.selectedIndex].id)
              event.accepted = true
            } else if (event.key === Qt.Key_Escape) {
              if (text.length > 0) { text = "" }
              else root.close()
              event.accepted = true
            }
          }
        }

        // Glyphs below are Material Design Icons codepoints from the Nerd
        // Font already used for every icon elsewhere in the shell (e.g. the
        // 󰠮 bar icon above) -- picked instead of plain Unicode symbols so
        // this row reads as one consistent icon set rather than a mismatched
        // one. Import/export deliberately use a matched down/up arrow pair:
        // import brings a file in (down), export sends the store out (up).
        PanelActionButton {
          id: newButton
          iconText: "󰐕" // md-plus
          tooltipText: "New snippet"
          foreground: root.foreground
          focusable: true
          onClicked: root.beginCreate()
        }

        PanelActionButton {
          id: importButton
          iconText: "󰜮" // md-arrow_down_bold
          tooltipText: "Import"
          foreground: root.foreground
          focusable: true
          onClicked: root.beginImport()
        }

        PanelActionButton {
          id: exportButton
          iconText: "󰜷" // md-arrow_up_bold
          tooltipText: "Export"
          foreground: root.foreground
          enabled: root.snippets.length > 0
          focusable: true
          onClicked: root.beginExport()
        }
      }

      Text {
        visible: root.rows.length === 0 && root.snippets.length === 0
        width: parent.width
        text: "No snippets yet.\nSave commands and code you use often."
        color: root.foreground
        opacity: 0.7
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.WordWrap
      }

      Text {
        visible: root.rows.length === 0 && root.snippets.length > 0
        width: parent.width
        text: "No matches for “" + root.filterText + "”"
        textFormat: Text.PlainText
        color: root.foreground
        opacity: 0.7
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        horizontalAlignment: Text.AlignHCenter
      }

      ListView {
        id: resultList
        visible: root.rows.length > 0
        width: parent.width
        height: Math.min(Style.space(320), root.rows.length * Style.space(40))
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        model: root.rows
        spacing: Style.space(2)

        delegate: CursorSurface {
          id: row
          required property var modelData
          required property int index

          width: ListView.view.width
          height: Style.space(36)
          hasCursor: root.selectedIndex === index
          foreground: root.foreground
          currentFill: Util.alpha(root.foreground, 0.08)

          Text {
            anchors.left: parent.left
            anchors.right: rowActions.left
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Style.space(8)
            anchors.rightMargin: Style.space(18)
            textFormat: Text.StyledText
            text: root.rowLabel(row.modelData.name, row.modelData.preview)
            color: root.rowPreviewColor
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            elide: Text.ElideRight
          }

          Row {
            id: rowActions
            anchors.right: parent.right
            anchors.rightMargin: Style.space(6)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)
            visible: row.hasCursor || rowMouse.containsMouse

            // Same Nerd Font MDI set as the row above.
            PanelActionButton {
              iconText: "󰏫" // md-pencil
              tooltipText: "Edit"
              foreground: root.foreground
              size: Style.space(20)
              onClicked: root.beginEdit(row.modelData.id)
            }

            PanelActionButton {
              iconText: "󰩹" // md-trash_can
              tooltipText: "Delete"
              foreground: root.foreground
              hoverColor: Color.urgent
              size: Style.space(20)
              onClicked: root.beginDelete(row.modelData.id)
            }
          }

          MouseArea {
            id: rowMouse
            anchors.fill: parent
            anchors.rightMargin: rowActions.width + Style.space(8)
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onContainsMouseChanged: if (containsMouse) root.selectedIndex = row.index
            onClicked: root.copySnippet(row.modelData.id, row.modelData.name)
          }
        }
      }
    }

    // ---------------- create / edit form ----------------
    Column {
      id: formColumn
      width: parent.width
      visible: root.view === "form"
      spacing: Style.space(10)

      Text {
        text: root.editingId === "" ? "New Snippet" : "Edit Snippet"
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.title
        font.bold: true
      }

      Text {
        text: "Name"
        color: root.foreground
        opacity: 0.7
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      TextField {
        id: nameField
        width: parent.width
        text: root.formName
        onTextChanged: root.formName = text
        foreground: root.foreground
        Keys.onEscapePressed: root.cancelForm()
      }

      Text {
        text: "Content"
        color: root.foreground
        opacity: 0.7
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      Rectangle {
        width: parent.width
        height: Style.space(140)
        radius: Style.cornerRadius
        color: "transparent"
        border.color: Util.alpha(root.foreground, 0.28)
        border.width: Style.normalBorderWidth

        ScrollView {
          anchors.fill: parent
          anchors.margins: Style.space(6)
          clip: true

          TextArea {
            id: contentField
            text: root.formContent
            onTextChanged: root.formContent = text
            wrapMode: TextArea.Wrap
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            background: null
            Keys.onEscapePressed: root.cancelForm()
          }
        }
      }

      Text {
        visible: root.formError.length > 0
        width: parent.width
        text: root.formError
        textFormat: Text.PlainText
        color: Color.urgent
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }

      Row {
        spacing: Style.space(8)
        anchors.right: parent.right

        Button {
          text: "Cancel"
          bordered: true
          foreground: root.foreground
          fontFamily: root.fontFamily
          focusable: true
          onClicked: root.cancelForm()
        }

        Button {
          text: root.formSaving ? "Saving…" : "Save"
          bordered: true
          foreground: root.foreground
          fontFamily: root.fontFamily
          enabled: !root.formSaving
          focusable: true
          onClicked: root.saveForm()
        }
      }
    }

    // ---------------- delete confirm ----------------
    Item {
      id: deleteConfirmItem
      width: parent.width
      implicitHeight: Style.space(140)
      visible: root.view === "delete-confirm"

      ConfirmDialog {
        anchors.fill: parent
        opened: root.view === "delete-confirm"
        message: "Delete \"" + root.deleteName + "\"?"
        confirmText: "Delete"
        background: root.background
        foreground: root.foreground
        fontFamily: root.fontFamily
        onCanceled: root.cancelDelete()
        onConfirmed: root.confirmDelete()
      }
    }

    // ---------------- import preview / conflicts ----------------
    Column {
      id: importColumn
      width: parent.width
      visible: root.view === "import-preview"
      spacing: Style.space(10)

      Text {
        text: "Import Snippets"
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.title
        font.bold: true
      }

      Text {
        visible: root.importError.length > 0
        width: parent.width
        text: root.importError
        color: Color.urgent
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        wrapMode: Text.WordWrap
      }

      Text {
        visible: root.importError.length === 0
        width: parent.width
        text: root.importNewCount + " new, " + root.importConflicts.length + " need a decision"
        color: root.foreground
        opacity: 0.75
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      Row {
        visible: root.importError.length === 0 && root.importConflicts.length > 1
        spacing: Style.space(6)

        Text {
          text: "Apply to all:"
          color: root.foreground
          opacity: 0.7
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          anchors.verticalCenter: parent.verticalCenter
        }

        Button { text: "Skip"; bordered: true; foreground: root.foreground; fontFamily: root.fontFamily; fontSize: Style.font.caption; focusable: true; onClicked: root.applyImportResolutionToAll("skip") }
        Button { text: "Replace"; bordered: true; foreground: root.foreground; fontFamily: root.fontFamily; fontSize: Style.font.caption; focusable: true; onClicked: root.applyImportResolutionToAll("replace") }
        Button { text: "Keep both"; bordered: true; foreground: root.foreground; fontFamily: root.fontFamily; fontSize: Style.font.caption; focusable: true; onClicked: root.applyImportResolutionToAll("keep-both") }
      }

      ListView {
        visible: root.importError.length === 0
        width: parent.width
        height: Math.min(Style.space(220), root.importConflicts.length * Style.space(64))
        clip: true
        model: root.importConflicts
        spacing: Style.space(6)

        delegate: Column {
          id: conflictRow
          required property var modelData
          width: ListView.view.width
          spacing: Style.space(4)

          Text {
            text: conflictRow.modelData.name
            textFormat: Text.PlainText
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            elide: Text.ElideRight
            width: parent.width
          }

          Row {
            spacing: Style.space(6)

            Button {
              text: "Skip"
              bordered: true
              selected: root.importResolutions[conflictRow.modelData.name] === "skip"
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              focusable: true
              onClicked: root.setImportResolution(conflictRow.modelData.name, "skip")
            }

            Button {
              text: "Replace"
              bordered: true
              selected: root.importResolutions[conflictRow.modelData.name] === "replace"
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              focusable: true
              onClicked: root.setImportResolution(conflictRow.modelData.name, "replace")
            }

            Button {
              text: "Keep both"
              bordered: true
              selected: root.importResolutions[conflictRow.modelData.name] === "keep-both"
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              focusable: true
              onClicked: root.setImportResolution(conflictRow.modelData.name, "keep-both")
            }
          }
        }
      }

      Row {
        spacing: Style.space(8)
        anchors.right: parent.right

        Button {
          text: "Cancel"
          bordered: true
          foreground: root.foreground
          fontFamily: root.fontFamily
          focusable: true
          onClicked: root.cancelImport()
        }

        Button {
          visible: root.importError.length === 0
          text: root.importBusy ? "Importing…" : "Import"
          bordered: true
          foreground: root.foreground
          fontFamily: root.fontFamily
          focusable: true
          enabled: !root.importBusy
          onClicked: root.confirmImport()
        }
      }
    }
  }
}
