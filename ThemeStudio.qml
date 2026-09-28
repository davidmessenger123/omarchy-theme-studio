import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Commons

Item {
  id: root

  // The CLI lives in the plugin directory so the whole studio is one git repo;
  // ~/.local/bin/omarchy-theme-from-image is a symlink to it for command-line use.
  readonly property string tool: Quickshell.env("HOME")
                          + "/.config/omarchy/plugins/davidjm.theme-studio/omarchy-theme-from-image"
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
  // Set to a slug when the picker is adding wallpapers to an existing theme
  // rather than creating one; "" means create. The picker is shared, so the
  // mode lives here and every page reads it.
  property string addTarget: ""
  // With --add, the palette is re-derived from the whole set by default, which
  // would discard edits made on the Colours page. Keeping the colours is the
  // less destructive default, so re-deriving is opt-in.
  property bool keepColors: true
  // Set to a slug before reloading so the list can follow a row that changed
  // name, rather than resetting the selection to the active theme.
  property string pendingFollowOld: ""
  // The slug the old one became. Held separately because closing the rename
  // field clears renameText, which the list reload no longer has.
  property string pendingFollowNew: ""
  property bool renaming: false
  property string renameText: ""

  // "Edit colours" workspace state. colorDraft is the working copy the user
  // types into; colorGroups comes from the tool so the two never drift.
  property var colorGroups: []
  property var colorDraft: ({})
  // Row index the keyboard has been handed to, or -1. See editColorCursor.
  property int editingRow: -1

  // Group headers and colour keys flattened into one list, so a single repeater
  // can lay out both without a nested repeater losing hold of the outer model.
  readonly property var colorRows: {
    var rows = []
    for (var i = 0; i < colorGroups.length; i++) {
      rows.push({ kind: "group", title: colorGroups[i].title })
      for (var j = 0; j < colorGroups[i].keys.length; j++) {
        rows.push({ kind: "color", key: colorGroups[i].keys[j] })
      }
    }
    return rows
  }

  // Only the keys the tool declared editable. Everything else in colors comes
  // from the theme file and is not a hex colour -- the Hyprland borders are
  // gradients of the accent -- so it must never be validated or sent.
  readonly property var editableKeys: {
    var keys = []
    for (var i = 0; i < colorGroups.length; i++) {
      for (var j = 0; j < colorGroups[i].keys.length; j++) keys.push(colorGroups[i].keys[j])
    }
    return keys
  }

  // Index of the first editable row, so the list does not open on a header.
  readonly property int firstColorRow: {
    for (var i = 0; i < colorRows.length; i++) {
      if (colorRows[i].kind === "color") return i
    }
    return 0
  }

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
      for (var j = 0; j < themes.length; j++) {
        if (pendingFollowNew === themes[j].slug) {
          var keep = j
          pendingFollowOld = ""
          pendingFollowNew = ""
          selectedIndex = keep
          return
        }
      }
      pendingFollowOld = ""
      pendingFollowNew = ""
    }
    var activeAt = -1
    for (var k = 0; k < themes.length; k++) {
      if (themes[k].active) { activeAt = k; break }
    }
    if (selectedIndex < 0 || selectedIndex >= themes.length)
      selectedIndex = activeAt >= 0 ? activeAt : 0

    // The colours on disk are the truth; drop any draft left over from before
    // the reload, or it would show values that no longer match the theme.
    if (stack.currentIndex === 2) loadColorDraft()
  }

  // Switching rows while editing colours shows that row's palette, not the
  // previous theme's.
  onSelectedIndexChanged: {
    if (stack.currentIndex === 2) loadColorDraft()
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
    renaming = true
    // Seed the field directly rather than through a binding: the user's typing
    // would otherwise break the binding and leave renameText stale.
    renameText = root.current.slug
    renameField.text = renameText
    Qt.callLater(function() { renameField.forceActiveFocus(); renameField.selectAll() })
  }

  function cancelRename() {
    renaming = false
    renameText = ""
    renameField.text = ""
  }

  // What the name will actually become on disk, and why it cannot, so the hint
  // can say so before Enter is pressed rather than after a failed rename.
  readonly property string renameSlug: slugOf(renameText)
  readonly property string renameProblem: {
    if (!renaming) return ""
    var typed = String(renameText || "").trim()
    if (!typed) return "Type a name."
    if (!renameSlug) return "That has no letters or digits in it."
    if (renameSlug === selectedTheme()) return "That is the current name."
    for (var i = 0; i < themes.length; i++) {
      if (themes[i].slug === renameSlug) return "'" + renameSlug + "' is taken."
    }
    return ""
  }

  function commitRename() {
    var slug = selectedTheme()
    var wanted = String(renameField.text || "").trim()
    if (root.renameProblem !== "") {
      say(root.renameProblem, true)
      return
    }
    if (renaming && slug && wanted) {
      say("Renaming " + slug + " to " + root.renameSlug + "...")
      renameProc.oldSlug = slug
      pendingFollowOld = slug
      pendingFollowNew = root.renameSlug
      renameProc.command = ["/usr/bin/python3", "-I", root.tool,
                            "--rename", slug, "--to", wanted]
      renameProc.running = true
    } else {
      cancelRename()
    }
  }

  // ------------------------------------------------------------ colour editing

  function loadColorGroups() {
    if (groupsProc.running) return
    groupsProc.running = true
  }

  // The draft mirrors the selected theme's colors.toml, so Save only has to
  // send what actually changed.
  function loadColorDraft() {
    var draft = {}
    if (root.current) {
      var saved = root.current.colors
      for (var key in saved) draft[key] = saved[key]
    }
    colorDraft = draft
  }

  function draftFor(key) {
    var value = colorDraft[key]
    return typeof value === "string" ? value : ""
  }

  // Reassigns the whole object so every field's text binding re-evaluates.
  function setDraft(key, value) {
    var next = {}
    for (var existing in colorDraft) next[existing] = colorDraft[existing]
    next[key] = value
    colorDraft = next
  }

  // Accepts what a person actually types -- "f0a", "#F0A", "f0a1b2" -- and
  // returns a normalised #rrggbb, or "" when it cannot be one.
  function normaliseHex(value) {
    var text = String(value || "").trim().replace(/^#/, "").toLowerCase()
    if (/^[0-9a-f]{3}$/.test(text)) {
      text = text[0] + text[0] + text[1] + text[1] + text[2] + text[2]
    }
    return /^[0-9a-f]{6}$/.test(text) ? "#" + text : ""
  }

  function isHexValid(key) {
    return normaliseHex(draftFor(key)) !== ""
  }

  function draftIsDirty() {
    if (!root.current) return false
    for (var i = 0; i < editableKeys.length; i++) {
      var key = editableKeys[i]
      var typed = normaliseHex(colorDraft[key])
      if (typed && typed !== String(root.current.colors[key] || "").toLowerCase()) return true
    }
    return false
  }

  function invalidColorKeys() {
    var bad = []
    for (var i = 0; i < editableKeys.length; i++) {
      var key = editableKeys[i]
      if (draftFor(key) !== "" && !isHexValid(key)) bad.push(key)
    }
    return bad
  }

  function startColorEditing() {
    root.cancelRename()
    loadColorGroups()
    loadColorDraft()
    // The list takes the keyboard so Up/Down and typing work straight away.
    Qt.callLater(function() { colorList.forceActiveFocus() })
  }

  // Moves the highlight by `step`, stepping over group headers so Up and Down
  // only ever land on something editable.
  function moveColorCursor(step) {
    var index = colorList.currentIndex
    for (var i = index + step; i >= 0 && i < colorRows.length; i += step) {
      if (colorRows[i].kind === "color") { colorList.currentIndex = i; return }
    }
  }

  // Asks the highlighted row to take the keyboard. Routed through a property
  // rather than itemAtIndex(), which hands back an untyped QQuickItem.
  function editColorCursor() {
    editingRow = colorList.currentIndex
  }

  function saveColors() {
    var slug = selectedTheme()
    if (!slug) return
    if (!root.current.user) {
      say("Stock themes cannot be edited.", true)
      return
    }
    var bad = invalidColorKeys()
    if (bad.length) {
      say("Not a hex colour: " + bad.join(", "), true)
      return
    }
    var argv = []
    for (var i = 0; i < editableKeys.length; i++) {
      var key = editableKeys[i]
      var typed = normaliseHex(colorDraft[key])
      if (typed && typed !== String(root.current.colors[key] || "").toLowerCase())
        argv.push("--set-color", key + "=" + typed)
    }
    if (argv.length === 0) {
      say("Nothing changed.")
      return
    }
    say("Saving colours to " + slug + "...")
    saveColorsProc.command = ["/usr/bin/python3", "-I", root.tool,
                              "--name", slug, "--refresh"].concat(argv)
    saveColorsProc.running = true
  }

  function revertColors() {
    loadColorDraft()
    say("Reverted to the saved colours.")
  }

  // One place that switches panes, so the tab strip and the Ctrl+Tab shortcut
  // cannot drift apart and every page gets the setup it needs on entry.
  // `addTo` is the theme the wallpaper picker should add to, if any.
  function showTab(index, addTo) {
    stack.currentIndex = index
    if (index === 1) {
      addTarget = addTo || ""
      loadCandidates()
      // The grid takes the keyboard so the wallpapers can be chosen with the
      // arrows and Enter straight away.
      Qt.callLater(function() { candidateGrid.forceActiveFocus() })
    }
    if (index === 2) startColorEditing()
  }

  function startAddingWallpapers() {
    if (!root.current || !root.current.user) {
      say("Wallpapers can only be added to one of your own themes.", true)
      return
    }
    showTab(1, root.current.slug)
    say("Adding wallpapers to " + addTarget + ".")
  }

  function toggleCandidateAtCursor() {
    var index = candidateGrid.currentIndex
    if (index < 0 || index >= candidates.length) return
    toggleCandidate(candidates[index].path)
  }

  function cancelAddingWallpapers() {
    addTarget = ""
    say("")
  }

  function generateTheme() {
    if (chosen.length === 0) {
      say("Select at least one image.", true)
      return
    }
    if (addTarget === "") {
      if (!newName.trim()) {
        say("Give the theme a name.", true)
        return
      }
      say("Generating theme from " + chosen.length + " image(s)...")
    } else {
      say("Adding " + chosen.length + " image(s) to " + addTarget
          + (keepColors ? "..." : ", re-deriving its palette..."))
    }
    generateProc.running = true
  }

  function generateCommand() {
    var argv = ["/usr/bin/python3", "-I", root.tool]
    for (var i = 0; i < chosen.length; i++) argv.push(chosen[i])
    if (addTarget !== "") {
      argv.push("--name", addTarget, "--add")
      if (keepColors) argv.push("--keep-colors")
    } else {
      argv.push("--name", newName.trim())
    }
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
    resetTransient()
  }

  // Dismissing the panel must not leave half-finished work behind: a rename
  // field left open reappears with its stale text the next time it is shown.
  function resetTransient() {
    if (renameField) { renameField.text = "" }
    renaming = false
    renameText = ""
    pendingFollowOld = ""
    pendingFollowNew = ""
  }

  // Lifecycle hooks the shell calls on summon/hide.
  function open(payload) {
    var args = {}
    if (payload) {
      try { args = JSON.parse(payload) || {} } catch (e) { args = {} }
    }
    opened = true
    resetTransient()
    // The colour page is driven by the tool's group list. Fetch it on open as
    // well as on tab switch, so the page is never blank because it was reached
    // some other way.
    if (colorGroups.length === 0) loadColorGroups()
    if (args.directory) { pickDir = String(args.directory); loadCandidates() }
    loadThemes()
  }

  function close() {
    opened = false
    resetTransient()
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
      if (root.statusIsError) {
        // The row is still under its old name; let the user try again.
        pendingFollowOld = ""
        pendingFollowNew = ""
        return
      }
      root.cancelRename()
      root.loadThemes()
    }
    command: []
  }

  Process {
    id: groupsProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.colorGroups = root.parse(text)
    }
    command: ["/usr/bin/python3", "-I", root.tool, "--groups"]
  }

  Process {
    id: saveColorsProc
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
      root.loadThemes()
    }
    command: []
  }

  Process {
    id: generateProc
    property string output: ""
    // The tool reports things worth keeping -- images converted to png, a
    // wallpaper that was already there -- so show what it said rather than
    // replacing it with a generic message.
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: generateProc.output = String(text || "").trim()
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.say(String(text || "").trim(), true)
    }
    onExited: {
      if (root.statusIsError) return
      var lines = generateProc.output.split("\n").filter(function(l) { return l !== "" })
      if (lines.length) root.say(lines.join(" "))
      else if (root.addTarget !== "") root.say("Added wallpapers to " + root.addTarget + ".")
      else root.say("Generated " + newName.trim() + ".")
      root.addTarget = ""
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

  // Like ActionButton, an inline component cannot reach the enclosing `root`,
  // so this one carries its state in its own properties and reports through a
  // signal rather than writing to a shared one.
  component ToggleChip: Rectangle {
    id: chip
    property string label: ""
    property bool checked: false
    signal toggled()

    // `enabled` is inherited from QQuickItem rather than redeclared, so the
    // opacity and the click gate below stay in sync.
    implicitWidth: chipRow.implicitWidth + Style.space(22)
    implicitHeight: Style.space(36)
    radius: Style.cornerRadius
    opacity: enabled ? 1 : 0.45
    color: chip.checked ? Color.accent
                          : (chipMouse.containsMouse ? Color.background.lighter(1.25) : Color.background)
    border.width: 1
    border.color: chip.checked ? Color.accent
                                : (chipMouse.containsMouse ? Color.accent : Qt.alpha(Color.foreground, 0.22))

    RowLayout {
      id: chipRow
      anchors.centerIn: parent
      spacing: Style.space(8)

      Rectangle {
        implicitWidth: 14
        implicitHeight: 14
        radius: 7
        color: chip.checked ? Color.background : "transparent"
        border.width: 1
        border.color: chip.checked ? Color.background : Qt.alpha(Color.foreground, 0.5)
        Text {
          anchors.centerIn: parent
          visible: chip.checked
          text: "✓"
          color: Color.accent
          font.pixelSize: 9
          font.weight: Font.Bold
        }
      }

      Text {
        text: chip.label
        color: chip.checked ? Color.background : Color.foreground
        font.pixelSize: Style.font.body
        font.weight: Font.DemiBold
      }
    }

    MouseArea {
      id: chipMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
      onClicked: if (chip.enabled) chip.toggled()
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
        // Ctrl+Tab / Ctrl+Shift+Tab cycle the panes; the tab strip is otherwise
        // mouse-only, which would strand anyone not using a pointer.
        if (event.key === Qt.Key_Tab && (event.modifiers & Qt.ControlModifier)) {
          var step = (event.modifiers & Qt.ShiftModifier) ? -1 : 1
          root.showTab((stack.currentIndex + step + 3) % 3)
          return
        }
        // Generate-only: hand the keyboard to the wallpaper grid, but only when
        // it does not already have it, so the arrows are not swallowed.
        if (stack.currentIndex === 1) {
          if ((event.key === Qt.Key_Down || event.key === Qt.Key_Tab)
              && !candidateGrid.activeFocus)
            candidateGrid.forceActiveFocus()
          return
        }
        // Browse-only shortcuts. The colour list handles its own arrows, and
        // yanking focus to the sidebar from there would strand the user.
        if (stack.currentIndex !== 0) return
        // Only hand focus over when the list does not already have it: this
        // handler accepts the event, so re-focusing on every press would
        // swallow the arrow keys the list needs to move the selection.
        if ((event.key === Qt.Key_Down || event.key === Qt.Key_Tab)
            && !sidebarList.activeFocus)
          sidebarList.forceActiveFocus()
        // R and A open the rename field and the wallpaper picker, so the whole
        // of Browse is reachable without a mouse. Guarded on !renaming so they
        // cannot fire while that field has focus and Enter is on its way to
        // commitRename.
        if (!root.renaming && root.current !== null && root.current.user) {
          if (event.key === Qt.Key_R) root.startRename()
          if (event.key === Qt.Key_A) root.startAddingWallpapers()
        }
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
                  ActionButton {
                    label: "Add Wallpaper…"
                    visible: root.current !== null && root.current.user
                    onClicked: root.startAddingWallpapers()
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
                    onTextChanged: root.renameText = text
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
                    enabled: root.renameProblem === ""
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
                    text: root.renameProblem !== ""
                          ? root.renameProblem
                          : (root.renameSlug !== ""
                             ? "Becomes " + root.renameSlug + "  ·  backgrounds come along"
                             : "Letters, digits and dashes. Backgrounds come along.")
                    color: root.renameProblem !== "" ? Color.urgent : Color.muted
                    font.pixelSize: Style.font.caption
                  }
                }
              }
            }

            // --- build a new theme, or add wallpapers to an existing one
            Item {
              ColumnLayout {
                anchors.fill: parent
                spacing: Style.space(12)

                Text {
                  text: root.addTarget !== ""
                        ? "Add wallpapers to " + root.addTarget
                        : "New theme from wallpapers"
                  color: Color.foreground
                  font.pixelSize: Style.font.title
                  font.weight: Font.Bold
                }

                Text {
                  Layout.fillWidth: true
                  visible: root.addTarget !== ""
                  text: "The theme keeps its colours unless you ask for them to be re-derived."
                  color: Color.muted
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                }

                RowLayout {
                  Layout.fillWidth: true
                  visible: root.addTarget === ""
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
                  id: candidateGrid
                  Layout.fillWidth: true
                  Layout.fillHeight: true
                  clip: true
                  model: root.candidates
                  cellWidth: 128
                  cellHeight: 96
                  focus: true
                  keyNavigationEnabled: true
                  // Enter picks the highlighted image and Ctrl+Enter commits,
                  // so a set of wallpapers can be chosen without a mouse. One
                  // Keys.onPressed handles both, since a specific handler
                  // would shadow it for Return.
                  Keys.onPressed: function(event) {
                    if (event.key === Qt.Key_Escape) {
                      root.cancelAddingWallpapers()
                      return
                    }
                    if (event.modifiers & Qt.ControlModifier) {
                      if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)
                        root.generateTheme()
                      return
                    }
                    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                        || (event.text && event.text.length === 1))
                      root.toggleCandidateAtCursor()
                  }
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

                  ToggleChip {
                    visible: root.addTarget !== ""
                    label: "Keep current colours"
                    checked: root.keepColors
                    onToggled: root.keepColors = !root.keepColors
                  }

                  ActionButton {
                    visible: root.addTarget === ""
                    label: "Generate Theme"
                    enabled: root.chosen.length > 0
                    busy: generateProc.running
                    onClicked: root.generateTheme()
                  }

                  ActionButton {
                    visible: root.addTarget !== ""
                    label: root.chosen.length === 1
                          ? "Add 1 Wallpaper" : "Add " + root.chosen.length + " Wallpapers"
                    enabled: root.chosen.length > 0
                    busy: generateProc.running
                    onClicked: root.generateTheme()
                  }

                  ActionButton {
                    visible: root.addTarget !== ""
                    label: "Cancel"
                    enabled: !generateProc.running
                    onClicked: root.cancelAddingWallpapers()
                  }

                  Item { Layout.fillWidth: true }

                  Text {
                    text: root.addTarget !== ""
                          ? (root.keepColors
                             ? "Enter to pick, Ctrl+Enter to add. The theme cycles through the set."
                             : "The palette will be re-derived from the whole set, discarding colour edits.")
                          : "Enter to pick, Ctrl+Enter to generate. Several images become a set the theme cycles through."
                    color: root.addTarget !== "" && !root.keepColors ? Color.urgent : Color.muted
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }
                }
              }
            }

            // --- edit an existing theme's colours
            Item {
              // No `visible` binding here or on the ColumnLayout below: those
              // are StackLayout's own children, and binding visible on them
              // would defeat the page switching. StackLayout does not manage
              // the grandchildren, which is where the empty state belongs.
              ColumnLayout {
                anchors.fill: parent
                spacing: Style.space(10)

                ColumnLayout {
                  visible: !root.current
                  Layout.alignment: Qt.AlignHCenter | Qt.AlignVCenter
                  spacing: Style.space(8)
                  Text {
                    text: "Pick a theme to edit its colours"
                    color: Color.muted
                    font.pixelSize: Style.font.title
                  }
                  Text {
                    text: "Colours are saved to colors.toml in the theme folder."
                    color: Color.muted
                    font.pixelSize: Style.font.body
                  }
                }

                ColumnLayout {
                  visible: root.current !== null
                  Layout.fillWidth: true
                  Layout.fillHeight: true
                  spacing: Style.space(10)

                  RowLayout {
                    Layout.fillWidth: true
                    spacing: Style.space(10)
                    Text {
                      text: "Colours"
                      color: Color.foreground
                      font.pixelSize: Style.font.title
                      font.weight: Font.Bold
                    }
                    Text {
                      text: root.current ? root.current.slug : ""
                      color: Color.muted
                      font.pixelSize: Style.font.caption
                    }
                    Item { Layout.fillWidth: true }
                    ActionButton {
                      label: "Revert"
                      enabled: root.current !== null && root.draftIsDirty()
                      onClicked: root.revertColors()
                    }
                    ActionButton {
                      label: "Save Changes"
                      enabled: root.current !== null && root.current.user
                                 && root.draftIsDirty()
                      busy: saveColorsProc.running
                      onClicked: root.saveColors()
                    }
                  }

                  // Live preview of the theme as typed, so a bad pick is obvious
                  // before saving rather than after.
                  Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: Style.space(64)
                    radius: Style.cornerRadius
                    color: root.normaliseHex(root.draftFor("background")) || Color.background
                    border.width: 1
                    border.color: root.borderColor

                    RowLayout {
                      anchors.fill: parent
                      anchors.margins: Style.space(10)
                      spacing: Style.space(10)

                      Text {
                        Layout.fillWidth: true
                        text: "Aa  The quick brown fox"
                        color: root.normaliseHex(root.draftFor("foreground")) || Color.foreground
                        font.pixelSize: Style.font.title
                        elide: Text.ElideRight
                      }
                      Rectangle {
                        implicitWidth: swatchLabel.implicitWidth + Style.space(16)
                        implicitHeight: swatchLabel.implicitHeight + Style.space(8)
                        radius: Style.cornerRadius
                        color: root.normaliseHex(root.draftFor("accent")) || Color.accent
                        Text {
                          id: swatchLabel
                          anchors.centerIn: parent
                          text: "accent"
                          color: root.normaliseHex(root.draftFor("background")) || Color.background
                          font.pixelSize: Style.font.caption
                          font.weight: Font.DemiBold
                        }
                      }
                      Rectangle {
                        implicitWidth: mutedLabel.implicitWidth + Style.space(16)
                        implicitHeight: mutedLabel.implicitHeight + Style.space(8)
                        radius: Style.cornerRadius
                        color: "transparent"
                        border.width: 1
                        border.color: root.normaliseHex(root.draftFor("muted")) || Color.muted
                        Text {
                          id: mutedLabel
                          anchors.centerIn: parent
                          text: "muted"
                          color: root.normaliseHex(root.draftFor("muted")) || Color.muted
                          font.pixelSize: Style.font.caption
                        }
                      }
                    }
                  }

                  // A ListView rather than a Repeater in a ScrollView, so the
                  // 29 fields are reachable with the arrow keys: the editor is
                  // long and mouse-only navigation through it is tedious.
                  ListView {
                    id: colorList
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    model: root.colorRows
                    // Groups are headers, not editable rows, so start on the
                    // first one below a header rather than on a header itself.
                    currentIndex: root.firstColorRow
                    keyNavigationEnabled: false
                    focus: true
                    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

                    // Arrow keys are handled here rather than left to the
                    // view's own key navigation, which would also stop on the
                    // group headers between the fields.
                    Keys.onUpPressed: root.moveColorCursor(-1)
                    Keys.onDownPressed: root.moveColorCursor(1)
                    Keys.onReturnPressed: root.editColorCursor()
                    Keys.onPressed: function(event) {
                      if (event.text && event.text.length === 1) root.editColorCursor()
                    }

                    delegate: Item {
                      id: colorRow
                      required property var modelData
                      required property int index

                      // True for exactly the one row the keyboard was asked to
                      // edit; the rest ignore it.
                      readonly property bool wantsFocus: root.editingRow === colorRow.index
                      onWantsFocusChanged: if (wantsFocus) focusDelay.restart()

                      // Deferred a turn so the delegate exists and is on screen
                      // before it is asked to take focus.
                      Timer {
                        id: focusDelay
                        interval: 0
                        onTriggered: {
                          hexField.forceActiveFocus()
                          hexField.selectAll()
                        }
                      }

                      readonly property bool isGroup: colorRow.modelData.kind === "group"
                      readonly property string colorKey:
                        colorRow.modelData.kind === "color" ? colorRow.modelData.key : ""
                      readonly property string typed: root.draftFor(colorRow.colorKey)
                      readonly property bool hasText: colorRow.typed !== ""
                      readonly property bool valid: root.normaliseHex(colorRow.typed) !== ""
                      readonly property string shown: colorRow.valid
                        ? root.normaliseHex(colorRow.typed) : ""

                      width: ListView.view.width
                      height: colorRow.isGroup ? Style.space(28) : Style.space(30)

                      // Group header
                      Text {
                        visible: colorRow.isGroup
                        anchors.left: parent.left
                        anchors.bottom: parent.bottom
                        anchors.bottomMargin: Style.space(2)
                        text: colorRow.modelData.title
                        color: Color.accent
                        font.pixelSize: Style.font.caption
                        font.weight: Font.Bold
                        font.capitalization: Font.AllUppercase
                      }

                      // Swatch
                      Rectangle {
                        visible: !colorRow.isGroup
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        width: Style.space(28)
                        height: Style.space(22)
                        radius: 3
                        color: colorRow.shown !== "" ? colorRow.shown : "transparent"
                        border.width: 1
                        border.color: colorRow.hasText && !colorRow.valid
                                      ? Color.urgent : root.borderColor
                      }

                      // Key name
                      Text {
                        visible: !colorRow.isGroup
                        anchors.left: parent.left
                        anchors.leftMargin: Style.space(34)
                        anchors.right: hexBox.left
                        anchors.rightMargin: Style.space(8)
                        anchors.verticalCenter: parent.verticalCenter
                        text: colorRow.colorKey
                        color: Color.muted
                        font.pixelSize: Style.font.caption
                        elide: Text.ElideRight
                      }

                      // Hex field
                      Rectangle {
                        id: hexBox
                        visible: !colorRow.isGroup
                        anchors.right: parent.right
                        anchors.left: parent.left
                        anchors.leftMargin: Style.space(180)
                        anchors.verticalCenter: parent.verticalCenter
                        height: Style.space(24)
                        radius: 3
                        color: Color.background.lighter(1.05)
                        border.width: 1
                        border.color: colorRow.hasText && !colorRow.valid
                                      ? Color.urgent
                                      : (colorList.currentIndex === colorRow.index
                                         ? Color.accent : root.borderColor)

                        TextInput {
                          id: hexField
                          anchors.fill: parent
                          anchors.leftMargin: Style.space(8)
                          anchors.rightMargin: Style.space(8)
                          verticalAlignment: TextInput.AlignVCenter
                          color: Color.foreground
                          font.pixelSize: Style.font.caption
                          font.family: "monospace"
                          selectByMouse: true
                          clip: true
                          // onTextEdited fires only for real typing, so the
                          // binding survives the user's own keystrokes while
                          // still following an external reload.
                          text: colorRow.typed
                          onTextEdited: root.setDraft(colorRow.colorKey, text)
                          // Escape abandons the edit and hands the keyboard
                          // back to the list so the arrows work again.
                          Keys.onEscapePressed: {
                            root.revertColors()
                            root.editingRow = -1
                            colorList.forceActiveFocus()
                          }
                          Keys.onReturnPressed: {
                            root.saveColors()
                            root.editingRow = -1
                            colorList.forceActiveFocus()
                          }
                        }
                      }
                    }
                  }

                  Text {
                    Layout.fillWidth: true
                    visible: root.current !== null
                    text: root.current.user
                          ? (root.draftIsDirty()
                             ? "Unsaved changes. Saving re-applies the theme; the wallpaper does not change."
                             : "Saved colours. Editing the accent redraws the Hyprland border gradient.")
                          : "Stock theme — pick one of your own to edit it."
                    color: root.draftIsDirty() ? Color.accent : Color.muted
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
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
                  onClicked: root.showTab(0)
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
                  onClicked: root.showTab(1)
                }
              }
              Text {
                text: "Colours"
                color: stack.currentIndex === 2 ? Color.accent : Color.muted
                font.pixelSize: Style.font.caption
                font.weight: Font.DemiBold
                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.showTab(2)
                }
              }
            }
          }
        }
      }
    }
  }
}
