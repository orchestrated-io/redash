import json
import os

from flask import url_for
from redash import settings

# Use the same robust path resolution as settings
def get_project_root():
    # Try to get the project root from the handler file location
    handler_dir = os.path.dirname(__file__)
    project_root_from_handler = os.path.dirname(os.path.dirname(handler_dir))
    
    # Also try the current working directory as a fallback
    current_dir = os.getcwd()
    
    # Check which path actually contains the client directory
    if os.path.exists(os.path.join(project_root_from_handler, "client")):
        return project_root_from_handler
    elif os.path.exists(os.path.join(current_dir, "client")):
        return current_dir
    else:
        # Fallback to the handler-based path
        return project_root_from_handler

project_root = get_project_root()
WEBPACK_MANIFEST_PATH = os.path.join(project_root, "client", "dist", "asset-manifest.json")


def configure_webpack(app):
    app.extensions["webpack"] = {"assets": None}

    def get_asset(path):
        assets = app.extensions["webpack"]["assets"]
        # in debug we read in this file each request
        if assets is None or app.debug:
            try:
                with open(WEBPACK_MANIFEST_PATH) as fp:
                    assets = json.load(fp)
            except IOError:
                app.logger.exception("Unable to load webpack manifest")
                assets = {}
            app.extensions["webpack"]["assets"] = assets
        return url_for("static", filename=assets.get(path, path))

    @app.context_processor
    def webpack_assets():
        return {"asset_url": get_asset}
