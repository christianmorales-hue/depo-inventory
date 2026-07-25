"""
Photos for catalogue items.

Needs one extra package:   pip install python-multipart

Add to the bottom of api/main.py, after the users line:

    from api import photos  # noqa: E402

Files land in ./media next to your project. Add `media/` to .gitignore -
photos do not belong in git.
"""
import hashlib
from pathlib import Path

from fastapi import HTTPException, Request, UploadFile
from fastapi.staticfiles import StaticFiles

from api.main import app, require, run

MEDIA = Path("media")
MEDIA.mkdir(exist_ok=True)

MAX_BYTES = 6 * 1024 * 1024
TYPES = {"image/jpeg": ".jpg", "image/png": ".png", "image/webp": ".webp"}

app.mount("/media", StaticFiles(directory=MEDIA), name="media")


@app.post("/api/items/{item_id}/photo")
async def upload_photo(item_id: int, request: Request, file: UploadFile):
    """Any logged-in person may add a photo. A picture of the part beats any
    nickname, so the easier this is, the better the catalogue gets."""
    require(request)
    if file.content_type not in TYPES:
        raise HTTPException(400, "Use una foto JPG, PNG o WEBP.")
    data = await file.read()
    if len(data) > MAX_BYTES:
        raise HTTPException(400, "La foto no debe pasar de 6 MB.")
    if not run("SELECT 1 FROM item WHERE item_id = %s", (item_id,)):
        raise HTTPException(404, "Producto no encontrado.")

    name = hashlib.sha256(data).hexdigest()[:24] + TYPES[file.content_type]
    (MEDIA / name).write_bytes(data)
    run("UPDATE item SET photo_path = %s WHERE item_id = %s", (name, item_id))
    return {"photo_path": name}


@app.delete("/api/items/{item_id}/photo")
def delete_photo(item_id: int, request: Request):
    require(request, "admin")
    rows = run("UPDATE item SET photo_path = NULL WHERE item_id = %s "
               "RETURNING 1", (item_id,))
    if not rows:
        raise HTTPException(404, "Producto no encontrado.")
    # The file itself stays on disk: another item may share it, since the
    # filename is a hash of the contents.
    return {"ok": True}
