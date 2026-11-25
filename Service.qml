import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Wayland
import QtQuick
import QtQuick.Effects
import qs.Commons

// Focus mode: dims everything behind the focused window, turns the wallpaper
// gray and hides the bar. Toggled over IPC:
//   omarchy-shell focus-mode toggle
// The plugin binds a key for this itself, see "Key binding" below.
Item {
  id: root

  property var shell: null

  readonly property real dimStrength: 0.7
  readonly property int fadeMs: 250
  readonly property string home: Quickshell.env("HOME")
  readonly property string backgroundLink: home + "/.local/state/omarchy/current/background"
  readonly property string barOffFlag: home + "/.local/state/omarchy/toggles/bar-off"

  property bool active: false
  // dim_around strength before focus mode changed it, restored on leaving.
  property real originalDimAround: 0.4
  property bool barWasHidden: false
  // Set while dim_around and its strength still need restoring.
  property bool restorePending: false
  property string wallpaper: ""
  readonly property bool wallpaperIsStill: /\.(jpe?g|png|webp)$/i.test(wallpaper)

  // Opacity of the gray wallpaper, faded between 0 and 1.
  property real grayLevel: 0

  Behavior on grayLevel {
    NumberAnimation { duration: Style.duration(root.fadeMs); easing.type: Easing.OutCubic }
  }

  // hyprctl dispatch and Hyprland.dispatch evaluate `return hl.dispatch(<expr>)`,
  // so anything that is not a single dispatcher runs inside a function that
  // ends with a no-op dispatcher.
  function luaRun(body) {
    Hyprland.dispatch("(function() " + body + " return hl.dsp.no_op() end)()")
  }

  // Hyprland itself names the focused window. Quickshell's activeToplevel
  // stays empty after a shell restart until the focus changes once.
  // Clearing every window first means no stale dim_around survives a window
  // that was closed or moved while focus mode was on.
  function dimLua(on) {
    var body = 'for _, w in ipairs(hl.get_windows()) do ' +
      'hl.dispatch(hl.dsp.window.set_prop({ prop = "dim_around", value = "0", window = w })) end '
    if (on) body += 'local a = hl.get_active_window() ' +
      'if a then hl.dispatch(hl.dsp.window.set_prop({ prop = "dim_around", value = "1", window = a })) end '
    return body
  }

  function strengthLua(value) {
    return "hl.config({ decoration = { dim_around = " + value.toFixed(3) + " } }) "
  }

  // Fades the dim_around strength inside Hyprland. Separate dispatches per
  // frame can arrive out of order, so the whole fade is one dispatch that
  // steps with Hyprland timers. A newer fade stops an older one through the
  // shared counter. `before` is Lua that runs first, `done` Lua that runs
  // after the last step, both within the same dispatch.
  function fadeStrength(to, before, done) {
    var steps = Math.max(1, Math.round(Style.duration(fadeMs) / 16))
    luaRun(before +
      "_G.__focus_mode_fade = (_G.__focus_mode_fade or 0) + 1 " +
      "local id = _G.__focus_mode_fade " +
      "local from = hl.get_config('decoration.dim_around') or 0 " +
      "local step = 0 " +
      "local function tick() " +
      "  if _G.__focus_mode_fade ~= id then return end " +
      "  step = step + 1 " +
      "  local t = 1 - (1 - step / " + steps + ") ^ 3 " +
      "  hl.config({ decoration = { dim_around = from + (" + to.toFixed(3) + " - from) * t } }) " +
      "  if step < " + steps + " then hl.timer(tick, { type = 'oneshot', timeout = 16 }) " +
      "  else " + (done || "") + " end " +
      "end " +
      "tick()")
  }

  function enable() {
    if (active) return
    active = true
    startProc.running = true
  }

  function disable() {
    if (!active) return
    active = false
    grayLevel = 0
    // Once faded out, the windows lose dim_around and the strength returns to
    // what it was.
    fadeStrength(0, "", dimLua(false) + strengthLua(originalDimAround))
    if (!barWasHidden) Quickshell.execDetached(["omarchy-toggle-bar", "off"])
  }

  function toggle() {
    if (active) disable()
    else enable()
  }

  // The fade-out has ended, the next start reads the strength afresh. A
  // toggle back on during the fade-out keeps the strength read before.
  onGrayLevelChanged: {
    if (!active && grayLevel === 0) restorePending = false
  }

  Connections {
    target: Hyprland
    enabled: root.active
    function onActiveToplevelChanged() { root.luaRun(root.dimLua(true)) }
  }

  // Reads the state focus mode needs before it changes anything: the current
  // dim_around strength, whether the bar is already hidden and the wallpaper.
  Process {
    id: startProc
    command: ["bash", "-c",
      'hyprctl getoption decoration:dim_around -j | jq -r ".float"; ' +
      '[[ -f "$1" ]] && echo hidden || echo shown; ' +
      'readlink -f "$2"',
      "focus-mode", root.barOffFlag, root.backgroundLink]
    stdout: StdioCollector {
      onStreamFinished: {
        if (!root.active) return
        var lines = String(text || "").split("\n")
        var strength = parseFloat(lines[0])
        // A fade-out still running has lowered the strength already.
        var wasPending = root.restorePending
        if (!wasPending && !isNaN(strength)) root.originalDimAround = strength
        root.restorePending = true
        root.barWasHidden = lines[1] === "hidden"
        root.wallpaper = String(lines[2] || "").trim()
        if (!root.barWasHidden) Quickshell.execDetached(["omarchy-toggle-bar", "on"])
        // Starting from scratch, the fade begins at 0 rather than at the
        // configured strength.
        root.fadeStrength(root.dimStrength, (wasPending ? "" : root.strengthLua(0)) + root.dimLua(true), "")
        root.grayLevel = 1
      }
    }
  }

  IpcHandler {
    target: "focus-mode"

    function toggle(): void { root.toggle() }
    function on(): void { root.enable() }
    function off(): void { root.disable() }
    function status(): string { return root.active ? "on" : "off" }
  }

  // ------------------------------------------------------------ Key binding
  //
  // The manifest has no field for key bindings, so the plugin binds its key in
  // Hyprland at runtime. The key comes from this plugin's entry in
  // ~/.config/omarchy/shell.json, `"key": "SUPER + D"` by default; an empty
  // string or false binds nothing. A key that already has a binding is left
  // alone, so a binding of the user's own always wins. Runtime bindings are
  // gone after a Hyprland reload, so the plugin binds again after each one.

  readonly property string defaultKey: "SUPER + D"
  readonly property string shellConfigPath: home + "/.config/omarchy/shell.json"
  readonly property string pluginId: "alexzeitler.focus-mode"
  readonly property var modifierBits: ({ SHIFT: 1, CAPS: 2, CTRL: 4, CONTROL: 4, ALT: 8, MOD2: 16, MOD3: 32, SUPER: 64, WIN: 64, LOGO: 64, MOD4: 64, MOD5: 128 })

  // The key as configured, "" when the plugin should bind nothing.
  property string configuredKey: defaultKey
  // The key this plugin has bound, "" when none.
  property string boundKey: ""

  // Third-party plugins do not get the shell's config handed in, so the
  // plugin reads its own entry from disk.
  FileView {
    id: shellConfigFile
    path: root.shellConfigPath
    watchChanges: true
    onFileChanged: reload()
    onLoaded: root.readConfiguredKey()
    onLoadFailed: root.readConfiguredKey()
  }

  function readConfiguredKey() {
    var key = defaultKey
    try {
      var parsed = JSON.parse(String(shellConfigFile.text() || "{}"))
      var entries = parsed && Array.isArray(parsed.plugins) ? parsed.plugins : []
      for (var i = 0; i < entries.length; i++) {
        var entry = entries[i]
        if (!entry || String(entry.id || "") !== pluginId || !("key" in entry)) continue
        key = entry.key === false ? "" : String(entry.key || "")
      }
    } catch (e) {
      // A half-written file keeps the key read before.
      return
    }
    if (key === configuredKey && (boundKey === key || key === "")) return
    configuredKey = key
    updateBinding()
  }

  // Only plain key names reach the Lua string, nothing that could end it.
  function isSafeKey(key) {
    return /^[A-Za-z0-9_:+ ]+$/.test(key)
  }

  // "SUPER + SHIFT + D" as Hyprland lists it in `hyprctl binds -j`.
  function parseKey(key) {
    var parts = key.split("+").map(function(p) { return p.trim() }).filter(function(p) { return p.length > 0 })
    if (parts.length === 0) return null
    var mask = 0
    for (var i = 0; i < parts.length - 1; i++) {
      var bit = modifierBits[parts[i].toUpperCase()]
      if (bit === undefined) return null
      mask |= bit
    }
    return { modmask: mask, key: parts[parts.length - 1].toLowerCase() }
  }

  function updateBinding() {
    if (boundKey) {
      luaRun('hl.unbind("' + boundKey + '") ')
      boundKey = ""
    }
    if (!configuredKey) return
    if (!isSafeKey(configuredKey) || !parseKey(configuredKey)) {
      console.warn("focus-mode: cannot bind key '" + configuredKey + "'")
      return
    }
    if (!bindsProc.running) bindsProc.running = true
  }

  // Lists the bindings Hyprland has, then binds the key if it is free.
  Process {
    id: bindsProc
    command: ["hyprctl", "binds", "-j"]
    stdout: StdioCollector {
      onStreamFinished: {
        var key = root.configuredKey
        var wanted = root.parseKey(key)
        if (!wanted || root.boundKey) return
        var binds = []
        try { binds = JSON.parse(String(text || "[]")) } catch (e) { return }
        for (var i = 0; i < binds.length; i++) {
          var b = binds[i]
          if (b.submap === "" && b.modmask === wanted.modmask && String(b.key || "").toLowerCase() === wanted.key) {
            console.log("focus-mode: " + key + " is taken, not binding it")
            return
          }
        }
        root.luaRun('hl.bind("' + key + '", hl.dsp.exec_cmd("omarchy-shell focus-mode toggle"), ' +
          '{ description = "Toggle focus mode" }) ')
        root.boundKey = key
      }
    }
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (event.name !== "configreloaded") return
      // The reload dropped the runtime binding and reset dim_around.
      root.boundKey = ""
      root.updateBinding()
      if (root.active) root.fadeStrength(root.dimStrength, root.dimLua(true), "")
    }
  }

  // A shell restart must not leave a window dimmed or a key bound.
  Component.onDestruction: {
    if (boundKey) luaRun('hl.unbind("' + boundKey + '") ')
    if (!restorePending) return
    luaRun("_G.__focus_mode_fade = (_G.__focus_mode_fade or 0) + 1 " +
      dimLua(false) + strengthLua(originalDimAround))
  }

  // The gray wallpaper sits on the bottom layer, above Omarchy's background
  // and below every window. It takes no input, so clicks reach the desktop.
  // Video backgrounds are drawn by another program and stay as they are.
  Variants {
    model: Quickshell.screens

    PanelWindow {
      id: panel
      required property var modelData

      screen: modelData
      visible: root.grayLevel > 0 && root.wallpaperIsStill
      anchors { top: true; bottom: true; left: true; right: true }
      color: "transparent"
      exclusionMode: ExclusionMode.Ignore
      mask: Region {}

      WlrLayershell.namespace: "alexzeitler-focus-mode"
      WlrLayershell.layer: WlrLayer.Bottom
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

      // Same fill as Omarchy's background, so the gray copy lines up with it.
      Image {
        id: wallpaperImage
        anchors.fill: parent
        source: root.wallpaperIsStill ? "file://" + root.wallpaper : ""
        fillMode: Image.PreserveAspectCrop
        sourceSize.width: Math.ceil(panel.width * panel.screen.devicePixelRatio)
        sourceSize.height: Math.ceil(panel.height * panel.screen.devicePixelRatio)
        asynchronous: true
        visible: false
      }

      MultiEffect {
        anchors.fill: parent
        source: wallpaperImage
        saturation: -1.0
        opacity: root.grayLevel
      }
    }
  }
}
