import AppKit
import Darwin

// Launch Services starts this short-lived app separately from the sandboxed gallery.
// Its only input is the UUID of a video already registered in LiveDesk's Aerial category.
do {
    guard CommandLine.arguments.count == 2,
          let assetID = UUID(uuidString: CommandLine.arguments[1])?.uuidString else { exit(EXIT_FAILURE) }

    let files = FileManager.default
    let store = files.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/com.apple.wallpaper", isDirectory: true)
    let aerials = store.appendingPathComponent("aerials", isDirectory: true)
    let manifest = try Data(contentsOf: aerials.appendingPathComponent("manifest/entries.json"))
    guard let catalog = try JSONSerialization.jsonObject(with: manifest) as? [String: Any],
          let assets = catalog["assets"] as? [[String: Any]],
          assets.contains(where: {
              $0["id"] as? String == assetID &&
              ($0["categories"] as? [String])?.contains(AerialSelection.categoryID) == true
          }),
          files.isReadableFile(atPath: aerials.appendingPathComponent("videos/\(assetID).mov").path)
    else { exit(EXIT_FAILURE) }

    let indexURL = AerialSelection.indexURL(in: store)
    let index = try AerialSelection.readIndex(in: store)
    let updated = try AerialSelection.selecting(assetID, in: index)
    let backup = indexURL.appendingPathExtension("livedesk-backup")
    if !files.fileExists(atPath: backup.path) {
        try files.copyItem(at: indexURL, to: backup)
    }

    try stopWallpaperAgent()
    try updated.write(to: indexURL, options: .atomic)
    try stopWallpaperAgent()
    let refresh = Process()
    refresh.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
    refresh.arguments = ["WallpaperAerialsExtension"]
    refresh.standardError = FileHandle.nullDevice
    try? refresh.run()
    exit(EXIT_SUCCESS)
} catch {
    exit(EXIT_FAILURE)
}

func stopWallpaperAgent() throws {
    for agent in NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.wallpaper.agent") {
        let pid = agent.processIdentifier
        guard kill(pid, SIGKILL) == 0 || errno == ESRCH else { throw CocoaError(.fileWriteNoPermission) }
        for _ in 0..<50 {
            if kill(pid, 0) == -1 && errno == ESRCH { break }
            usleep(20_000)
        }
    }
}
