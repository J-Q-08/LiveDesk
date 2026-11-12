import Foundation

enum AerialSelection {
    static let categoryID = "1DA60D58-7B3F-4A52-A441-879D57DD0001"

    static func indexURL(in store: URL) -> URL {
        store.appendingPathComponent("Store/Index.plist")
    }

    static func readIndex(in store: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: indexURL(in: store))
        guard let index = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              index["SystemDefault"] is [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
        return index
    }

    static func selectedID(in index: [String: Any]) -> String? {
        guard let content = linkedContent(in: index),
              let choices = content["Choices"] as? [[String: Any]],
              let choice = choices.first,
              choice["Provider"] as? String == "com.apple.wallpaper.choice.aerials",
              let data = choice["Configuration"] as? Data,
              let config = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return config["assetID"] as? String
    }

    static func selecting(_ assetID: String, in index: [String: Any]) throws -> Data {
        let configuration = try PropertyListSerialization.data(
            fromPropertyList: ["assetID": assetID], format: .binary, options: 0)
        let options = try (linkedContent(in: index)?["EncodedOptionValues"] as? Data ?? PropertyListSerialization.data(
            fromPropertyList: ["values": ["placement": ["picker": ["_0": ["id": "FillScreen"]]]]],
            format: .binary, options: 0))
        let choice: [String: Any] = [
            "Provider": "com.apple.wallpaper.choice.aerials", "Files": [], "Configuration": configuration
        ]
        let content: [String: Any] = [
            "Choices": [choice], "Shuffle": "$null", "EncodedOptionValues": options
        ]
        let now = Date()
        let linked: [String: Any] = ["LastSet": now, "LastUse": now, "Content": content]
        let selection: [String: Any] = ["Type": "linked", "Linked": linked]
        var updated = index
        updated["SystemDefault"] = selection
        updated["AllSpacesAndDisplays"] = selection
        updated["Displays"] = [String: Any]()
        updated["Spaces"] = [String: Any]()
        return try PropertyListSerialization.data(fromPropertyList: updated, format: .binary, options: 0)
    }

    private static func linkedContent(in index: [String: Any]) -> [String: Any]? {
        guard let entry = index["SystemDefault"] as? [String: Any],
              entry["Type"] as? String == "linked",
              let linked = entry["Linked"] as? [String: Any] else { return nil }
        return linked["Content"] as? [String: Any]
    }
}
