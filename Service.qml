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
// The plugin binds a key for this itself, see "Key binding" below. The bar
// widget in Panel.qml sets how strong the dimming and the gray are, and shows
// a preview while its sliders move. The gray applies to the wallpaper and to
// the border of the focused window alike.
Item {
  id: root

  property var shell: null

  readonly property int fadeMs: 250
  readonly property string home: Quickshell.env("HOME")
  readonly property string backgroundLink: home + "/.local/state/omarchy/current/background"
  readonly property string barOffFlag: home + "/.local/state/omarchy/toggles/bar-off"
  readonly property string pluginId: "alexzeitler.focus-mode"

  readonly property real defaultDim: 0.7
  readonly property real defaultGrayscale: 1
  readonly property bool defaultGrayscaleBorder: true

  // Focus mode as toggled by key or IPC.
  property bool active: false
  // The bar widget shows the effect while its sliders move. The bar stays.
  property bool previewing: false
  property real previewDim: defaultDim
  property real previewGrayscale: defaultGrayscale
  property bool previewGrayscaleBorder: defaultGrayscaleBorder

  // Settings from shell.json.
  property real configuredDim: defaultDim
  property real configuredGrayscale: defaultGrayscale
  property bool configuredGrayscaleBorder: defaultGrayscaleBorder

  readonly property bool shown: active || previewing
  readonly property real dimTarget: previewing ? previewDim : configuredDim
  readonly property real grayscaleTarget: previewing ? previewGrayscale : configuredGrayscale
  // The border follows the grayscale amount, unless it is switched off.
  readonly property real borderTarget: (previewing ? previewGrayscaleBorder : configuredGrayscaleBorder) ? grayscaleTarget : 0

  // dim_around strength before focus mode changed it, restored on leaving.
  property real originalDimAround: 0.4
  // Set while dim_around and its strength still need restoring.
  property bool restorePending: false
  property bool barWasHidden: false
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

  // Desaturates the active border by `amount`, 0..1. The theme's colors are
  // kept in a Lua global on first use, so every amount starts from them and
  // leaving focus mode puts them back unchanged. get_config hands colors out
  // as "0xAARRGGBB" and the angle in degrees; hl.config takes rgba() strings.
  function borderLua(amount) {
    return "local o = _G.__focus_mode_border " +
      "if not o then o = hl.get_config('general.col.active_border') _G.__focus_mode_border = o end " +
      "local g = " + amount.toFixed(3) + " " +
      "local function hex2(n) return string.format('%02x', math.floor(n + 0.5)) end " +
      "local cols = {} " +
      "for i, c in ipairs(o.colors) do " +
      "  local v = tonumber(string.sub(c, 3), 16) " +
      "  local a = math.floor(v / 16777216) % 256 " +
      "  local r = math.floor(v / 65536) % 256 " +
      "  local gr = math.floor(v / 256) % 256 " +
      "  local b = v % 256 " +
      "  local l = 0.299 * r + 0.587 * gr + 0.114 * b " +
      "  cols[i] = 'rgba(' .. hex2(r + (l - r) * g) .. hex2(gr + (l - gr) * g) .. hex2(b + (l - b) * g) .. hex2(a) .. ')' " +
      "end " +
      "hl.config({ general = { col = { active_border = { colors = cols, angle = o.angle } } } }) "
  }

  // Puts the theme's border back, if focus mode changed it.
  function restoreBorderLua() {
    return "if _G.__focus_mode_border then " + borderLua(0) + " _G.__focus_mode_border = nil end "
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
    barHideProc.running = true
  }

  function disable() {
    if (!active) return
    active = false
    if (!barWasHidden) Quickshell.execDetached(["omarchy-toggle-bar", "off"])
  }

  function toggle() {
    if (active) disable()
    else enable()
  }

  // Called by the bar widget. Values outside 0..1 are clamped.
  function setPreview(dim, grayscale, grayscaleBorder) {
    previewDim = clamp01(dim, defaultDim)
    previewGrayscale = clamp01(grayscale, defaultGrayscale)
    previewGrayscaleBorder = grayscaleBorder !== false && grayscaleBorder !== "false"
    previewing = true
  }

  function endPreview() {
    previewing = false
  }

  function clamp01(value, fallback) {
    var n = Number(value)
    if (isNaN(n)) return fallback
    return Math.max(0, Math.min(1, n))
  }

  onShownChanged: {
    if (shown) {
      startProc.running = true
      return
    }
    grayLevel = 0
    // Once faded out, the windows lose dim_around and the strength returns to
    // what it was. The border gets its color back at once.
    fadeStrength(0, restoreBorderLua(), dimLua(false) + strengthLua(originalDimAround))
  }

  // A slider sends a stream of values. Only the last one of a burst reaches
  // Hyprland, so an older dispatch cannot overtake it.
  onDimTargetChanged: if (shown && restorePending) dimTimer.restart()

  onBorderTargetChanged: if (shown && restorePending) borderTimer.restart()

  Timer {
    id: borderTimer
    interval: 40
    onTriggered: if (root.shown && root.restorePending) root.luaRun(root.borderLua(root.borderTarget))
  }

  Timer {
    id: dimTimer
    interval: 40
    onTriggered: if (root.shown && root.restorePending) root.fadeStrength(root.dimTarget, "", "")
  }

  // The fade-out has ended, the next start reads the strength afresh. A start
  // during the fade-out keeps the strength read before.
  onGrayLevelChanged: {
    if (!shown && grayLevel === 0) restorePending = false
  }

  Connections {
    target: Hyprland
    enabled: root.shown
    function onActiveToplevelChanged() { root.luaRun(root.dimLua(true)) }
  }

  // Reads the state focus mode needs before it changes anything: the current
  // dim_around strength and the wallpaper.
  Process {
    id: startProc
    command: ["bash", "-c",
      'hyprctl getoption decoration:dim_around -j | jq -r ".float"; readlink -f "$1"',
      "focus-mode", root.backgroundLink]
    stdout: StdioCollector {
      onStreamFinished: {
        if (!root.shown) return
        var lines = String(text || "").split("\n")
        var strength = parseFloat(lines[0])
        // A fade-out still running has lowered the strength already.
        var wasPending = root.restorePending
        if (!wasPending && !isNaN(strength)) root.originalDimAround = strength
        root.restorePending = true
        root.wallpaper = String(lines[1] || "").trim()
        // Starting from scratch, the fade begins at 0 rather than at the
        // configured strength.
        root.fadeStrength(root.dimTarget,
          (wasPending ? "" : root.strengthLua(0)) + root.dimLua(true) + root.borderLua(root.borderTarget), "")
        root.grayLevel = 1
      }
    }
  }

  // Hides the bar unless it is hidden already. A bar the user hid before
  // stays hidden afterwards.
  Process {
    id: barHideProc
    command: ["bash", "-c",
      '[[ -f "$1" ]] && echo hidden || { omarchy-toggle-bar on >/dev/null 2>&1; echo shown; }',
      "focus-mode", root.barOffFlag]
    stdout: StdioCollector {
      onStreamFinished: root.barWasHidden = String(text || "").trim() === "hidden"
    }
  }

  IpcHandler {
    target: "focus-mode"

    function toggle(): void { root.toggle() }
    function on(): void { root.enable() }
    function off(): void { root.disable() }
    function status(): string { return root.active ? "on" : "off" }
    function preview(dim: string, grayscale: string, grayscaleBorder: string): void { root.setPreview(dim, grayscale, grayscaleBorder) }
    function endPreview(): void { root.endPreview() }
  }

  // ------------------------------------------------------------ Settings
  //
  // The settings sit on this plugin's entries in ~/.config/omarchy/shell.json:
  // the entry in `plugins`, and the entry in the bar layout once the bar
  // widget is placed. The bar entry wins where both carry a key.
  //   key        "SUPER + D" by default; "" or false binds nothing
  //   dim        0..1, 0.7 by default
  //   grayscale  0..1, 1 by default; true and false mean 1 and 0
  //   grayscaleBorder  true by default; false keeps the border's colors
  // Third-party plugins do not get the shell's config handed in, so the
  // plugin reads the file itself.

  readonly property string shellConfigPath: home + "/.config/omarchy/shell.json"

  FileView {
    id: shellConfigFile
    path: root.shellConfigPath
    watchChanges: true
    onFileChanged: reload()
    onLoaded: root.readConfig()
    onLoadFailed: root.readConfig()
  }

  function pluginSettings(parsed) {
    var merged = {}
    var entries = parsed && Array.isArray(parsed.plugins) ? parsed.plugins : []
    for (var i = 0; i < entries.length; i++)
      if (entries[i] && String(entries[i].id || "") === pluginId)
        for (var k in entries[i]) merged[k] = entries[i][k]
    var layout = parsed && parsed.bar && parsed.bar.layout ? parsed.bar.layout : {}
    for (var section in layout) {
      var items = Array.isArray(layout[section]) ? layout[section] : []
      for (var j = 0; j < items.length; j++)
        if (items[j] && String(items[j].id || "") === pluginId)
          for (var b in items[j]) merged[b] = items[j][b]
    }
    return merged
  }

  function readConfig() {
    var settings
    try {
      settings = pluginSettings(JSON.parse(String(shellConfigFile.text() || "{}")))
    } catch (e) {
      // A half-written file keeps the settings read before.
      return
    }
    configuredDim = clamp01(settings.dim, defaultDim)
    configuredGrayscale = settings.grayscale === true ? 1
      : settings.grayscale === false ? 0
      : clamp01(settings.grayscale, defaultGrayscale)
    configuredGrayscaleBorder = settings.grayscaleBorder !== false

    var key = defaultKey
    if ("key" in settings) key = settings.key === false ? "" : String(settings.key || "")
    if (key === configuredKey && (boundKey === key || key === "")) return
    configuredKey = key
    updateBinding()
  }

  // ------------------------------------------------------------ Key binding
  //
  // The manifest has no field for key bindings, so the plugin binds its key in
  // Hyprland at runtime. A key that already has a binding is left alone, so a
  // binding of the user's own always wins. Runtime bindings are gone after a
  // Hyprland reload, so the plugin binds again after each one.

  readonly property string defaultKey: "SUPER + D"
  readonly property var modifierBits: ({ SHIFT: 1, CAPS: 2, CTRL: 4, CONTROL: 4, ALT: 8, MOD2: 16, MOD3: 32, SUPER: 64, WIN: 64, LOGO: 64, MOD4: 64, MOD5: 128 })

  // The key as configured, "" when the plugin should bind nothing.
  property string configuredKey: defaultKey
  // The key this plugin has bound, "" when none.
  property string boundKey: ""

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
      // The reload dropped the runtime binding and reset dim_around and the
      // border. The border is read afresh, a theme switch may have changed it.
      root.boundKey = ""
      root.updateBinding()
      if (root.shown) root.fadeStrength(root.dimTarget,
        "_G.__focus_mode_border = nil " + root.dimLua(true) + root.borderLua(root.borderTarget), "")
    }
  }

  // A shell restart must not leave a window dimmed or a key bound.
  Component.onDestruction: {
    if (boundKey) luaRun('hl.unbind("' + boundKey + '") ')
    if (!restorePending) return
    luaRun("_G.__focus_mode_fade = (_G.__focus_mode_fade or 0) + 1 " +
      dimLua(false) + strengthLua(originalDimAround) + restoreBorderLua())
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
        saturation: -root.grayscaleTarget
        opacity: root.grayLevel
      }
    }
  }
}
