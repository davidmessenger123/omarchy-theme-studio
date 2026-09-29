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

## Live updates

The studio keeps itself current, so what it shows is not just what it last did.
While the panel is open:

| Change | How it is noticed |
|---|---|
| `omarchy theme set X` from anywhere | watched `current/theme.name`, immediate |
| A theme created, renamed or removed with the CLI | re-read on a 3 s tick |
| `omarchy theme bg next` or a background set | re-read on a 3 s tick |
| A photo dropped into the picked folder | re-read on a 3 s tick |

Two details worth knowing if you change this:

- **A refresh that finds nothing new changes nothing.** Both listings are
  compared against the previous result and the models are left alone, so the
  sidebar's scroll and the wallpaper grid's cursor survive a tick. An empty
  result is treated as a failed run rather than an empty listing, so a transient
  failure cannot blank the panel.
- **A refresh never interrupts something you asked for.** It is skipped while a
  rename, save, generate or browse is in flight, and the selection is re-found by
  slug rather than index, so a theme appearing cannot silently select a
  different one. Unsaved colour edits survive a refresh too: a theme appearing
  or disappearing renumbers every row after it without changing which theme is
  selected, and the draft is only reloaded when the theme actually changed or
  there is nothing unsaved to lose.

When a refresh does change the list, an `UPDATED` mark appears beside the theme
count for a moment. Silently rearranging a list under someone's pointer is its
own bug.

The tick costs about 150 ms of work every 3 s, and only while the panel is open.
Most of that is the tool's own imports, which is why the watched file exists to
cover the cases that should feel instant.

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
| <kbd>Enter</kbd> / <kbd>Right</kbd> | In the folder browser, open the highlighted folder |
| <kbd>Left</kbd> / <kbd>Backspace</kbd> | In the folder browser, go up a level |
| <kbd>Escape</kbd> | Close the folder browser, leaving the folder in use unchanged |

## Choosing a folder

**Choose Folder…** on Generate opens a browser inside the panel, showing
subfolders with how many images each holds, shortcuts for the folders wallpapers
are usually in, and a path box for typing anywhere on disk.

It is built into the panel rather than handed to the desktop file chooser
because the studio is a layer-shell surface on the overlay layer: a chooser
launched as its own window composites *behind* the studio and its scrim, so it
can be seen but neither clicked nor typed into. Browsing in the panel keeps the
picker somewhere the keyboard already is.

## Image formats

`png jpg jpeg webp bmp gif avif jxl heic tif tiff` are all offered by the picker,
so a phone's camera roll can be used as it is. That is a wider set than a theme
is allowed to *store*, which is the point: anything else is transcoded to png
when it becomes a background, so a `.HEIC` ends up as an ordinary theme
wallpaper.

Qt cannot decode `.heic`, `.avif` or `.jxl`, so those tiles show the format and
filename until a preview has been converted for them. Conversion costs about a
second per image and is cached in `~/.cache/omarchy/theme-studio/`, keyed on the
file's path, size and mtime, so it is paid once and survives restarts.

Stored backgrounds are capped at 4K on the long edge. A 48-megapixel phone photo
written out at full size costs about a minute and 50 MB; capped, the same photo
takes about ten seconds and 17 MB, which is well past any desktop's resolution
and therefore not visible. The cap only shrinks, so a smaller source is never
enlarged.

An image that is already a format a theme may store is copied across untouched
rather than re-encoded, so a large `.jpg` stays exactly as it was. Only the
conversion path downsizes.

## Why a theme came out light when you expected dark

`mode` is the pixel-weighted **mean** lightness of the images, cut at 0.5:

    dark = mean lightness of every image, weighted by pixel count < 0.5

It is the average over the whole set, not the dominant colour and not the
background, so a photo with a bright sky and a dark foreground lands near the
middle. A set of wallpapers is a blend, not a vote: one bright photo among three
dark ones can tip the average, and a high-resolution image counts for more than a
small one because it contributes more pixels.

To see what a set will do before making it:

```sh
omarchy-theme-from-image ~/Pictures/*.HEIC --preview
```

`--preview` prints `mode`, the measurement that decided it, and writes nothing.

## Forcing light or dark

**Auto / Dark / Light** on the Generate page, or `--mode dark|light` on the
command line, overrides the measurement. Reach for it when the wallpaper reads
one way and measures the other — a bright sky over a dark room, or a set that
lands a hair over the threshold.

Forcing a mode also rewrites `colors.toml` of a theme whose wallpapers are
already stored, which is what makes "generate it, then generate it again as
dark" work: normally a re-run finds nothing new to add and leaves the palette
alone. That is deliberate — it is what stops a re-run from silently discarding
edits made on the Colours page — so the studio warns before it happens. It also
means forcing a mode discards those edits for that theme.

`--mode` cannot be combined with `--keep-colors`, which asks for the opposite.

## Adding wallpapers to a theme

<kbd>A</kbd> on Browse, or **Add Wallpaper…**, sends the wallpaper picker at
the selected theme instead of creating a new one. The added images join the set
that `omarchy theme bg next` cycles through, and the theme is re-applied
afterwards.

**Keep current colours** is on by default, so the palette survives untouched.
Turning it off re-derives the palette from the whole set — useful after adding a
wallpaper that should change the theme, but it discards any edits made on the
Colours page.

### The `.sources` file

Each generated theme gets a `.sources` file beside its `colors.toml`, recording
which wallpaper came from which image. It is what stops the same picture being
stored twice under two names: ImageMagick's png encoder is not
byte-reproducible, so a converted `.HEIC` cannot be recognised by comparing it
to the stored copy, and without this record adding the same photo again files a
duplicate every time.

It sits beside `colors.toml` rather than in `backgrounds/`, which
`omarchy-theme-set` scans, so it is never offered as a wallpaper. Deleting it is
harmless — you only lose duplicate detection from then on. Committing it along
with the rest of the theme is fine.

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
    omarchy-theme-from-image --browse ~/Pictures
    omarchy-theme-from-image --thumb ~/Pictures/IMG_3175.HEIC
    omarchy-theme-from-image ~/Pictures/*.HEIC --mode dark
    omarchy-theme-from-image --name evening-green --set-color accent=#ff00aa
    omarchy-theme-from-image --name evening-green --set-color accent=#ff00aa --refresh

`--mode auto|dark|light` forces the palette's light or dark; the default,
`auto`, decides from the images. `--preview` prints the palette without writing
anything. `--browse` describes one
folder as JSON — its parent, its subfolders, and an image count for each — for
the studio's folder browser. `--thumb` converts one image to a cached png
preview and prints the path. ImageMagick does the pixel work; everything after
that is stdlib Python.

## Tests

```sh
python3 -m unittest discover -s tests
```

Covers the pure logic: colour maths, the contrast floor, slug rules, hex
validation, the `colors.toml` rewrite, the folder browser's listing, the format
lists, the preview cache, the source manifest, and forcing the mode. The
palette, conversion and regenerate tests need ImageMagick and are skipped
without it. CI runs these on every push.

QML is not linted in CI — see the comment at the top of `test.yml`. Locally:

```sh
/usr/lib/qt6/bin/qmllint -I /usr/share/omarchy/shell ThemeStudio.qml
```

## License

MIT — see [LICENSE](LICENSE).

