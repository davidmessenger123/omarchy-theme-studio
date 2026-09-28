import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Commons

Item {
  id: root

  readonly property string tool: Quickshell.env("HOME") + "/.local/bin/omarchy-theme-from-image"
  readonly property string home: Quickshell.env("HOME")
  readonly property string userThemes: home + "/.config/omarchy/themes"

  // Color has no root-level `border`. Derive one from the themed foreground so
  // it tracks whatever theme is active, without depending on a nested role.
  readonly property color borderColor: Qt.alpha(Color.foreground, 0.22)

  property bool opened: false
  property var themes: []
  property int selectedIndex: -1
  property string busy: ""
  property string status: ""
  property bool statusIsError: false

  // "New theme" workspace state.
  property string pickDir: home + "/Pictures"
  property var candidates: []
  property var chosen: []
  property string newName: ""
  // Set to a slug before reloading so the list can follow a row that changed
  // name, rather than resetting the selection to the active theme.
  property string pendingFollowOld: ""
  property bool renaming: false
  property string renameText: ""

  readonly property var current: selectedIndex >= 0 && selectedIndex < themes.length
                                ? themes[selectedIndex]
                                : null

  readonly property var swatchKeys: [
    "accent", "red", "yellow", "orange", "green", "cyan", "blue", "magenta", "brown",
    "selection", "muted", "background", "dark_background", "lighter_background",
    "foreground", "bright_foreground", "bright_red", "bright_green", "bright_cyan",
    "bright_blue", "bright_magenta", "bright_yellow"
  ]

  function parse(raw) {
    try {
      return JSON.parse(String(raw || "")) || []
    } catch (error) {
      return []
    }
  }

  function say(message, isError) {
    status = message
    statusIsError = isError === true
  }

  function selectedTheme() {
    if (!root.current) return ""
    return root.current.slug
  }

  // ------------------------------------------------------------------ loading

  function loadThemes() {
    if (listProc.running) return
    listProc.running = true
  }

  function onThemesReady() {
    // After a rename the old slug is gone; keep the selection on the new name.
    if (pendingFollowOld !== "") {
      for (var i = 0; i < themes.length; i++) {
        if (themes[i].slug !== pendingFollowOld) continue
        var renamedFrom = renameText.trim()
        for (var j = 0; j < themes.length; j++) {
          if (slugOf(renamedFrom) === themes[j].slug) {
            pendingFollowOld = ""
            selectedIndex = j
            return
          }
        }
      }
      pendingFollowOld = ""
    }
    var activeAt = -1
    for (var k = 0; k < themes.length; k++) {
      if (themes[k].active) { activeAt = k; break }
    }
    if (selectedIndex < 0 || selectedIndex >= themes.length)
      selectedIndex = activeAt >= 0 ? activeAt : 0
  }

  // Mirrors the tool's slugify so the list can predict the new directory name.
  function slugOf(name) {
    return String(name || "").toLowerCase().replace(/[^a-z0-9]+/g, "-")
            .replace(/^-+|-+$/g, "")
  }

  function loadCandidates() {
    if (candidatesProc.running) return
    candidatesProc.running = true
  }

  // ---------------------------------------------------------------- selection

  function toggleCandidate(path) {
    var next = []
    for (var i = 0; i < chosen.length; i++) {
      if (chosen[i] !== path) next.push(chosen[i])
    }
    if (next.length === chosen.length) next.push(path)
    chosen = next
    if (!newName) newName = baseName(chosen[0])
  }

  function isChosen(path) {
    return chosen.indexOf(path) !== -1
  }

  function baseName(path) {
    var parts = String(path || "").split("/")
    var name = parts.length ? parts[parts.length - 1] : ""
    return name.replace(/\.[^.]+$/, "")
  }

  function clearChosen() {
    chosen = []
    newName = ""
  }

  // ------------------------------------------------------------------ actions

  function applyTheme() {
    var slug = selectedTheme()
    if (!slug) return
    say("Applying " + slug + "...")
    applyProc.themeSlug = slug
    applyProc.running = true
  }

  function setBackground(path) {
    say("Setting background...")
    setBgProc.target = path
    setBgProc.running = true
  }

  function removeTheme() {
    var slug = selectedTheme()
    if (!slug || !root.current || !root.current.user) {
      say("Only your own themes can be removed.", true)
      return
    }
    say("Removing " + slug + "...")
    removeProc.themeSlug = slug
    removeProc.running = true
  }

  function startRename() {
    if (!root.current || !root.current.user) return
    renameText = root.current.slug
    renaming = true
    Qt.callLater(function() { renameField.forceActiveFocus(); renameField.selectAll() })
  }

  function cancelRename() {
    renaming = false
    renameText = ""
  }

  function commitRename() {
    var slug = selectedTheme()
    var wanted = String(renameText || "").trim()
    if (renaming && slug && wanted && wanted !== slug) {
      say("Renaming " + slug + " to " + wanted + "...")
      renameProc.oldSlug = slug
      renameProc.command = ["/usr/bin/python3", "-I", root.tool,
                            "--rename", slug, "--to", wanted]
      renameProc.running = true
    } else {
      cancelRename()
    }
  }

  function generateTheme() {
    if (chosen.length === 0) {
      say("Select at least one image.", true)
      return
    }
    var name = newName.trim()
    if (!name) {
      say("Give the theme a name.", true)
      return
    }
    say("Generating theme from " + chosen.length + " image(s)...")
    generateProc.running = true
  }

  function generateCommand() {
    var argv = ["/usr/bin/python3", "-I", root.tool]
    for (var i = 0; i < chosen.length; i++) argv.push(chosen[i])
    argv.push("--name")
    argv.push(newName.trim())
    return argv
  }

  function chooseDirectory() {
    var chooser = "/usr/bin/omarchy-file-select"
    if (pickDirProc.running) return
    pickDirProc.chooser = chooser
    pickDirProc.running = true
  }

  function onDirectoryPicked() {
    var line = String(pickDirProc.pickedDir || "").trim().split("\n")[0] || ""
    if (!line) return
    pickDir = line
    loadCandidates()
  }

  function dismiss() {
    opened = false
  }

  // Lifecycle hooks the shell calls on summon/hide.
  function open(payload) {
    var args = {}
    if (payload) {
      try { args = JSON.parse(payload) || {} } catch (e) { args = {} }
    }
    opened = true
    if (args.directory) { pickDir = String(args.directory); loadCandidates() }
    loadThemes()
  }

  function close() {
    opened = false
  }

  // ----------------------------------------------------------------- plumbing

  Process {
    id: listProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.themes = root.parse(text)
        root.onThemesReady()
      }
    }
    command: ["/usr/bin/python3", "-I", root.tool, "--list"]
  }

  Process {
    id: candidatesProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.candidates = root.parse(text)
    }
    command: ["/usr/bin/python3", "-I", root.tool, "--images-in", root.pickDir]
  }

  Process {
    id: pickDirProc
    property string chooser: ""
    // Named pickedDir, not stdout: Process already owns `stdout` and assigning
    // a second one is a duplicate binding, not an override.
    property string pickedDir: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: pickDirProc.pickedDir = String(text || "")
    }
    onExited: root.onDirectoryPicked()
    command: [pickDirProc.chooser, "--directory", "--title", "Choose a wallpaper folder"]
  }

  Process {
    id: applyProc
    property string themeSlug: ""
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.say(String(text || "").trim().split("\n").pop(), true)
    }
    onExited: {
      root.say(root.statusIsError ? root.status : "Applied " + applyProc.themeSlug)
      root.loadThemes()
    }
    command: ["/usr/bin/env", "bash", "-lc",
              "omarchy theme set " + applyProc.themeSlug + " >/dev/null 2>&1"]
  }

  Process {
    id: setBgProc
    property string target: ""
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.say(String(text || "").trim(), true)
    }
    onExited: root.say("Background updated.")
    command: ["/usr/bin/env", "bash", "-lc",
              "omarchy theme bg set " + Util.shellQuote(setBgProc.target) + " >/dev/null 2>&1"]
  }

  Process {
    id: removeProc
    property string themeSlug: ""
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.say(String(text || "").trim(), true)
    }
    onExited: {
      if (root.statusIsError) return
      root.say("Removed " + removeProc.themeSlug)
      root.selectedIndex = -1
      root.loadThemes()
    }
    command: ["/usr/bin/env", "bash", "-lc",
              "omarchy theme remove " + Util.shellQuote(removeProc.themeSlug)]
  }

  Process {
    id: renameProc
    property string oldSlug: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var lines = String(text || "").trim().split("\n").filter(function(l) { return l !== "" })
        if (lines.length) root.say(lines.join(" "))
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.say(String(text || "").trim(), true)
    }
    onExited: {
      if (root.statusIsError) return
      var note = root.status
      root.cancelRename()
      root.pendingFollowOld = renameProc.oldSlug
      root.loadThemes()
    }
    command: []
  }

  Process {
    id: generateProc
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.say(String(text || "").trim(), true)
    }
    onExited: {
      if (root.statusIsError) return
      root.say("Generated " + newName.trim() + ".")
      root.clearChosen()
      root.loadThemes()
    }
    command: root.generateCommand()
  }

  // -------------------------------------------------------------------- views

  component ActionButton: Rectangle {
    id: button
    property string label: ""
    property bool danger: false
    property bool busy: false
    signal clicked()

    // Singletons imported at file scope are visible here, but the enclosing
    // item's `root` id is not, so this component derives its own border.
    readonly property color borderColor: Qt.alpha(Color.foreground, 0.22)

    // `enabled` is inherited from QQuickItem rather than redeclared, so the
    // standard gating and the styling below stay in sync.
    implicitWidth: Math.max(84, label.length * 8 + Style.space(22))
    implicitHeight: Style.space(36)
    radius: Style.cornerRadius
    opacity: enabled ? 1 : 0.45
    color: button.busy ? Color.accent
                          : (mouse.containsMouse ? Color.background.lighter(1.25) : Color.background)
    border.width: 1
    border.color: button.danger ? Color.urgent : (mouse.containsMouse ? Color.accent : button.borderColor)

    Text {
      anchors.centerIn: parent
      text: button.label
      color: button.danger ? Color.urgent : Color.foreground
      font.pixelSize: Style.font.body
      font.weight: Font.DemiBold
    }

    MouseArea {
      id: mouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: button.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
      onClicked: if (button.enabled && !button.busy) button.clicked()
    }
  }

  PanelWindow {
    id: panel

    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "davidjm-theme-studio"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: root.opened ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: Color.imagePicker.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.dismiss()
    }

    FocusScope {
      id: card
      focus: true
      width: 1120
      height: 700
      anchors.centerIn: parent

      Keys.onEscapePressed: root.dismiss()
      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Down) sidebarList.forceActiveFocus()
        if (event.key === Qt.Key_Tab) sidebarList.forceActiveFocus()
      }

      Rectangle {
        anchors.fill: parent
        radius: Style.cornerRadius
        color: Color.background
        border.width: 1
        border.color: root.borderColor

        MouseArea { anchors.fill: parent; onClicked: {} }
      }

      ColumnLayout {
        anchors.fill: parent
        anchors.margins: Style.space(20)
        spacing: Style.space(14)

        // ------------------------------------------------------------ header
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(12)

          ColumnLayout {
            spacing: 0
            Text {
              text: "Theme Studio"
              color: Color.foreground
              font.pixelSize: Style.font.title
              font.weight: Font.Bold
            }
            Text {
              text: root.userThemes
              color: Color.muted
              font.pixelSize: Style.font.caption
            }
          }

          Item { Layout.fillWidth: true }

          ActionButton {
            label: "Close"
            onClicked: root.dismiss()
          }
        }

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(16)

          // ---------------------------------------------------------- themes
          Rectangle {
            Layout.preferredWidth: 250
            Layout.fillHeight: true
            radius: Style.cornerRadius
            color: Color.background.lighter(1.04)
            border.width: 1
            border.color: root.borderColor

            ColumnLayout {
              anchors.fill: parent
              anchors.margins: Style.space(10)
              spacing: Style.space(6)

              Text {
                text: "THEMES  (" + root.themes.length + ")"
                color: Color.muted
                font.pixelSize: Style.font.caption
                font.weight: Font.DemiBold
                Layout.leftMargin: Style.space(4)
              }

              ListView {
                id: sidebarList
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                model: root.themes
                currentIndex: root.selectedIndex
                focus: true
                keyNavigationEnabled: true
                ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

                delegate: Rectangle {
                  id: row
                  required property int index
                  required property var modelData

                  readonly property bool isActive: row.modelData.active

                  width: ListView.view.width - Style.space(4)
                  height: Style.space(56)
                  radius: Style.cornerRadius
                  color: row.index === root.selectedIndex ? Color.accent
                         : (rowMouse.containsMouse ? Color.background.lighter(1.12) : "transparent")

                  ColumnLayout {
                    anchors.fill: parent
                    anchors.leftMargin: Style.space(10)
                    anchors.rightMargin: Style.space(8)
                    spacing: 0

                    RowLayout {
                      Layout.fillWidth: true
                      spacing: Style.space(6)
                      Text {
                        text: row.modelData.name
                        color: row.index === root.selectedIndex ? Color.background : Color.foreground
                        font.pixelSize: Style.font.body
                        font.weight: Font.DemiBold
                        elide: Text.ElideRight
                        Layout.fillWidth: true
                      }
                      Rectangle {
                        visible: row.isActive
                        implicitWidth: activeLabel.implicitWidth + Style.space(10)
                        implicitHeight: activeLabel.implicitHeight + Style.space(4)
                        radius: 3
                        color: row.index === root.selectedIndex
                               ? Color.background : Color.accent
                        Text {
                          id: activeLabel
                          anchors.centerIn: parent
                          text: "ACTIVE"
                          color: row.index === root.selectedIndex ? Color.accent : Color.background
                          font.pixelSize: 8
                          font.weight: Font.Bold
                        }
                      }
                    }

                    Text {
                      text: (row.modelData.user ? "yours" : "stock")
                            + "  ·  " + row.modelData.mode
                            + "  ·  " + row.modelData.backgrounds.length + " bg"
                      color: row.index === root.selectedIndex
                             ? Util.alpha(Color.background, 0.75) : Color.muted
                      font.pixelSize: Style.font.caption
                    }
                  }

                  MouseArea {
                    id: rowMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.selectedIndex = row.index
                  }
                }
              }
            }
          }

          // ------------------------------------------------------- main pane
          StackLayout {
            id: stack
            Layout.fillWidth: true
            Layout.fillHeight: true
            currentIndex: 0

            // --- browse an existing theme
            Item {
              // Nothing selected yet.
              ColumnLayout {
                anchors.centerIn: parent
                spacing: Style.space(8)
                visible: !root.current
                Text {
                  text: "No theme selected"
                  color: Color.muted
                  font.pixelSize: Style.font.title
                }
                Text {
                  text: "Pick one on the left, or build a new theme from wallpapers."
                  color: Color.muted
                  font.pixelSize: Style.font.body
                }
              }

              // Palette
              ColumnLayout {
                visible: root.current !== null
                anchors.fill: parent
                spacing: Style.space(12)

                RowLayout {
                  Layout.fillWidth: true
                  spacing: Style.space(10)
                  Text {
                    text: root.current ? root.current.name : ""
                    color: Color.foreground
                    font.pixelSize: Style.font.title
                    font.weight: Font.Bold
                  }
                  Text {
                    visible: root.current !== null
                    text: root.current ? root.current.slug : ""
                    color: Color.muted
                    font.pixelSize: Style.font.caption
                  }
                  Item { Layout.fillWidth: true }
                  Text {
                    text: "PALETTE"
                    color: Color.muted
                    font.pixelSize: Style.font.caption
                    font.weight: Font.DemiBold
                  }
                }

                RowLayout {
                  Layout.fillWidth: true
                  spacing: Style.space(5)
                  Repeater {
                    model: root.swatchKeys
                    delegate: Item {
                      id: swatch
                      required property string modelData
                      readonly property string valueName: root.current
                        ? (root.current.colors[swatch.modelData] || "") : ""
                      Layout.fillWidth: true
                      Layout.preferredHeight: 42
                      Rectangle {
                        id: swatchRect
                        anchors.fill: parent
                        radius: Style.cornerRadius
                        color: swatch.valueName !== "" ? swatch.valueName : "transparent"
                        border.width: 1
                        border.color: root.borderColor
                        Text {
                          anchors.centerIn: parent
                          visible: swatch.valueName === ""
                          text: "—"
                          color: Color.muted
                          font.pixelSize: Style.font.caption
                        }
                      }
                      MouseArea {
                        id: swatchArea
                        anchors.fill: parent
                        hoverEnabled: true
                      }
                      Rectangle {
                        z: 50
                        visible: swatchArea.containsMouse && swatch.valueName !== ""
                        anchors.bottom: swatchArea.top
                        anchors.bottomMargin: Style.space(6)
                        anchors.horizontalCenter: swatchArea.horizontalCenter
                        width: tip.implicitWidth + Style.space(14)
                        height: tip.implicitHeight + Style.space(8)
                        radius: Style.cornerRadius
                        color: Color.background
                        border.width: 1
                        border.color: Color.accent
                        Text {
                          id: tip
                          anchors.centerIn: parent
                          text: swatch.modelData + "  " + swatch.valueName
                          color: Color.foreground
                          font.pixelSize: Style.font.caption
                        }
                      }
                    }
                  }
                }

                Text {
                  text: "BACKGROUNDS  (" + (root.current ? root.current.backgrounds.length : 0)
                        + ")  ·  click to make it current, cycles with omarchy theme bg next"
                  color: Color.muted
                  font.pixelSize: Style.font.caption
                  font.weight: Font.DemiBold
                }

                GridView {
                  id: backgrounds
                  Layout.fillWidth: true
                  Layout.fillHeight: true
                  clip: true
                  model: root.current ? root.current.backgrounds : []
                  cellWidth: 150
                  cellHeight: 108
                  ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

                  delegate: Item {
                    id: bgTile
                    required property var modelData
                    width: 140
                    height: 98

                    Rectangle {
                      anchors.fill: parent
                      radius: Style.cornerRadius
                      color: Color.background.lighter(1.05)
                      border.width: 1
                      border.color: bgMouse.containsMouse ? Color.accent : root.borderColor
                    }

                    Image {
                      anchors.fill: parent
                      anchors.margins: 3
                      source: Util.fileUrl(bgTile.modelData.path)
                      fillMode: Image.PreserveAspectCrop
                      asynchronous: true
                      cache: true
                      smooth: true
                      clip: true
                    }

                    Rectangle {
                      anchors.bottom: parent.bottom
                      anchors.left: parent.left
                      anchors.right: parent.right
                      anchors.margins: 3
                      height: 20
                      radius: 2
                      color: Util.alpha(Color.background, 0.72)
                      Text {
                        anchors.centerIn: parent
                        width: parent.width - Style.space(6)
                        text: bgTile.modelData.name
                        color: Color.foreground
                        font.pixelSize: Style.font.caption
                        elide: Text.ElideMiddle
                        horizontalAlignment: Text.AlignHCenter
                      }
                    }

                    MouseArea {
                      id: bgMouse
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.setBackground(bgTile.modelData.path)
                    }
                  }
                }

                // Actions for the selected theme
                RowLayout {
                  Layout.fillWidth: true
                  spacing: Style.space(8)

                  ActionButton {
                    label: "Apply Theme"
                    enabled: root.current !== null
                    busy: applyProc.running
                    onClicked: root.applyTheme()
                  }
                  ActionButton {
                    label: "Remove Theme"
                    danger: true
                    enabled: root.current !== null && root.current.user
                    onClicked: root.removeTheme()
                  }
                  ActionButton {
                    label: "Rename…"
                    visible: !root.renaming && root.current !== null && root.current.user
                    enabled: !renameProc.running
                    onClicked: root.startRename()
                  }
                  Item { Layout.fillWidth: true }
                  Text {
                    visible: root.current !== null && !root.current.user
                    text: "Stock theme — cannot be removed"
                    color: Color.muted
                    font.pixelSize: Style.font.caption
                  }
                }

                // Inline rename, shown in place of the button once opened so the
                // row does not reflow under the pointer.
                Rectangle {
                  visible: root.renaming
                  Layout.fillWidth: true
                  Layout.preferredHeight: Style.space(36)
                  radius: Style.cornerRadius
                  color: Color.background.lighter(1.05)
                  border.width: 1
                  border.color: renameField.activeFocus ? Color.accent : root.borderColor

                  TextInput {
                    id: renameField
                    anchors.fill: parent
                    anchors.leftMargin: Style.space(12)
                    anchors.rightMargin: Style.space(12)
                    verticalAlignment: TextInput.AlignVCenter
                    color: Color.foreground
                    font.pixelSize: Style.font.body
                    selectByMouse: true
                    clip: true
                    Keys.onReturnPressed: root.commitRename()
                    Keys.onEnterPressed: root.commitRename()
                    Keys.onEscapePressed: root.cancelRename()
                  }

                  Text {
                    anchors.fill: parent
                    anchors.leftMargin: Style.space(12)
                    visible: renameField.text === ""
                    text: "New name for " + (root.current ? root.current.slug : "")
                    color: Color.muted
                    font.pixelSize: Style.font.body
                  }
                }

                RowLayout {
                  visible: root.renaming
                  Layout.fillWidth: true
                  spacing: Style.space(8)

                  ActionButton {
                    label: "Save Name"
                    busy: renameProc.running
                    onClicked: root.commitRename()
                  }
                  ActionButton {
                    label: "Cancel"
                    enabled: !renameProc.running
                    onClicked: root.cancelRename()
                  }
                  Item { Layout.fillWidth: true }
                  Text {
                    text: "Letters, digits and dashes. Backgrounds come along."
                    color: Color.muted
                    font.pixelSize: Style.font.caption
                  }
                }
              }
            }

            // --- build a new theme
            Item {
              ColumnLayout {
                anchors.fill: parent
                spacing: Style.space(12)

                Text {
                  text: "New theme from wallpapers"
                  color: Color.foreground
                  font.pixelSize: Style.font.title
                  font.weight: Font.Bold
                }

                RowLayout {
                  Layout.fillWidth: true
                  spacing: Style.space(8)

                  Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: Style.space(36)
                    radius: Style.cornerRadius
                    color: Color.background.lighter(1.05)
                    border.width: 1
                    border.color: nameField.activeFocus ? Color.accent : root.borderColor

                    TextInput {
                      id: nameField
                      anchors.fill: parent
                      anchors.leftMargin: Style.space(12)
                      anchors.rightMargin: Style.space(12)
                      verticalAlignment: TextInput.AlignVCenter
                      color: Color.foreground
                      font.pixelSize: Style.font.body
                      selectByMouse: true
                      clip: true
                      onTextChanged: root.newName = text
                      Keys.onEscapePressed: { root.newName = ""; text = ""; root.dismiss() }
                    }

                    Text {
                      anchors.fill: parent
                      anchors.leftMargin: Style.space(12)
                      visible: nameField.text === ""
                      text: "Theme name"
                      color: Color.muted
                      font.pixelSize: Style.font.body
                    }
                  }

                  ActionButton {
                    label: "Use Folder Name"
                    onClicked: if (root.chosen.length) root.newName = root.baseName(root.chosen[0])
                  }
                }

                // Folder + selection summary
                RowLayout {
                  Layout.fillWidth: true
                  spacing: Style.space(8)

                  ActionButton {
                    label: "Choose Folder…"
                    onClicked: root.chooseDirectory()
                  }
                  Text {
                    Layout.fillWidth: true
                    text: root.pickDir
                    color: Color.muted
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideMiddle
                  }
                  Text {
                    text: root.chosen.length + " selected"
                    color: root.chosen.length ? Color.accent : Color.muted
                    font.pixelSize: Style.font.caption
                    font.weight: Font.DemiBold
                  }
                  ActionButton {
                    label: "Clear"
                    enabled: root.chosen.length > 0
                    onClicked: root.clearChosen()
                  }
                }

                GridView {
                  Layout.fillWidth: true
                  Layout.fillHeight: true
                  clip: true
                  model: root.candidates
                  cellWidth: 128
                  cellHeight: 96
                  ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

                  delegate: Item {
                    id: candidate
                    required property var modelData
                    required property int index
                    width: 120
                    height: 88

                    readonly property bool picked: root.isChosen(candidate.modelData.path)

                    Rectangle {
                      anchors.fill: parent
                      radius: Style.cornerRadius
                      color: candidate.picked ? Color.accent : Color.background.lighter(1.05)
                      border.width: candidate.picked ? 2 : 1
                      border.color: candidate.picked ? Color.accent : root.borderColor
                    }

                    Image {
                      anchors.fill: parent
                      anchors.margins: 3
                      source: Util.fileUrl(candidate.modelData.path)
                      fillMode: Image.PreserveAspectCrop
                      asynchronous: true
                      smooth: true
                      clip: true
                    }

                    Rectangle {
                      visible: candidate.picked
                      anchors.top: parent.top
                      anchors.right: parent.right
                      anchors.margins: 6
                      width: 20
                      height: 20
                      radius: 10
                      color: Color.accent
                      Text {
                        anchors.centerIn: parent
                        text: "✓"
                        color: Color.background
                        font.pixelSize: Style.font.caption
                        font.weight: Font.Bold
                      }
                    }

                    MouseArea {
                      anchors.fill: parent
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.toggleCandidate(candidate.modelData.path)
                    }
                  }
                }

                RowLayout {
                  Layout.fillWidth: true
                  spacing: Style.space(8)

                  ActionButton {
                    label: "Generate Theme"
                    enabled: root.chosen.length > 0
                    busy: generateProc.running
                    onClicked: root.generateTheme()
                  }
                  Text {
                    text: "Several images become a set the theme cycles through."
                    color: Color.muted
                    font.pixelSize: Style.font.caption
                  }
                }
              }
            }
          }
        }

        // -------------------------------------------------------------- status
        Rectangle {
          Layout.fillWidth: true
          Layout.preferredHeight: Style.space(30)
          radius: Style.cornerRadius
          color: Color.background.lighter(1.06)
          border.width: 1
          border.color: root.statusIsError ? Color.urgent : root.borderColor

          Text {
            anchors.left: parent.left
            anchors.leftMargin: Style.space(12)
            anchors.right: tabButton.left
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            text: root.status !== "" ? root.status : "Ready."
            color: root.statusIsError ? Color.urgent : Color.muted
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }

          // Switches the right-hand pane between browsing and generating.
          Rectangle {
            id: tabButton
            anchors.right: parent.right
            anchors.rightMargin: Style.space(4)
            anchors.verticalCenter: parent.verticalCenter
            width: tabsRow.implicitWidth + Style.space(20)
            height: Style.space(24)
            radius: Style.cornerRadius
            color: "transparent"
            border.width: 1
            border.color: root.borderColor

            RowLayout {
              id: tabsRow
              anchors.centerIn: parent
              spacing: Style.space(12)

              Text {
                text: "Browse"
                color: stack.currentIndex === 0 ? Color.accent : Color.muted
                font.pixelSize: Style.font.caption
                font.weight: Font.DemiBold
                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: stack.currentIndex = 0
                }
              }
              Text {
                text: "Generate"
                color: stack.currentIndex === 1 ? Color.accent : Color.muted
                font.pixelSize: Style.font.caption
                font.weight: Font.DemiBold
                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: {
                    stack.currentIndex = 1
                    root.loadCandidates()
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}
