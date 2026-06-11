import Foundation
import AppKit

/// Renders process app icons to PNG. For an executable inside a `.app` it uses
/// the bundle's icon (what Activity Monitor shows); for a bare daemon it uses
/// the file's icon (generic Unix-exec icon). Stateless — the caller caches.
public enum IconProvider {
    public static func pngIcon(forExecutablePath path: String, size: CGFloat = 36) -> Data? {
        let target = appBundlePath(for: path) ?? path
        guard FileManager.default.fileExists(atPath: target) else { return nil }

        let icon = NSWorkspace.shared.icon(forFile: target)
        let pixels = Int(size * 2)   // @2x
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        rep.size = NSSize(width: size, height: size)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        icon.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
        NSGraphicsContext.restoreGraphicsState()

        return rep.representation(using: .png, properties: [:])
    }

    /// Nearest `.app` ancestor of an executable path, if any.
    private static func appBundlePath(for execPath: String) -> String? {
        var url = URL(fileURLWithPath: execPath)
        while url.pathComponents.count > 1 {
            if url.pathExtension == "app" { return url.path }
            url.deleteLastPathComponent()
        }
        return nil
    }
}
