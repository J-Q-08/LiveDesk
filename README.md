# LiveDesk

LiveDesk is a macOS video wallpaper app. Discover reads community wallpapers from Supabase and refreshes every 20 seconds while open. Anyone can browse and download a community wallpaper into their local Library without an account.

To upload a custom video, create an account or sign in on the **Account** page, then choose **Upload and Share Video** in **Submissions**. Uploading copies the video to this Mac and publishes it to Discover for everyone. The app warns about public sharing before opening the file picker. If network publishing fails after the local copy is saved, Submissions offers **Retry Sharing**. The project currently requires email confirmation. Public registration needs custom SMTP, because Supabase’s default email service only sends to project team members. Its confirmation redirect is currently `http://localhost:3000` and must be changed before release. Supabase Auth stores registered accounts and shows their count in the project's Authentication dashboard; the app does not expose a public account count.

Open `Wallpaper.xcodeproj` in Xcode and run the Wallpaper scheme. Community metadata is in the Supabase `public.wallpapers` table, and media is in the public `wallpapers` Storage bucket. The schema and row-level security policies are in `supabase/migrations/`. The app contains a publishable key only; it never contains a service role or secret key. Authentication sessions are kept in the macOS Keychain. The current community upload limit is 50 MB per video.

The desktop wallpaper and Lock Screen support remain experimental and need validation across macOS versions and multiple displays.
