# Theme Studio

An Omarchy shell plugin for generating themes from wallpapers and editing them
afterwards.

    omarchy-shell shell summon davidjm.theme-studio '{}'

Also on the launcher menu as **Theme Studio**.

## Install

```sh
git clone https://github.com/davidmessenger123/omarchy-theme-studio.git \
  ~/.config/omarchy/plugins/davidjm.theme-studio
ln -s ~/.config/omarchy/plugins/davidjm.theme-studio/omarchy-theme-from-image \
  ~/.local/bin/omarchy-theme-from-image
omarchy plugin enable davidjm.theme-studio
```

The clone path is not optional: the plugin finds its CLI at
`~/.config/omarchy/plugins/davidjm.theme-studio/omarchy-theme-from-image`, so
the symlink has to point there for both the plugin and the command line to
work. `omarchy plugin enable` registers it in `shell.json`; saving a file under
`~/.config/omarchy/plugins/` reloads the plugin, so the shell does not need
restarting.

To uninstall, remove the directory and `omarchy plugin remove
davidjm.theme-studio`.

### Optional: a launcher menu entry

```sh
omarchy-menu-edit   # or edit ~/.config/omarchy/extensions/omarchy-menu.jsonc
```

Add, under `menu`:

```jsonc
"style.theme-studio": {
  "icon": "",
  "label": "Theme Studio",
  "description": "Generate and manage themes from wallpapers",
  "aliases": ["theme-studio", "theme-from-image"],
  "action": "omarchy-shell shell summon davidjm.theme-studio"
}
```

## Requirements

- [Omarchy](https://omarchy.org) with the shell runtime.
- Python 3 (stdlib only) and ImageMagick (`magick`) for the CLI.

### If you want your themes in git

Omarchy treats a theme directory that contains its own `.git` as third-party
content. A theme is only checked for `<theme>/.git`, so a repository at the
`themes/` level is fine and each theme is still treated as yours:

```sh
git -C ~/.config/omarchy/themes init
```

Do not run `git init` inside an individual `~/.config/omarchy/themes/<name>/`.
That switches the theme to the restricted staging path, which skips symlinks
and ignores `*.lua`, `alacritty.toml`, `foot.ini`, `ghostty.conf`, `kitty.conf`
and `vscode.json` — so a hand-added Neovim or terminal config would silently
stop being applied. Backgrounds and `colors.toml` are unaffected.

## Layout

Three panes, cycled with <kbd>Ctrl</kbd>+<kbd>Tab</kbd> (and the tab strip):

| Pane | What it does |
|---|---|
| **Browse** | Palette and backgrounds of every theme, stock and yours. Apply, rename, add wallpapers, remove. |
| **Generate** | Derive a new theme from wallpapers, or add wallpapers to one of your own. |
| **Colours** | Edit any colour in your own theme's `colors.toml`. |

## Keyboard

The studio is fully operable without a mouse.

| Key | Action |
|---|---|
| <kbd>Ctrl</kbd>+<kbd>Tab</kbd> | Next pane (<kbd>Ctrl</kbd>+<kbd>Shift</kbd>+<kbd>Tab</kbd> for previous) |
| <kbd>Down</kbd> / <kbd>Tab</kbd> | Focus the theme list (Browse) or the wallpaper grid (Generate) |
| <kbd>R</kbd> | Rename the selected theme (Browse) |
| <kbd>A</kbd> | Add wallpapers to the selected theme (Browse) |
| <kbd>Enter</kbd> | In the rename field, commit. On the wallpaper grid, pick the highlighted image. |
| <kbd>Ctrl</kbd>+<kbd>Enter</kbd> | Generate the theme, or add the picked wallpapers (Generate) |
| <kbd>Up</kbd> / <kbd>Down</kbd> | Walk the colour rows, skipping group headers (Colours) |
| <kbd>Enter</kbd> or any character | Start editing the highlighted colour (Colours) |
| <kbd>Enter</kbd> | Save colours. <kbd>Escape</kbd> reverts and returns to the list. |

## Adding wallpapers to a theme

<kbd>A</kbd> on Browse, or **Add Wallpaper…**, sends the wallpaper picker at
the selected theme instead of creating a new one. The added images join the set
that `omarchy theme bg next` cycles through, and the theme is re-applied
afterwards.

**Keep current colours** is on by default, so the palette survives untouched.
Turning it off re-derives the palette from the whole set — useful after adding a
wallpaper that should change the theme, but it discards any edits made on the
Colours page.


## Editing colours

Colours are written to `~/.config/omarchy/themes/<slug>/colors.toml`, and only
the keys you changed are rewritten, so comments, key order and any hand-tuned
values survive. Saving re-applies the theme with `OMARCHY_THEME_SKIP_BACKGROUND=1`,
so the bar, menus and OSD repaint at once but the wallpaper does not jump to the
next image in the set.

The two `hyprland_*_border` tokens are not editable directly: they are a
two-stop gradient derived from the accent, so moving the accent carries them.

## The CLI

`omarchy-theme-from-image` does the work; the plugin is a front end for it. It
lives in this directory and is symlinked to `~/.local/bin`, so command-line use
is unchanged.

    omarchy-theme-from-image ~/Pictures/shot.jpg --name "Evening Green"
    omarchy-theme-from-image --pick --add --keep-colors
    omarchy-theme-from-image --list
    omarchy-theme-from-image --name evening-green --set-color accent=#ff00aa
    omarchy-theme-from-image --name evening-green --set-color accent=#ff00aa --refresh

`--preview` prints the palette without writing anything. ImageMagick does the
pixel work; everything after that is stdlib Python.
