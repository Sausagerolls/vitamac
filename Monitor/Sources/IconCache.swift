import Foundation
import UIKit
import CryptoKit

/// On-disk PNG cache for process app icons, keyed by executable path, so icons
/// survive app launches instead of being re-fetched over the network each time.
enum IconCache {
    private static let manifestKey = "iconManifestPaths"

    private static let directory: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MonitorIcons", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    private static func fileURL(for path: String) -> URL {
        let digest = SHA256.hash(data: Data(path.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name).appendingPathExtension("png")
    }

    static func loadData(for path: String) -> Data? {
        try? Data(contentsOf: fileURL(for: path))
    }

    static func save(_ png: Data, for path: String) {
        try? png.write(to: fileURL(for: path), options: .atomic)
        var manifest = Set(UserDefaults.standard.stringArray(forKey: manifestKey) ?? [])
        if manifest.insert(path).inserted {
            UserDefaults.standard.set(Array(manifest), forKey: manifestKey)
        }
    }

    /// Executable paths we have a cached icon for (for preloading at launch).
    static func manifestPaths() -> [String] {
        UserDefaults.standard.stringArray(forKey: manifestKey) ?? []
    }
}
