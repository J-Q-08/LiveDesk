# LiveDesk

LiveDesk is a macOS video wallpaper app. Discover reads community wallpapers from Supabase and refreshes every 20 seconds while open. Discover and Library show tiles at each video’s aspect ratio. Anyone can browse and download a community wallpaper into their local Library without an account. Local Library index changes are serialized within the running app so simultaneous imports and downloads preserve both entries. Desktop playback creates a wallpaper window for each connected display and updates the set when displays change.

To upload a custom video, create an account or sign in on the **Account** page, then open **Upload** and choose **Upload and Share Video**. You must give the video a name before sharing it. Uploading copies the video to this Mac and publishes it to Discover for everyone. The app warns about public sharing before opening the file picker. If network publishing fails after the local copy is saved, Upload offers **Retry Sharing**; retries reuse the local video's cloud identity. **Your cloud uploads** lists videos published by the signed-in account on any Mac; selecting one downloads a local copy. The sidebar checks Supabase every 20 seconds and reports offline or service errors. Email confirmation is disabled in Supabase for this prototype, so signup creates a usable account immediately. Restore email verification, configure custom SMTP, and set a real confirmation redirect before public release. Supabase Auth stores registered accounts and shows their count in the project's Authentication dashboard; the app does not expose a public account count.

Open `Wallpaper.xcodeproj` in Xcode and run the Wallpaper scheme. Community metadata is in the Supabase `public.wallpapers` table, and media is in the public `wallpapers` Storage bucket. The schema and row-level security policies are in `supabase/migrations/`. The app contains a publishable key only; it never contains a service role or secret key. Authentication sessions are kept in the macOS data protection Keychain. Existing prototype users may need to sign in once after upgrading from the earlier Keychain entry. The current community upload limit is 50 MB per video; files are checked before being copied into the local Library.

The desktop wallpaper and Lock Screen support remain experimental and need validation across macOS versions and multiple displays.

## Release verification

Run these checks on the candidate build and record the macOS version, display setup, and build commit with the results.

1. With a fresh Library and no account, download a Discover wallpaper. Confirm the preview opens, then quit and reopen the app and play the downloaded video from Library.
2. Sign in with a test account, quit and reopen, and verify the session is restored. Publish a video you have permission to share. On a second Mac, confirm the account lists it under Your cloud uploads and a guest can find and download it in Discover.
3. Disconnect the test Mac from the network. Confirm the sidebar reports the connection problem and downloaded Library videos still play. Reconnect and verify Discover refreshes. In a test backend, interrupt publishing after the media upload and retry. Verify there is one catalog entry for the video.
4. Apply a wallpaper, quit and reopen, and confirm playback resumes on the desktop. Repeat with two displays, then disconnect and reconnect the external display. Verify the video remains behind desktop icons across Spaces.
5. Verify launch at login from an installed build. Before distributing, validate signing, notarization, and first launch on a Mac without the development build or existing app data.
