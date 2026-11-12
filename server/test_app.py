import app as service
from fastapi.testclient import TestClient


def test_publish_browse_and_download(tmp_path, monkeypatch):
    monkeypatch.setattr(service, "DATA_DIR", tmp_path)
    client = TestClient(service.app)
    assert client.get("/api/wallpapers").json() == []

    video = b"\x00\x00\x00\x18ftypisom" + b"video bytes"
    response = client.post("/api/wallpapers?title=Mountain%20Lake", content=video,
                           headers={"X-Wallpaper-Extension": "mp4"})
    assert response.status_code == 201
    item = response.json()
    assert item["title"] == "Mountain Lake"
    assert client.get("/api/wallpapers?q=Mountain").json() == [item]
    assert client.get("/api/wallpapers?q=Desert").json() == []
    assert client.get(item["videoPath"]).content == video

    retry = client.post("/api/wallpapers?title=Mountain%20Lake", content=video,
                        headers={"X-Wallpaper-Extension": "mp4", "X-Wallpaper-ID": item["id"]})
    assert retry.status_code == 201
    assert retry.json() == item
    assert len(client.get("/api/wallpapers").json()) == 1

    thumbnail = b"\x89PNG\r\n\x1a\n" + b"thumbnail"
    assert client.put(item["thumbnailPath"], content=thumbnail).status_code == 204
    assert client.get(item["thumbnailPath"]).content == thumbnail


def test_reject_invalid_upload(tmp_path, monkeypatch):
    monkeypatch.setattr(service, "DATA_DIR", tmp_path)
    client = TestClient(service.app)
    response = client.post("/api/wallpapers?title=Invalid", content=b"not a video",
                           headers={"X-Wallpaper-Extension": "mp4"})
    assert response.status_code == 415
    assert client.get("/api/wallpapers").json() == []
    assert not list((tmp_path / "videos").iterdir())


def test_reject_oversized_upload(tmp_path, monkeypatch):
    monkeypatch.setattr(service, "DATA_DIR", tmp_path)
    monkeypatch.setattr(service, "MAX_VIDEO_BYTES", 15)
    client = TestClient(service.app)
    response = client.post("/api/wallpapers?title=Too%20big",
                           content=b"\x00\x00\x00\x18ftypisom" + b"extra bytes",
                           headers={"X-Wallpaper-Extension": "mp4"})
    assert response.status_code == 413
    assert client.get("/api/wallpapers").json() == []
