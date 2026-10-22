import json
from pathlib import Path

app = Path(defines['app']).resolve()
artwork = Path(defines['artwork']).resolve()
layout = json.loads(Path(defines['layout']).read_text())
files = [str(app)]
symlinks = {'Applications': '/Applications'}
format = 'ULFO'
filesystem = 'APFS'
background = str(artwork / 'background.png')
icon = str(app / 'Contents/Resources/AppIcon.icns')
icon_locations = {app.name: tuple(layout['app']), 'Applications': tuple(layout['applications'])}
window_rect = (tuple(layout['windowOrigin']), (layout['width'], layout['windowHeight']))
icon_size = layout['iconSize']
text_size = layout['textSize']
show_toolbar = False
show_status_bar = False
show_pathbar = False
show_tab_view = False
show_sidebar = False
include_icon_view_settings = True
include_list_view_settings = False
default_view = 'icon-view'
arrange_by = None
# FinderInfo on a sealed app bundle fails strict signature verification.
# Let Finder honour the user's normal filename-extension preference.
hide_extensions = []

def create_hook(mount_point, options):
    (Path(mount_point) / '.metadata_never_index').touch()
