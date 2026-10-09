import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import Testing
@testable import HoursUI

/// Runtime render: writes the Style Gallery in light and dark to
/// `$TMPDIR/hours-gallery-{light,dark}.png` for visual review.
@Suite struct DesignGalleryRenderTests {
    @MainActor
    @Test(arguments: [ColorScheme.light, .dark])
    func renderStyleGallery(scheme: ColorScheme) throws {
        let renderer = ImageRenderer(content: StyleGallery().environment(\.colorScheme, scheme))
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        #expect(image.width == 1180 * 2)
        #expect(image.height > 1000)

        let dir = ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory()
        let url = URL(fileURLWithPath: dir).appendingPathComponent("hours-gallery-\(scheme == .dark ? "dark" : "light").png")
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
        print("StyleGallery (\(scheme)): \(url.path)")
    }
}
