# dmgbuild settings for the installer window; scripts/build_app.py passes the paths as defines.
# Icon positions match the arrow and label chips in assets/dmg (scripts/make_dmg_background.py).
import os.path

app = defines["app"]
assets = defines["assets"]

format = "UDZO"
files = [app]
symlinks = {"Applications": "/Applications"}
icon = defines["icon"]
background = os.path.join(assets, "background.png")
hide_extensions = [os.path.basename(app)]

# The height includes the 28-point title bar, so the 420-point background shows whole.
window_rect = ((200, 140), (660, 448))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
include_icon_view_settings = True
arrange_by = None
icon_size = 112
text_size = 13
icon_locations = {
    os.path.basename(app): (165, 200),
    "Applications": (495, 200),
    # Outside the window, for people who show hidden files in Finder.
    ".background.tiff": (900, 900),
    ".VolumeIcon.icns": (1000, 900),
    ".DS_Store": (1100, 900),
}
