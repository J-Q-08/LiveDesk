# LiveDesk

LiveDesk is a macOS video wallpaper app. Imported videos live on your Mac in the local Library. Discover loads community wallpapers from Supabase; it refreshes every 20 seconds while open. Selecting a community wallpaper downloads a copy into your Library. A video only becomes public when you choose **Publish to Discover** in Submissions and confirm.

## Run

Open `Wallpaper.xcodeproj` in Xcode and run the Wallpaper scheme. You can import a video from **Submissions**. To publish, create an account or sign in there, then select **Publish to Discover** on an imported video. New accounts may need email confirmation before signing in.

Community metadata is in the Supabase `public.wallpapers` table, and media is in the public `wallpapers` Storage bucket. The schema and row-level security policies are in `supabase/migrations/`. The app contains a publishable key only; it never contains a service role or secret key. Authentication sessions are kept in the macOS Keychain. The current community upload limit is 50 MB per video.

The desktop wallpaper and Lock Screen support remain experimental and need validation across macOS versions and multiple displays.
