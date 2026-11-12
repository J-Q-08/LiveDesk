# LiveDesk

LiveDesk is a macOS video wallpaper app. The Mac app stores imported videos locally. The community server stores videos that people explicitly publish, plus a SQLite catalog that Discover reads.

## Try the shared library locally

1. In Terminal, run `cd server && uv run uvicorn app:app --host 127.0.0.1 --port 8787`.
2. Open `Wallpaper.xcodeproj` in Xcode and run the `Wallpaper` scheme.
3. Import a video. It remains private in your Library.
4. Open **Submissions** and select **Publish to Discover** for that video.
5. Open **Discover**. Select the shared video to download a copy into your Library.

The app points to `http://localhost:8787` by default. You can change the server URL in Discover. The server's database and uploaded videos live in `server/data/`, which Git ignores. See [server/README.md](server/README.md) for server details.

## Current release status

This is a local prototype. The server is not deployed and does not have user accounts or abuse controls. Do not expose it to the public internet yet. The Mac app also has an experimental live Lock Screen integration that still needs real-device validation.
