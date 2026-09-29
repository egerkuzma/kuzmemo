import AppKit
import SwiftUI

/// Renders a SwiftUI view to PNG without showing a window, so the UI can be inspected from the terminal.
enum Snapshot {
    /// `height` fixes the size of a window-like view; without it the view is as tall as its content.
    static func png<V: View>(_ view: V, width: CGFloat, height: CGFloat? = nil, dark: Bool, scale: CGFloat = 2) -> Data? {
        let themed = view
            .frame(width: width, height: height)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, dark ? .dark : .light)
        let hosting = NSHostingView(rootView: themed)
        let fitting = hosting.fittingSize
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: height ?? max(fitting.height, 40))

        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()

        let pixelsWide = Int(hosting.bounds.width * scale)
        let pixelsHigh = Int(hosting.bounds.height * scale)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        rep.size = hosting.bounds.size
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
}
