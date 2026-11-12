# LiveDesk community server (local prototype)

This server stores video files on disk and their titles in SQLite. Everyone connected to the same server can see published videos in Discover. Importing a video into the Mac app stays private until its owner selects **Publish to Discover**.

Run locally:

```sh
cd server
uv run --extra test uvicorn app:app --host 127.0.0.1 --port 8787
```

The Mac app defaults to `http://127.0.0.1:8787`. Set a different server URL in Discover. `LIVEDESK_DATA_DIR` changes where the database and videos are stored.

This is a development prototype. Do not expose it to the public internet yet: it has no accounts, moderation, quotas per user, or abuse controls. A 100 MB per-video limit and container check are basic safeguards, not a security boundary. Public deployment also needs HTTPS, durable object storage, backups, and operator tools.
