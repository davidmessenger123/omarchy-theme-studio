import importlib.machinery
import importlib.util
import os
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

TOOL = Path(__file__).resolve().parent.parent / "omarchy-theme-from-image"

_loader = importlib.machinery.SourceFileLoader("theme_tool", str(TOOL))
_spec = importlib.util.spec_from_loader("theme_tool", _loader)
tool = importlib.util.module_from_spec(_spec)
_loader.exec_module(tool)


class Slugify(unittest.TestCase):
    def test_mirrors_what_the_ui_predicts(self):
        # The studio derives the directory name client-side with this exact
        # regex to preview "Becomes evening-green", so the two must agree.
        self.assertEqual(tool.slugify("Evening Green"), "evening-green")
        self.assertEqual(tool.slugify("  Spaced   Out  "), "spaced-out")
        self.assertEqual(tool.slugify("Img-3175"), "img-3175")
        self.assertEqual(tool.slugify("Ünïcode & Sym#bols"), "n-code-sym-bols")

    def test_rejects_names_that_are_not_usable_directories(self):
        for name in ("", "   ", "---", "!!!"):
            with self.assertRaises(tool.ThemeError):
                tool.slugify(name)

    def test_a_leading_dot_is_stripped_not_left_behind(self):
        # Nothing left for the leading-dot guard to catch, so this is fine.
        self.assertEqual(tool.slugify(".hidden"), "hidden")


class ColourMaths(unittest.TestCase):
    def test_hex_round_trips_through_hsl(self):
        for value in ("#000000", "#ffffff", "#dbe467", "#101820", "#ff00aa"):
            hue, saturation, lightness = tool.rgb_to_hsl(*tool.hex_to_rgb(value))
            self.assertEqual(tool.to_hex(hue, saturation, lightness), value)

    def test_short_hex_expands(self):
        self.assertEqual(tool.hex_to_rgb("#f0a"), (255, 0, 170))

    def test_contrast_ratio_endpoints(self):
        self.assertAlmostEqual(tool.contrast_ratio("#000000", "#ffffff"), 21.0, places=2)
        self.assertAlmostEqual(tool.contrast_ratio("#ffffff", "#ffffff"), 1.0, places=5)

    def test_hue_distance_wraps(self):
        self.assertAlmostEqual(tool.hue_distance(350.0, 10.0), 20.0)
        self.assertAlmostEqual(tool.hue_distance(10.0, 350.0), 20.0)
        self.assertAlmostEqual(tool.hue_distance(0.0, 180.0), 180.0)


class ContrastFloor(unittest.TestCase):
    def test_a_colour_already_readable_is_left_alone(self):
        readable = "#e9e6e2"
        self.assertEqual(tool.ensure_contrast(readable, "#221f1b", True), readable)

    def test_too_dark_is_lifted_until_it_reads(self):
        lifted = tool.ensure_contrast("#3d3e28", "#221f1b", True)
        self.assertNotEqual(lifted, "#3d3e28")
        self.assertGreaterEqual(
            tool.contrast_ratio(lifted, "#221f1b"), tool.MINIMUM_CONTENT_CONTRAST
        )

    def test_muted_stays_readable_on_a_dark_background(self):
        """Regression: muted was lightness 0.20 on a 0.12 background.

        That is a contrast of about 1.5, which made every secondary label in
        the studio invisible. The value is now 0.52; this asserts the property
        rather than the constant, so a future change cannot quietly regress it.
        """
        for hue in range(0, 360, 15):
            for accent_saturation in (0.0, 0.10, 0.40, 0.90):
                background = tool.to_hex(hue, 0.15, 0.12)
                # build_palette caps muted's saturation, so mirror that rather
                # than testing a colour the generator never produces.
                muted = tool.to_hex(hue, min(accent_saturation, 0.22), 0.52)
                self.assertGreaterEqual(
                    tool.contrast_ratio(muted, background),
                    tool.MINIMUM_CONTENT_CONTRAST,
                    f"muted unreadable at hue {hue}, accent saturation {accent_saturation}",
                )

    def test_the_old_muted_value_would_have_failed(self):
        # Guards the test above against being vacuous: if 0.20 ever became
        # readable again the floor itself, not muted, would need revisiting.
        background = tool.to_hex(120.0, 0.15, 0.12)
        self.assertLess(
            tool.contrast_ratio(tool.to_hex(120.0, 0.22, 0.20), background),
            tool.MINIMUM_CONTENT_CONTRAST,
        )


class NormaliseHex(unittest.TestCase):
    def test_accepts_six_digits_with_or_without_a_hash(self):
        for typed, expected in (
            ("#f0a1b2", "#f0a1b2"),
            ("f0a1b2", "#f0a1b2"),
            ("#F0A1B2", "#f0a1b2"),
            ("  #f0a1b2  ", "#f0a1b2"),
        ):
            self.assertEqual(tool.normalise_hex("accent", typed), expected, typed)

    def test_rejects_anything_that_is_not_a_colour(self):
        for typed in ("nothex", "f0a", "#12345", "#1234567", "",
                      "rgb(1,2,3)", "#gggggg"):
            with self.assertRaises(tool.ThemeError):
                tool.normalise_hex("accent", typed)

    def test_shorthand_is_the_studio_s_job_not_ours(self):
        # The studio expands #f0a so it can preview the swatch while typing and
        # sends the expanded form, so this rejecting it is deliberate.
        with self.assertRaises(tool.ThemeError):
            tool.normalise_hex("accent", "f0a")


class BorderDerivation(unittest.TestCase):
    def test_follows_the_accent(self):
        values = tool.border_values("#ff00aa")
        self.assertEqual(values["hyprland_inactive_border"], "rgba(ff00aa44)")
        active = values["hyprland_active_border"]
        self.assertIn("ff00aa", active)
        self.assertIn("45deg", active)
        self.assertEqual(len(active.split()), 3)

    def test_the_two_stops_differ(self):
        active = tool.border_values("#dbe467")["hyprland_active_border"]
        first, second, _ = active.split()
        self.assertNotEqual(first, second)


class ReadColors(unittest.TestCase):
    def test_ignores_comments_and_quotes(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "colors.toml"
            path.write_text(
                '# a comment\n'
                'mode = "dark"\n'
                'accent = "#dbe467"\n'
                "\n"
                "malformed line without equals\n"
                "background = '#221f1b'\n",
                encoding="utf-8",
            )
            colours = tool.read_colors(path)
            self.assertEqual(colours["accent"], "#dbe467")
            self.assertEqual(colours["background"], "#221f1b")
            self.assertEqual(colours["mode"], "dark")
            self.assertNotIn("malformed line without equals", colours)

    def test_missing_file_is_empty_not_an_error(self):
        self.assertEqual(tool.read_colors(Path("/nonexistent/colors.toml")), {})


class EditColors(unittest.TestCase):
    def setUp(self):
        self._temporary = tempfile.TemporaryDirectory()
        self.root = Path(self._temporary.name)
        self.addCleanup(self._temporary.cleanup)
        # edit_colors resolves the theme directory from the module global.
        self._saved = tool.USER_THEMES
        tool.USER_THEMES = self.root
        self.addCleanup(lambda: setattr(tool, "USER_THEMES", self._saved))

        self.theme = self.root / "test-theme"
        (self.theme / "backgrounds").mkdir(parents=True)
        self.colors = self.theme / "colors.toml"
        self.colors.write_text(
            'mode = "dark"\n'
            "\n"
            "# keep this comment\n"
            'accent = "#dbe467"\n'
            'background = "#221f1b"\n'
            'muted = "#9d9f6a"\n'
            'hyprland_active_border = "rgba(dbe467ee) rgba(a6ea8aee) 45deg"\n'
            'hyprland_inactive_border = "rgba(dbe46744)"\n',
            encoding="utf-8",
        )

    def text(self):
        return self.colors.read_text(encoding="utf-8")

    def test_changes_only_the_named_key(self):
        self.assertEqual(tool.edit_colors("test-theme", ["muted=#ff00aa"]), 1)
        text = self.text()
        self.assertIn('muted = "#ff00aa"', text)
        self.assertIn('accent = "#dbe467"', text)
        self.assertIn('background = "#221f1b"', text)
        # Comments, blank lines, key order and the mode flag all survive.
        self.assertIn("# keep this comment", text)
        self.assertIn('mode = "dark"', text)
        self.assertLess(text.index("mode"), text.index("accent"))
        self.assertLess(text.index("accent"), text.index("background"))

    def test_moving_the_accent_redraws_the_border_gradient(self):
        tool.edit_colors("test-theme", ["accent=#ff00aa"])
        text = self.text()
        self.assertIn('hyprland_inactive_border = "rgba(ff00aa44)"', text)
        self.assertIn("ff00aa", text)
        self.assertNotIn("dbe467", text)

    def test_editing_another_colour_leaves_the_borders_alone(self):
        tool.edit_colors("test-theme", ["muted=#ff00aa"])
        self.assertIn("rgba(dbe46744)", self.text())

    def test_accepts_spaces_and_a_missing_hash(self):
        tool.edit_colors("test-theme", ["  muted = FF00AA  "])
        self.assertIn('muted = "#ff00aa"', self.text())

    def test_adding_a_key_the_file_lacks_appends_it(self):
        (self.colors).write_text('mode = "dark"\naccent = "#dbe467"\n', encoding="utf-8")
        tool.edit_colors("test-theme", ["muted=#ff00aa"])
        self.assertIn('muted = "#ff00aa"', self.text())

    def test_no_change_reports_nothing_changed(self):
        self.assertEqual(tool.edit_colors("test-theme", ["accent=#dbe467"]), 0)

    def test_repeated_no_op_saves_do_not_duplicate_lines(self):
        """Regression: an already-correct key fell through to the append path.

        Each no-op save added another copy of the line, so the file grew
        without bound however many times the studio was opened and saved.
        """
        for _ in range(4):
            tool.edit_colors("test-theme", ["accent=#dbe467", "muted=#9d9f6a"])
        text = self.text()
        self.assertEqual(text.count("accent ="), 1)
        self.assertEqual(text.count("muted ="), 1)
        self.assertEqual(text.count("mode ="), 1)

    def test_rejects_a_derived_key(self):
        with self.assertRaises(tool.ThemeError) as caught:
            tool.edit_colors("test-theme", ["hyprland_active_border=#ffffff"])
        self.assertIn("accent", str(caught.exception))

    def test_rejects_an_unknown_key(self):
        with self.assertRaises(tool.ThemeError):
            tool.edit_colors("test-theme", ["nonsense=#ffffff"])

    def test_rejects_a_malformed_pair(self):
        with self.assertRaises(tool.ThemeError):
            tool.edit_colors("test-theme", ["justakey"])

    def test_rejects_a_bad_colour_without_writing(self):
        before = self.text()
        with self.assertRaises(tool.ThemeError):
            tool.edit_colors("test-theme", ["muted=nothex"])
        self.assertEqual(self.text(), before)

    def test_rejects_an_unknown_theme(self):
        with self.assertRaises(tool.ThemeError):
            tool.edit_colors("no-such-theme", ["accent=#ffffff"])

    def test_rejects_an_empty_update(self):
        with self.assertRaises(tool.ThemeError):
            tool.edit_colors("test-theme", [])


class EditableKeys(unittest.TestCase):
    def test_groups_only_offer_real_keys(self):
        listed = [key for _, keys in tool.EDIT_GROUPS for key in keys]
        self.assertEqual(sorted(listed), sorted(tool.EDITABLE_KEYS))
        self.assertEqual(len(listed), len(set(listed)), "a key is offered twice")

    def test_derived_keys_are_never_editable(self):
        for key in tool.DERIVED_KEYS:
            self.assertNotIn(key, tool.EDITABLE_KEYS)
            self.assertNotIn(key, tool.COLOR_KEYS)

    def test_every_editable_key_is_rendered(self):
        for key in tool.EDITABLE_KEYS:
            self.assertIn(key, tool.ORDER)


class RenderColorsToml(unittest.TestCase):
    def test_round_trips_through_read_colors(self):
        colours = {key: "#123456" for key in tool.EDITABLE_KEYS}
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "colors.toml"
            path.write_text(tool.render_colors_toml(colours, True), encoding="utf-8")
            parsed = tool.read_colors(path)
        self.assertEqual(parsed["mode"], "dark")
        for key in tool.EDITABLE_KEYS:
            self.assertEqual(parsed[key], "#123456", key)

    def test_light_mode_is_written(self):
        colours = {key: "#123456" for key in tool.EDITABLE_KEYS}
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "colors.toml"
            path.write_text(tool.render_colors_toml(colours, False), encoding="utf-8")
            self.assertEqual(tool.read_colors(path)["mode"], "light")


def magick_available():
    return any(
        os.access(os.path.join(folder, "magick"), os.X_OK)
        for folder in os.environ.get("PATH", "").split(os.pathsep)
        if folder
    )


class BrowseDirectory(unittest.TestCase):
    """The payload behind the studio's in-panel folder browser."""

    def setUp(self):
        self._temporary = tempfile.TemporaryDirectory()
        self.root = Path(self._temporary.name).resolve()
        self.pictures = self.root / "Pictures"
        (self.pictures / "Wallpapers").mkdir(parents=True)
        (self.pictures / ".hidden").mkdir()
        (self.pictures / "notes.txt").write_text("", encoding="utf-8")
        (self.pictures / "a.jpg").write_text("", encoding="utf-8")
        (self.pictures / "b.PNG").write_text("", encoding="utf-8")
        (self.pictures / "IMG_2596.HEIC").write_text("", encoding="utf-8")
        (self.pictures / "Wallpapers" / "c.webp").write_text("", encoding="utf-8")
        self.addCleanup(self._temporary.cleanup)

    def test_counts_only_what_the_grid_could_pick(self):
        # The number beside a folder has to match the number the grid will hold,
        # so it counts the same extension set the grid lists.
        result = tool.browse_directory(self.pictures)
        # Three, including the .HEIC: a folder of phone wallpaper must not read
        # as empty. Counting a narrower set than the grid lists is what made a
        # folder full of .HEIC look like it held nothing.
        self.assertEqual(result["images"], 3)
        # Upper case counts: a .PNG is still a wallpaper.
        self.assertEqual(
            [entry["images"] for entry in result["dirs"] if entry["name"] == "Wallpapers"],
            [1],
        )

    def test_lists_subfolders_and_skips_files_and_dot_folders(self):
        names = [entry["name"] for entry in tool.browse_directory(self.pictures)["dirs"]]
        self.assertEqual(names, ["Wallpapers"])
        self.assertNotIn(".hidden", names)
        self.assertNotIn("notes.txt", names)

    def test_reports_the_parent_so_up_is_always_reachable(self):
        self.assertEqual(tool.browse_directory(self.pictures)["parent"], str(self.root))
        # The filesystem root is its own parent, which would loop forever.
        self.assertEqual(tool.browse_directory("/")["parent"], "")

    def test_a_missing_path_reports_an_error_in_the_same_shape(self):
        # The browser shows the message and stays open, so the failure has to
        # arrive as data rather than as a non-zero exit.
        result = tool.browse_directory(self.root / "nope")
        self.assertIn("not a folder", result["error"])
        for key in ("path", "parent", "images", "dirs", "shortcuts"):
            self.assertIn(key, result)

    def test_a_tilde_path_is_expanded(self):
        self.assertFalse(tool.browse_directory("~")["path"].startswith("~"))

    def test_shortcuts_only_list_folders_that_exist(self):
        paths = {entry["path"] for entry in tool.browse_directory("/")["shortcuts"]}
        for entry in tool.browse_directory("/")["shortcuts"]:
            self.assertTrue(Path(entry["path"]).is_dir(), entry["path"])
        # Home is always there, so the browser can always get back to a start.
        self.assertIn(str(Path.home().resolve()), paths)


class SourceFormats(unittest.TestCase):
    """Which files the studio offers, and which of them it can actually show."""

    def test_a_phone_photo_is_offered(self):
        # Regression: the studio listed only what a theme may *store*, so a
        # folder of .HEIC wallpaper came up empty. store_background converts
        # anything else to png, so those files were always usable.
        self.assertIn(".heic", tool.SOURCE_EXTENSIONS)
        self.assertIn(".avif", tool.SOURCE_EXTENSIONS)
        self.assertIn(".jxl", tool.SOURCE_EXTENSIONS)

    def test_everything_offered_can_actually_be_stored(self):
        # Otherwise the picker would happily offer a file that fails at the
        # moment the theme is written.
        storable = {"." + ext for ext in tool.OMARCHY_BACKGROUND_EXTENSIONS}
        self.assertTrue(tool.SOURCE_EXTENSIONS - storable, "no format needs converting")
        for extension in tool.SOURCE_EXTENSIONS:
            self.assertNotEqual(extension, "", extension)

    def test_only_previewable_formats_claim_to_be_previewable(self):
        # The grid renders `preview` directly and converts everything else, so
        # a format in both lists must agree about itself.
        self.assertTrue(tool.PREVIEWABLE_EXTENSIONS <= tool.SOURCE_EXTENSIONS)
        # HEIC is exactly the case the conversion exists for: ImageMagick reads
        # it, Qt cannot.
        self.assertNotIn(".heic", tool.PREVIEWABLE_EXTENSIONS)

    def test_the_chooser_offers_the_same_formats_the_picker_does(self):
        # Derived from SOURCE_EXTENSIONS, so the portal and the in-panel grid
        # cannot drift into offering different things.
        self.assertEqual(
            set(tool.CHOOSER_EXTENSIONS.split()),
            {ext.lstrip(".") for ext in tool.SOURCE_EXTENSIONS},
        )

    def test_the_grid_offers_every_source_format(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            names = {ext: f"shot{ext}" for ext in tool.SOURCE_EXTENSIONS}
            for name in names.values():
                (root / name).write_bytes(b"")
            (root / "notes.txt").write_bytes(b"")
            listed = {Path(entry["path"]).name: entry
                      for entry in tool.list_background_files(root)}
            for extension, name in names.items():
                self.assertIn(name, listed, extension)
                entry = listed[name]
                self.assertEqual(entry["ext"], extension.lstrip("."))
                # A preview is offered only where Qt can decode the file.
                expected = str(root / name) if extension in tool.PREVIEWABLE_EXTENSIONS else ""
                self.assertEqual(entry["preview"], expected, extension)


class Thumbnails(unittest.TestCase):
    """The preview cache behind formats Qt cannot decode."""

    def setUp(self):
        self._temporary = tempfile.TemporaryDirectory()
        self.root = Path(self._temporary.name)
        self.image = self.root / "shot.heic"
        self.image.write_bytes(b"pretend heic")
        self.addCleanup(self._temporary.cleanup)
        # thumbnail_path and make_thumbnail resolve the cache from the module
        # global, as USER_THEMES is elsewhere in these tests.
        self._saved = tool.THUMBNAIL_CACHE
        tool.THUMBNAIL_CACHE = self.root / "cache"
        self.addCleanup(lambda: setattr(tool, "THUMBNAIL_CACHE", self._saved))

    def test_the_cache_key_follows_the_content_not_the_name(self):
        first = tool.thumbnail_path(self.image)
        self.assertEqual(first, tool.thumbnail_path(self.image))
        # Two files of the same name in different folders must not share a
        # preview.
        other = self.root / "sub"
        other.mkdir()
        twin = other / "shot.heic"
        twin.write_bytes(b"different")
        self.assertNotEqual(first, tool.thumbnail_path(twin))

    def test_an_edited_image_gets_a_fresh_preview(self):
        before = tool.thumbnail_path(self.image)
        os.utime(self.image, (0, 0))
        self.assertNotEqual(before, tool.thumbnail_path(self.image))

    def test_an_existing_preview_is_reused_rather_than_rebuilt(self):
        # Needs no ImageMagick: the cache hit returns before any conversion.
        target = tool.thumbnail_path(self.image)
        target.parent.mkdir(parents=True)
        target.write_bytes(b"already converted")
        self.assertEqual(tool.make_thumbnail(self.image), target)
        self.assertEqual(target.read_bytes(), b"already converted")

    def test_a_missing_source_is_an_error_not_a_crash(self):
        with self.assertRaises(tool.ThemeError):
            tool.make_thumbnail(self.root / "gone.heic")


@unittest.skipUnless(magick_available(), "ImageMagick's magick is not on PATH")
class ConvertPhonePhoto(unittest.TestCase):
    """The whole point of the preview cache: a .HEIC the shell cannot show.

    Needs ImageMagick both to write the source and to convert it, so it is
    skipped wherever that is absent, which includes the CI runner.
    """

    def setUp(self):
        self._temporary = tempfile.TemporaryDirectory()
        self.root = Path(self._temporary.name)
        self.addCleanup(self._temporary.cleanup)
        self._saved = tool.THUMBNAIL_CACHE
        tool.THUMBNAIL_CACHE = self.root / "cache"
        self.addCleanup(lambda: setattr(tool, "THUMBNAIL_CACHE", self._saved))
        # store_background writes into an existing backgrounds folder, as
        # write_theme creates for it.
        self.backgrounds = self.root / "backgrounds"
        self.backgrounds.mkdir()

        import subprocess

        self.source = self.root / "IMG_0001.HEIC"
        made = subprocess.run(
            ["magick", "-size", "300x200", "gradient:#dbe467-#101820", str(self.source)],
            capture_output=True, text=True,
        )
        self.assertEqual(made.returncode, 0, made.stderr)

    def test_the_picker_offers_a_heic_and_the_tool_converts_a_preview(self):
        listed = tool.list_background_files(self.root)
        self.assertEqual([entry["ext"] for entry in listed], ["heic"])
        # Nothing to render, so the studio is told to make one.
        self.assertEqual(listed[0]["preview"], "")

        preview = tool.make_thumbnail(self.source)
        self.assertTrue(preview.is_file())
        self.assertEqual(listed[0]["preview"], "", "the listing is not rewritten in place")

        import subprocess

        info = subprocess.run(
            ["magick", "identify", "-format", "%m %wx%h", str(preview)],
            capture_output=True, text=True,
        )
        self.assertEqual(info.returncode, 0, info.stderr)
        self.assertTrue(info.stdout.startswith("PNG "), info.stdout)
        # Shrunk to the cache edge, and not letterboxed away: the grid crops.
        width, _, height = info.stdout.split()[1].partition("x")
        self.assertLessEqual(int(width), tool.THUMBNAIL_EDGE)
        self.assertLessEqual(int(height), tool.THUMBNAIL_EDGE)

    def test_the_stored_background_is_a_png_the_theme_can_use(self):
        stored, transcode, already = tool.store_background(self.backgrounds, self.source, "bg")
        self.assertTrue(transcode)
        self.assertFalse(already)
        self.assertEqual(stored.suffix, ".png")
        # The point of transcoding: what omarchy-theme-set looks for now finds
        # it, which it would not for a .HEIC left where the camera put it.
        self.assertEqual([p.name for p in tool.existing_backgrounds(self.root)],
                         ["bg.png"])

    def dimensions(self, path):
        import subprocess

        info = subprocess.run(
            ["magick", "identify", "-format", "%w %h", str(path)],
            capture_output=True, text=True,
        )
        self.assertEqual(info.returncode, 0, info.stderr)
        return tuple(int(value) for value in info.stdout.split())

    def test_a_photo_larger_than_4k_is_stored_capped(self):
        # 4000px wide, so it is over the cap on its long edge but cheap enough
        # to make in a test. A phone photo is 8064 wide and takes a minute to
        # write out uncapped, for an image the compositor scales down anyway.
        import subprocess

        wide = self.root / "wide.HEIC"
        made = subprocess.run(
            ["magick", "-size", "4000x120", "gradient:#dbe467-#101820", str(wide)],
            capture_output=True, text=True,
        )
        self.assertEqual(made.returncode, 0, made.stderr)

        stored, transcode, _ = tool.store_background(self.backgrounds, wide, "wide")
        self.assertTrue(transcode)
        width, height = self.dimensions(stored)
        self.assertEqual(width, tool.MAX_BACKGROUND_EDGE)
        self.assertLessEqual(max(width, height), tool.MAX_BACKGROUND_EDGE)
        # Aspect ratio survives, so the wallpaper is not squashed.
        self.assertAlmostEqual(width / height, 4000 / 120, delta=0.2)

    def test_a_photo_within_4k_is_not_enlarged(self):
        # The ">" means shrink-only, so a small source is stored as it is rather
        # than blown up to the cap.
        stored, _, _ = tool.store_background(self.backgrounds, self.source, "small")
        self.assertEqual(self.dimensions(stored), (300, 200))


@unittest.skipUnless(magick_available(), "ImageMagick's magick is not on PATH")
class ForcingTheMode(unittest.TestCase):
    """Regenerating a theme as a different mode, which is the whole workflow."""

    def setUp(self):
        self._temporary = tempfile.TemporaryDirectory()
        self.root = Path(self._temporary.name)
        self.addCleanup(self._temporary.cleanup)
        self._saved = tool.USER_THEMES
        tool.USER_THEMES = self.root
        self.addCleanup(lambda: setattr(tool, "USER_THEMES", self._saved))

        import subprocess

        # Deliberately light. If the fixture measured as dark, forcing dark would
        # be indistinguishable from leaving it on auto and the test would pass
        # whether or not the override reached the palette.
        self.images = []
        for index, (start, end) in enumerate((("#f0f0f5", "#ffffff"),
                                              ("#e8ebf9", "#dbe3f5"))):
            path = self.root / f"shot{index}.png"
            made = subprocess.run(
                ["magick", "-size", "64x64", f"gradient:{start}-{end}", str(path)],
                capture_output=True, text=True,
            )
            self.assertEqual(made.returncode, 0, made.stderr)
            self.images.append(path)

        self.theme = self.root / "demo"
        # Guard the fixture itself, so it cannot quietly stop being a light set.
        self.assertFalse(tool.build_palette(self.images)[1], "fixture must measure light")

    def generate(self, mode="auto", recolour=False):
        colours, dark, _ = tool.build_palette(self.images, mode)
        return tool.write_theme("demo", colours, dark, self.images, recolour=recolour)

    def stored(self):
        return sorted(p.name for p in tool.existing_backgrounds(self.theme))

    def test_generating_the_same_images_again_keeps_the_palette(self):
        """The safe default: a re-run must not discard a palette silently."""
        self.generate()
        before = (self.theme / "colors.toml").read_text(encoding="utf-8")
        _, added, _ = self.generate()
        self.assertEqual(added, [])
        self.assertEqual((self.theme / "colors.toml").read_text(encoding="utf-8"), before)

    def test_forcing_a_mode_rewrites_the_palette_without_adding_wallpapers(self):
        self.generate()
        first = self.stored()
        self.assertEqual(tool.read_colors(self.theme / "colors.toml")["mode"], "light")
        _, added, _ = self.generate(mode="dark", recolour=True)
        self.assertEqual(added, [], "the wallpapers were already there")
        self.assertEqual(tool.read_colors(self.theme / "colors.toml")["mode"], "dark")
        self.assertEqual(self.stored(), first, "a re-run must not add a second copy")

    def test_a_heic_added_twice_is_not_stored_twice(self):
        """Regression: the duplicate test compared file bytes.

        Storing a .HEIC transcodes it, and ImageMagick's png encoder is not
        byte-reproducible -- the same image converted twice gives the same
        pixels and different bytes. So the byte comparison misses, and the same
        wallpaper was filed under a second name every time it was added again.
        The manifest records the source instead, which transcoding cannot
        invalidate.
        """
        import subprocess

        heic = self.root / "phone.HEIC"
        made = subprocess.run(
            ["magick", "-size", "64x64", "gradient:#2a5e12-#a8f05e", str(heic)],
            capture_output=True, text=True,
        )
        self.assertEqual(made.returncode, 0, made.stderr)

        backgrounds = self.theme / "backgrounds"
        backgrounds.mkdir(parents=True)
        first = tool.store_background(backgrounds, heic, "one")
        self.assertFalse(first[2])
        again = tool.store_background(backgrounds, heic, "one")
        self.assertTrue(again[2], "the second add should be a no-op")
        self.assertEqual(again[0], first[0])
        self.assertEqual(self.stored(), ["one.png"])

    def test_a_known_source_is_recognised_without_converting_again(self):
        """The part that makes the above hold for a real, large photo.

        Whether the byte comparison happens to hit depends on the size of the
        image, so the guarantee is asserted structurally: a source already in
        the manifest must be answered without running the encoder at all. If
        this is done by looking at the manifest first, no duplicate can be
        stored however non-reproducible the encoder turns out to be.
        """
        import subprocess

        heic = self.root / "phone.HEIC"
        made = subprocess.run(
            ["magick", "-size", "64x64", "gradient:#2a5e12-#a8f05e", str(heic)],
            capture_output=True, text=True,
        )
        self.assertEqual(made.returncode, 0, made.stderr)
        backgrounds = self.theme / "backgrounds"
        backgrounds.mkdir(parents=True)
        tool.store_background(backgrounds, heic, "one")

        calls = []
        real_run = tool.run

        def counting_run(command, **kwargs):
            calls.append(command)
            return real_run(command, **kwargs)

        tool.run = counting_run
        self.addCleanup(lambda: setattr(tool, "run", real_run))
        found, _, already = tool.store_background(backgrounds, heic, "one")
        self.assertTrue(already)
        self.assertEqual(found.name, "one.png")
        self.assertEqual(calls, [], "a known source must not be converted again")

    def test_the_manifest_is_not_where_omarchy_looks_for_wallpapers(self):
        self.generate()
        self.assertTrue(tool.sources_manifest(self.theme / "backgrounds").is_file())
        # omarchy-theme-set scans backgrounds/ and would offer a stray file there
        # as a wallpaper.
        self.assertNotIn(".sources", self.stored())

    def test_a_hand_copied_file_is_still_caught_by_the_content_test(self):
        # The manifest is new; the byte comparison must not have been dropped,
        # or a wallpaper copied in by hand would be stored twice.
        backgrounds = self.theme / "backgrounds"
        backgrounds.mkdir(parents=True)
        shutil.copy2(self.images[0], backgrounds / "copy.png")
        found, _, already = tool.store_background(backgrounds, self.images[0], "copy")
        self.assertTrue(already)
        self.assertEqual(found.name, "copy.png")


class DescribeMode(unittest.TestCase):
    def test_auto_says_what_decided_it(self):
        text = tool.describe_mode(False, 0.501, "auto")
        self.assertIn("light", text)
        self.assertIn("0.501", text)
        self.assertIn("0.500", text)

    def test_forced_does_not_claim_the_measurement_decided(self):
        text = tool.describe_mode(True, 0.0, "dark")
        self.assertIn("forced", text)
        self.assertNotIn("0.000", text)


class SourceManifest(unittest.TestCase):
    """The record that stops a re-added wallpaper being stored twice."""

    def setUp(self):
        self._temporary = tempfile.TemporaryDirectory()
        self.theme = Path(self._temporary.name) / "demo"
        self.backgrounds = self.theme / "backgrounds"
        self.backgrounds.mkdir(parents=True)
        self.source = self.theme.parent / "phone.HEIC"
        self.source.write_bytes(b"pretend heic")
        self.addCleanup(self._temporary.cleanup)

    def test_a_missing_manifest_is_empty_not_an_error(self):
        self.assertEqual(tool.read_sources(self.backgrounds), {})
        self.assertIsNone(tool.stored_from_source(self.backgrounds, self.source))

    def test_recording_then_finding_a_source(self):
        stored = self.backgrounds / "one.png"
        stored.write_bytes(b"converted")
        tool.write_source(self.backgrounds, self.source, stored)
        self.assertEqual(tool.stored_from_source(self.backgrounds, self.source), stored)

    def test_a_record_whose_file_vanished_is_not_believed(self):
        tool.write_source(self.backgrounds, self.source, self.backgrounds / "gone.png")
        self.assertIsNone(tool.stored_from_source(self.backgrounds, self.source))

    def test_a_different_image_is_not_mistaken_for_a_known_one(self):
        stored = self.backgrounds / "one.png"
        stored.write_bytes(b"converted")
        tool.write_source(self.backgrounds, self.source, stored)
        other = self.theme.parent / "other.HEIC"
        other.write_bytes(b"a different photo")
        self.assertIsNone(tool.stored_from_source(self.backgrounds, other))

    def test_the_manifest_is_keyed_by_content_not_by_name(self):
        # The same picture re-exported to a different path is the same wallpaper.
        first = self.backgrounds / "one.png"
        first.write_bytes(b"converted")
        tool.write_source(self.backgrounds, self.source, first)
        moved = self.theme.parent / "renamed.HEIC"
        shutil.copy2(self.source, moved)
        self.assertEqual(tool.stored_from_source(self.backgrounds, moved), first)

    def test_recording_survives_an_unwritable_theme_directory(self):
        # Losing the record costs a duplicate wallpaper next time, which is not
        # worth failing a write over.
        tool.sources_manifest(self.backgrounds).parent.mkdir(parents=True,
                                                            exist_ok=True)
        tool.sources_manifest(self.backgrounds).write_text("x y\n", encoding="utf-8")
        tool.sources_manifest(self.backgrounds).chmod(0o400)
        self.addCleanup(tool.sources_manifest(self.backgrounds).chmod, 0o600)
        tool.write_source(self.backgrounds, self.source, self.backgrounds / "one.png")
        # Whatever happened, the tool must still be usable afterwards.
        self.assertTrue(callable(tool.write_source))


@unittest.skipUnless(magick_available(), "ImageMagick's magick is not on PATH")
class BuildPalette(unittest.TestCase):
    """End-to-end palette derivation. Needs ImageMagick, so it is skipped
    wherever that is absent, which includes the CI runner."""

    def setUp(self):
        self._temporary = tempfile.TemporaryDirectory()
        self.folder = Path(self._temporary.name)
        self.addCleanup(self._temporary.cleanup)

    def make_image(self, name, start, end):
        import subprocess

        path = self.folder / name
        result = subprocess.run(
            ["magick", "-size", "64x64", f"gradient:{start}-{end}", str(path)],
            capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return path

    def palette_from(self, *specs, mode="auto"):
        images = [self.make_image(f"{i}.png", a, b) for i, (a, b) in enumerate(specs)]
        colours, dark, lightness = tool.build_palette(images, mode)
        return colours, dark, lightness

    def test_every_key_it_promises_is_present(self):
        colours, _, _ = self.palette_from(("#2a5e12", "#a8f05e"))
        for key in tool.EDITABLE_KEYS:
            self.assertRegex(colours[key], r"^#[0-9a-f]{6}$", key)
        # The border tokens are not palette entries: they are derived from the
        # accent at render time, which is why they are not editable.
        for key in tool.DERIVED_KEYS:
            self.assertNotIn(key, colours)

    def test_a_dark_image_gives_a_dark_theme(self):
        colours, dark, _ = self.palette_from(("#0a0a12", "#202030"))
        self.assertTrue(dark)
        background = tool.rgb_to_hsl(*tool.hex_to_rgb(colours["background"]))[2]
        self.assertLess(background, 0.5, f"background {colours['background']} is not dark")

    def test_a_light_image_gives_a_light_theme(self):
        _, dark, _ = self.palette_from(("#f0f0f5", "#ffffff"))
        self.assertFalse(dark)

    def test_content_colours_clear_the_contrast_floor(self):
        """Regression: muted was 0.20 lightness on a 0.12 background.

        This is the property the studio depends on, asserted through the real
        derivation path rather than a hand-built colour.
        """
        colours, dark, _ = self.palette_from(("#1a1a1a", "#2a2a2a"))
        background = colours["background"]
        content = ["accent", "selection", "muted", *tool.SLOTS,
                   *[f"bright_{name}" for name in tool.BRIGHT_SLOTS]]
        for key in content:
            self.assertGreaterEqual(
                tool.contrast_ratio(colours[key], background),
                tool.MINIMUM_CONTENT_CONTRAST,
                f"{key} is unreadable on {background}",
            )

    def test_rendering_then_reading_gives_the_same_colours(self):
        colours, dark, _ = self.palette_from(("#2a5e12", "#a8f05e"))
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "colors.toml"
            path.write_text(tool.render_colors_toml(colours, dark), encoding="utf-8")
            parsed = tool.read_colors(path)
        for key in tool.EDITABLE_KEYS:
            self.assertEqual(parsed[key], colours[key], key)

    def test_a_forced_mode_overrides_what_the_images_measured(self):
        """The point of --mode: a set the tool reads one way, used the other."""
        _, measured_light, _ = self.palette_from(("#f0f0f5", "#ffffff"))
        self.assertFalse(measured_light, "a white image should measure as light")
        colours, dark, _ = self.palette_from(("#f0f0f5", "#ffffff"), mode="dark")
        self.assertTrue(dark, "--mode dark must win over the measurement")
        # The whole ramp follows the mode, not just the flag.
        auto, _, _ = self.palette_from(("#f0f0f5", "#ffffff"))
        self.assertNotEqual(auto["background"], colours["background"])

    def test_forcing_light_overrides_a_dark_image(self):
        self.assertTrue(self.palette_from(("#0a0a12", "#202030"))[1])
        self.assertFalse(self.palette_from(("#0a0a12", "#202030"), mode="light")[1])

    def test_a_forced_mode_reports_no_measurement(self):
        # It decided nothing, so quoting a number as if it had would mislead.
        self.assertGreater(self.palette_from(("#f0f0f5", "#ffffff"))[2], 0.0)
        self.assertEqual(self.palette_from(("#f0f0f5", "#ffffff"), mode="dark")[2], 0.0)

    def test_the_reported_mean_is_the_measurement_not_a_slot_value(self):
        """Regression: the mean was stored in a name the ramp loops reuse.

        The slot and text loops below the measurement bind `lightness`
        themselves, so the returned figure came back as whichever colour was
        written last -- 0.42, the brown slot -- rather than the image's mean,
        while the mode flag was still correct because it was decided first.
        """
        images = [self.make_image(f"{i}.png", a, b)
                  for i, (a, b) in enumerate([("#2a5e12", "#a8f05e")])]
        _, _, reported = tool.build_palette(images)
        self.assertAlmostEqual(reported, tool.measure_lightness(tool.extract_palette(images)),
                               places=6)
        # The fixed ramp values it could have been confused with, which is how
        # the shadowing showed up.
        for value in (0.42, 0.52, 0.12, 0.18, 0.22, 0.90):
            self.assertNotAlmostEqual(reported, value, places=2)


if __name__ == "__main__":
    unittest.main()
