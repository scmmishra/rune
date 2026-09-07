import AppKit
import BeautifulMermaid

nonisolated enum GuideDiagramRenderer {
    static func render(source: String, dark: Bool) throws -> NSImage? {
        let lines = source.components(separatedBy: .newlines)
        guard source.utf8.count <= 4_000, lines.count <= 32,
              source.hasPrefix("flowchart ") || source.hasPrefix("graph ") || source.hasPrefix("sequenceDiagram"),
              !source.contains("%%{"), !source.contains("click "), !source.contains("<"),
              source.components(separatedBy: ";").count <= 32 else {
            throw GuideError.message("This diagram uses unsupported syntax or is too large.")
        }
        let graph = try MermaidRenderer.parse(source)
        let withinLimit: Bool
        switch graph.typedPayload {
        case let .flowchart(model): withinLimit = model.nodesInOrder.count <= 12 && model.edges.count <= 24
        case let .sequenceDiagram(model): withinLimit = model.actors.count <= 12 && model.messages.count <= 24
        default: withinLimit = false
        }
        guard withinLimit else { throw GuideError.message("This diagram is too complex for an inline guide.") }
        let renderer = MermaidImageRenderer(theme: dark ? .zincDark : .zincLight)
        guard let prepared = try renderer.prepare(from: source) else { return nil }
        let bounds = prepared.bounds
        guard bounds.width.isFinite, bounds.height.isFinite,
              bounds.width > 0, bounds.height > 0,
              bounds.width <= 2_000, bounds.height <= 2_000,
              bounds.width * bounds.height <= 1_000_000 else {
            throw GuideError.message("This diagram is too large to display inline.")
        }
        let scale = 2.0
        guard let context = CGContext(data: nil, width: Int(ceil(bounds.width * scale)),
                                      height: Int(ceil(bounds.height * scale)), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // BeautifulMermaid 1.0.4's macOS image path omits the top-left transform,
        // producing vertically mirrored text. Draw its prepared diagram with the
        // coordinate system required by PreparedDiagram.render instead.
        // https://github.com/lukilabs/beautiful-mermaid-swift/blob/1.0.4/Sources/BeautifulMermaidSwift/Views/MermaidLayer.swift
        context.translateBy(x: 0, y: CGFloat(context.height))
        context.scaleBy(x: scale, y: -scale)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        prepared.render(context, bounds)
        guard let image = context.makeImage() else { return nil }
        return NSImage(cgImage: image, size: bounds.size)
    }
}
