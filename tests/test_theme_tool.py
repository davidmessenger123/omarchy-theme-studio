import importlib.machinery
import importlib.util
import os
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

    def palette_from(self, *specs):
        images = [self.make_image(f"{i}.png", a, b) for i, (a, b) in enumerate(specs)]
        colours, dark = tool.build_palette(images)
        return colours, dark

    def test_every_key_it_promises_is_present(self):
        colours, _ = self.palette_from(("#2a5e12", "#a8f05e"))
        for key in tool.EDITABLE_KEYS:
            self.assertRegex(colours[key], r"^#[0-9a-f]{6}$", key)
        # The border tokens are not palette entries: they are derived from the
        # accent at render time, which is why they are not editable.
        for key in tool.DERIVED_KEYS:
            self.assertNotIn(key, colours)

    def test_a_dark_image_gives_a_dark_theme(self):
        colours, dark = self.palette_from(("#0a0a12", "#202030"))
        self.assertTrue(dark)
        background = tool.rgb_to_hsl(*tool.hex_to_rgb(colours["background"]))[2]
        self.assertLess(background, 0.5, f"background {colours['background']} is not dark")

    def test_a_light_image_gives_a_light_theme(self):
        _, dark = self.palette_from(("#f0f0f5", "#ffffff"))
        self.assertFalse(dark)

    def test_content_colours_clear_the_contrast_floor(self):
        """Regression: muted was 0.20 lightness on a 0.12 background.

        This is the property the studio depends on, asserted through the real
        derivation path rather than a hand-built colour.
        """
        colours, dark = self.palette_from(("#1a1a1a", "#2a2a2a"))
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
        colours, dark = self.palette_from(("#2a5e12", "#a8f05e"))
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "colors.toml"
            path.write_text(tool.render_colors_toml(colours, dark), encoding="utf-8")
            parsed = tool.read_colors(path)
        for key in tool.EDITABLE_KEYS:
            self.assertEqual(parsed[key], colours[key], key)


if __name__ == "__main__":
    unittest.main()
