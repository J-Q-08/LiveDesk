import Foundation

enum LegacyDataMigration {
    static func run() {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let legacyLibrary = home.appendingPathComponent(
            "Library/Containers/com.jeffrey.Wallpaper/Data/Library/Application Support/LiveDesk/Videos",
            isDirectory: true)
        let newLibrary = home.appendingPathComponent(
            "Library/Application Support/LiveDesk/Videos", isDirectory: true)

        if fm.fileExists(atPath: legacyLibrary.path) {
            do {
                try fm.createDirectory(at: newLibrary, withIntermediateDirectories: true)
                for file in try fm.contentsOfDirectory(at: legacyLibrary, includingPropertiesForKeys: nil) {
                    let destination = newLibrary.appendingPathComponent(file.lastPathComponent)
                    if !fm.fileExists(atPath: destination.path) {
                        try fm.copyItem(at: file, to: destination)
                    }
                }
            } catch {
                // The library loader will report missing files to the user.
            }
        }

        let legacyPreferences = home.appendingPathComponent(
            "Library/Containers/com.jeffrey.Wallpaper/Data/Library/Preferences/com.jeffrey.Wallpaper.plist")
        guard let data = try? Data(contentsOf: legacyPreferences),
              let values = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil) as? [String: Any] else { return }
        for key in ["selectedLibraryVideoID", "appliedVideoID", "appliedVideoLayout",
                    "launchAtLoginPreference"] {
            if UserDefaults.standard.object(forKey: key) == nil, let value = values[key] {
                UserDefaults.standard.set(value, forKey: key)
            }
        }
    }
}
