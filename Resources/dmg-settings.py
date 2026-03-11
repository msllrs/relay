import os

# Volume name
volume_name = "Relay"

# Disk image format
format = "UDZO"

# Background image
background = "Resources/dmg-bg.png"

# Window settings
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
sidebar_width = 0

# Window size and position
window_rect = ((200, 200), (480, 298))

# Icon size and text
icon_size = 64
text_size = 12

# Icon positions (x, y from top-left of content area)
icon_locations = {
    "Relay.app": (128, 100),
    "Applications": (352, 100),
}

# Files to include
files = [
    os.environ.get("APP_PATH", ".build/Relay.app"),
]

# Symlink to Applications
symlinks = {
    "Applications": "/Applications",
}

# Hide file extensions
hide_extensions = ["Relay.app"]
