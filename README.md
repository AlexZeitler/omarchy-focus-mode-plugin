# omarchy-focus-mode-plugin

A focus mode for Omarchy. One key press dims everything behind the focused
window, turns the wallpaper gray and hides the bar. The next press brings it
all back.

![Focus mode turning on and off around a PDF viewer](assets/focus-mode.gif)

## Glossary

Service plugin
: A plugin without a bar icon. It runs inside the Omarchy shell, the one
  Quickshell process that also draws the bar and the notifications.

dim_around
: A Hyprland window property. The window it is set on stays as it is,
  everything behind it is darkened.

## What it does

- Darkens everything behind the focused window, other windows and the
  wallpaper alike. The darkening follows the focus to the next window.
- Shows the wallpaper in gray while focus mode is on.
- Hides the bar, and shows it again afterwards. A bar that was hidden before
  stays hidden.
- Fades in and out. With `omarchy toggle animations` off, it switches at once.

## Install

```bash
omarchy plugin add https://github.com/AlexZeitler/omarchy-focus-mode-plugin.git --enable
omarchy restart shell
```

## Key binding

The plugin binds `SUPER + D` itself, as soon as the shell starts. `SUPER + D`
is free in a stock Omarchy.

If the key already has a binding, the plugin leaves it alone and binds
nothing. Your own binding always wins. The shell journal then says
`focus-mode: SUPER + D is taken, not binding it`.

### Another key

Set `key` on the plugin's entry in `~/.config/omarchy/shell.json`:

```json
{
  "id": "alexzeitler.focus-mode",
  "key": "SUPER + SHIFT + D"
}
```

The change applies on save. `"key": false` binds nothing.

### Binding the key yourself

If you would rather keep the binding in your Hyprland config, set
`"key": false` and add this line to `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + D", "Toggle focus mode", "omarchy-shell focus-mode toggle")
```

## Works best with a single square window

Focus mode works best together with Omarchy's single-window square aspect.
Press `SUPER + CTRL + BACKSPACE` to toggle it. A lone window then no longer
spans the whole screen, and the gray wallpaper shows on both sides of it.

## Control

```bash
omarchy-shell focus-mode toggle
omarchy-shell focus-mode on
omarchy-shell focus-mode off
omarchy-shell focus-mode status
```

## Limits

- A video background keeps its colors. Another program draws it, and the
  plugin only grays still images.
- The state is not kept. After a restart of the shell, focus mode is off.
- On a workspace without windows, only the wallpaper turns gray. There is no
  focused window to darken around.

## Remove

```bash
omarchy plugin remove alexzeitler.focus-mode
```

If you bound the key yourself, delete the line from
`~/.config/hypr/bindings.lua` as well.
