import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension URL {
    var isSVG: Bool {
        pathExtension.lowercased() == "svg"
    }

    /// Raster images, shown rendered only. SVG is text, so it is left to `isSVG`.
    var isImage: Bool {
        !isSVG && UTType(filenameExtension: pathExtension)?.conforms(to: .image) == true
    }

    /// Text files the drawer can show rendered as well as as source.
    var hasRenderedPreview: Bool {
        isMarkdown || isSVG
    }
}

/// A read-only rendering of an image: SVG from its (possibly unsaved) text, or a raster file.
struct ImagePreview: View {
    enum Source: Hashable {
        case svg(String)
        case file(URL)
    }

    let source: Source
    @State private var image: NSImage?
    @State private var failed = false

    private var isVector: Bool {
        if case .svg = source { true } else { false }
    }

    var body: some View {
        Group {
            if let image {
                // Vectors scale cleanly, but a tiny icon filling the drawer reads poorly;
                // enlarge them only up to a comfortable size. Rasters never enlarge.
                let minimum: CGFloat = isVector ? 256 : 0
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(maxWidth: max(image.size.width, minimum), maxHeight: max(image.size.height, minimum))
                    .padding(28)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel("Image")
            } else if failed {
                ContentUnavailableView(
                    "Unable to Render Image",
                    systemImage: "photo.badge.exclamationmark",
                    description: Text(isVector ? "Switch to Source to view the file." : "This image format is not supported.")
                )
            }
        }
        .task(id: source) {
            let source = source
            let rendered = await Task.detached(priority: .userInitiated) { () -> NSImage? in
                switch source {
                case let .svg(text): NSImage(data: Data(text.utf8))
                case let .file(url): NSImage(contentsOf: url)
                }
            }.value
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
