# The install window, as dmgbuild lays it out: the app on the left, the
# Applications folder on the right, an arrow between them painted into the
# background, and nothing else. make_dmg.sh passes the paths in via -D.
app = defines["app"]
files = [app]
symlinks = {"Applications": "/Applications"}
icon = defines.get("icon")
background = defines["background"]

format = "UDZO"
compression_level = 9
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
sidebar_width = 0

window_rect = ((260, 200), (int(defines["width"]), int(defines["height"])))
icon_size = 128
text_size = 14
arrange_by = None
grid_offset = (0, 0)
label_pos = "bottom"
# Keyed by the name the app has inside the image (make_dmg.sh stages it as
# SayControl.app). A name that matches nothing leaves Finder to place the
# icon itself, which is how it once sat higher than the folder.
icon_locations = {
    "SayControl.app": (int(defines["appX"]),  int(defines["iconY"])),
    "Applications": (int(defines["folderX"]), int(defines["iconY"])),
}
