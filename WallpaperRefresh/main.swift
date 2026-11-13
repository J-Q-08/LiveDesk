import AppKit
import Darwin
import OSLog

let logger = Logger(subsystem: "com.jeffrey.Wallpaper", category: "LockScreen")
let application = NSApplication.shared
let delegate = WallpaperRefreshDelegate()
application.delegate = delegate
application.run()

final class WallpaperRefreshDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { exit(EXIT_FAILURE) }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard urls.count == 1, let url = urls.first, url.scheme == "livedesk-wallpaper-refresh",
              let host = url.host, let token = UUID(uuidString: host) else {
            logger.error("Invalid wallpaper activation request")
            exit(EXIT_FAILURE)
        }
        applyWallpaper(requestToken: token)
    }
}

func applyWallpaper(requestToken: UUID) {
    var stage = "reading the activation request"
    do {
        let files = FileManager.default
        let store = files.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.wallpaper", isDirectory: true)
        let request = AerialSelection.requestURL(for: requestToken, in: store)
        let identifier = try String(contentsOf: request, encoding: .utf8)
        try files.removeItem(at: request)
        guard let assetID = UUID(uuidString: identifier)?.uuidString else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let aerials = store.appendingPathComponent("aerials", isDirectory: true)
        stage = "reading the Aerial catalog"
        let manifest = try Data(contentsOf: aerials.appendingPathComponent("manifest/entries.json"))
        guard let catalog = try JSONSerialization.jsonObject(with: manifest) as? [String: Any],
              let assets = catalog["assets"] as? [[String: Any]],
              assets.contains(where: {
                  $0["id"] as? String == assetID &&
                  ($0["categories"] as? [String])?.contains(AerialSelection.categoryID) == true
              }),
              files.isReadableFile(atPath: aerials.appendingPathComponent("videos/\(assetID).mov").path)
        else { throw CocoaError(.fileNoSuchFile) }

        stage = "reading the current wallpaper selection"
        let indexURL = AerialSelection.indexURL(in: store)
        let index = try AerialSelection.readIndex(in: store)
        let updated = try AerialSelection.selecting(assetID, in: index)
        let backup = indexURL.appendingPathExtension("livedesk-backup")
        if !files.fileExists(atPath: backup.path) {
            try files.copyItem(at: indexURL, to: backup)
        }

        stage = "reloading the wallpaper service"
        try stopWallpaperAgent()
        stage = "saving the wallpaper selection"
        try updated.write(to: indexURL, options: .atomic)
        stage = "refreshing the wallpaper service"
        try stopWallpaperAgent()
        let refresh = Process()
        refresh.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        refresh.arguments = ["WallpaperAerialsExtension"]
        refresh.standardError = FileHandle.nullDevice
        try? refresh.run()
        exit(EXIT_SUCCESS)
    } catch {
        let failure = error as NSError
        logger.error("Failed while \(stage, privacy: .public): \(failure.domain, privacy: .public) \(failure.code, privacy: .public)")
        exit(EXIT_FAILURE)
    }
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
