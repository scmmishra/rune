import AppKit
import SwiftUI

extension URL {
    var isSVG: Bool {
        pathExtension.lowercased() == "svg"
    }

    /// Files the drawer can show rendered as well as as source.
    var hasRenderedPreview: Bool {
        isMarkdown || isSVG
    }
}

/// A read-only rendering of an SVG file, drawn by AppKit's native SVG support.
struct SVGPreview: View {
    let text: String
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    // Vectors scale cleanly, but a tiny icon filling the drawer reads
                    // poorly; enlarge small images only up to a comfortable size.
                    .frame(maxWidth: max(image.size.width, 256), maxHeight: max(image.size.height, 256))
                    .padding(28)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel("SVG image")
            } else if failed {
                ContentUnavailableView(
                    "Unable to Render SVG",
                    systemImage: "photo.badge.exclamationmark",
                    description: Text("Switch to Source to view the file.")
                )
            }
        }
        .task(id: text) {
            let data = Data(text.utf8)
            let rendered = await Task.detached(priority: .userInitiated) { NSImage(data: data) }.value
            guard !Task.isCancelled else { return }
            // An SVG without a size parses to an empty image; treat it as unrenderable.
            if let rendered, rendered.size.width > 0, rendered.size.height > 0 {
                image = rendered
                failed = false
            } else {
                image = nil
                failed = true
            }
        }
    }
}
