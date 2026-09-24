# Mise en page du .dmg pour dmgbuild (voir scripts/package.sh) :
# l'app à gauche, un raccourci vers Applications à droite, sur le fond Support/dmg-background.tiff.
import os.path

application = defines["app"]
app_name = os.path.basename(application)

format = "UDZO"
files = [application]
symlinks = {"Applications": "/Applications"}
icon = os.path.join(application, "Contents/Resources/AppIcon.icns")

background = defines["background"]
window_rect = ((200, 200), (600, 400))
icon_locations = {app_name: (150, 190), "Applications": (450, 190)}
icon_size = 96
text_size = 13
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
