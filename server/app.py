"""Local development server for LiveDesk's shared wallpaper catalog."""

import os
import sqlite3
import uuid
from datetime import datetime, timezone
from pathlib import Path

from fastapi import FastAPI, Header, HTTPException, Request
from fastapi.responses import FileResponse

DATA_DIR = Path(os.environ.get("LIVEDESK_DATA_DIR", Path(__file__).parent / "data"))
MAX_VIDEO_BYTES = 100 * 1024 * 1024
ALLOWED_EXTENSIONS = {".mp4", ".mov", ".m4v"}

app = FastAPI(title="LiveDesk Community API")


def database() -> sqlite3.Connection:
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    connection = sqlite3.connect(DATA_DIR / "wallpapers.sqlite3")
    connection.row_factory = sqlite3.Row
    connection.execute("""
        CREATE TABLE IF NOT EXISTS wallpapers (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            filename TEXT NOT NULL,
            created_at TEXT NOT NULL
        )
    """)
    connection.commit()
    return connection


def wallpaper_json(row: sqlite3.Row) -> dict:
    return {
        "id": row["id"],
        "title": row["title"],
        "createdAt": row["created_at"],
        "videoPath": f'/api/wallpapers/{row["id"]}/video',
        "thumbnailPath": f'/api/wallpapers/{row["id"]}/thumbnail',
        "fileExtension": Path(row["filename"]).suffix.lstrip("."),
    }


@app.get("/api/wallpapers")
def list_wallpapers(q: str = "", limit: int = 50, offset: int = 0):
    if limit < 1 or limit > 100 or offset < 0:
        raise HTTPException(400, "Invalid pagination")
    with database() as db:
        rows = db.execute(
            "SELECT * FROM wallpapers WHERE title LIKE ? ORDER BY created_at DESC LIMIT ? OFFSET ?",
            (f"%{q[:100]}%", limit, offset),
        ).fetchall()
    return [wallpaper_json(row) for row in rows]


@app.post("/api/wallpapers", status_code=201)
async def publish_wallpaper(request: Request, title: str,
                            extension: str = Header(..., alias="X-Wallpaper-Extension"),
                            client_id: str | None = Header(None, alias="X-Wallpaper-ID")):
    title = title.strip()
    suffix = "." + extension.lower().lstrip(".")
    if not title or len(title) > 100:
        raise HTTPException(400, "Title must be 1–100 characters")
    if suffix not in ALLOWED_EXTENSIONS:
        raise HTTPException(415, "Use an MP4, MOV, or M4V video")

    try:
        identifier = str(uuid.UUID(client_id)) if client_id else str(uuid.uuid4())
    except ValueError:
        raise HTTPException(400, "Invalid wallpaper ID")
    with database() as db:
        existing = db.execute("SELECT * FROM wallpapers WHERE id = ?", (identifier,)).fetchone()
    if existing is not None:
        return wallpaper_json(existing)
    filename = identifier + suffix
    videos = DATA_DIR / "videos"
    videos.mkdir(parents=True, exist_ok=True)
    destination = videos / filename
    size = 0
    try:
        with destination.open("wb") as output:
            async for chunk in request.stream():
                size += len(chunk)
                if size > MAX_VIDEO_BYTES:
                    raise HTTPException(413, "Video exceeds the 100 MB limit")
                output.write(chunk)
        # ISO base media files, including common MP4/MOV/M4V, have an ftyp box.
        with destination.open("rb") as stored:
            header = stored.read(12)
        if len(header) < 12 or header[4:8] != b"ftyp":
            raise HTTPException(415, "This does not appear to be a supported video")
        created_at = datetime.now(timezone.utc).isoformat()
        with database() as db:
            db.execute(
                "INSERT INTO wallpapers (id, title, filename, created_at) VALUES (?, ?, ?, ?)",
                (identifier, title, filename, created_at),
            )
        return {"id": identifier, "title": title, "createdAt": created_at,
                "videoPath": f"/api/wallpapers/{identifier}/video",
                "thumbnailPath": f"/api/wallpapers/{identifier}/thumbnail",
                "fileExtension": suffix.lstrip(".")}
    except Exception:
        destination.unlink(missing_ok=True)
        raise


@app.get("/api/wallpapers/{identifier}/video")
def get_video(identifier: str):
    with database() as db:
        row = db.execute("SELECT filename FROM wallpapers WHERE id = ?", (identifier,)).fetchone()
    if row is None:
        raise HTTPException(404, "Wallpaper not found")
    suffix = Path(row["filename"]).suffix.lower()
    media_type = "video/quicktime" if suffix == ".mov" else "video/mp4"
    return FileResponse(DATA_DIR / "videos" / row["filename"], media_type=media_type)


@app.put("/api/wallpapers/{identifier}/thumbnail", status_code=204)
async def put_thumbnail(identifier: str, request: Request):
    with database() as db:
        row = db.execute("SELECT id FROM wallpapers WHERE id = ?", (identifier,)).fetchone()
    if row is None:
        raise HTTPException(404, "Wallpaper not found")
    image = await request.body()
    if len(image) > 2 * 1024 * 1024 or not image.startswith(b"\x89PNG\r\n\x1a\n"):
        raise HTTPException(415, "Use a PNG image under 2 MB")
    thumbnails = DATA_DIR / "thumbnails"
    thumbnails.mkdir(parents=True, exist_ok=True)
    (thumbnails / f"{identifier}.png").write_bytes(image)


@app.get("/api/wallpapers/{identifier}/thumbnail")
def get_thumbnail(identifier: str):
    path = DATA_DIR / "thumbnails" / f"{identifier}.png"
    if not path.is_file():
        raise HTTPException(404, "Thumbnail not found")
    return FileResponse(path, media_type="image/png")
