# Theme Studio

An Omarchy shell plugin for generating themes from wallpapers and editing them
afterwards.

    omarchy-shell shell summon davidjm.theme-studio '{}'

Also on the launcher menu as **Theme Studio**.

## Layout

Three panes, cycled with <kbd>Ctrl</kbd>+<kbd>Tab</kbd> (and the tab strip):

| Pane | What it does |
|---|---|
| **Browse** | Palette and backgrounds of every theme, stock and yours. Apply, rename, remove. |
| **Generate** | Derive a theme from one or more wallpapers in a folder. |
| **Colours** | Edit any colour in your own theme's `colors.toml`. |

## Keyboard

The studio is fully operable without a mouse.

| Key | Action |
|---|---|
| <kbd>Ctrl</kbd>+<kbd>Tab</kbd> | Next pane (<kbd>Ctrl</kbd>+<kbd>Shift</kbd>+<kbd>Tab</kbd> for previous) |
| <kbd>Down</kbd> / <kbd>Tab</kbd> | Focus the theme list (Browse) |
| <kbd>R</kbd> | Rename the selected theme (Browse) |
| <kbd>Enter</kbd> | Rename is only live in the rename field. |
| <kbd>Up</kbd> / <kbd>Down</kbd> | Walk the colour rows, skipping group headers (Colours) |
| <kbd>Enter</kbd> or any character | Start editing the highlighted colour (Colours) |
| <kbd>Enter</kbd> | Save colours. <kbd>Escape</kbd> reverts and returns to the list. |

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
