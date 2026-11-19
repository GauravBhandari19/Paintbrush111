import SwiftUI
import Combine
import AppKit
import UniformTypeIdentifiers

// MARK: - Tools

enum Tool: String, CaseIterable, Identifiable {
    case pencil, brush, spray, eraser
    case line, rectangle, oval
    case fill, eyedropper, text

    var id: String { rawValue }

    var label: String {
        switch self {
        case .pencil: return "Pencil"
        case .brush: return "Brush"
        case .spray: return "Spray Can"
        case .eraser: return "Eraser"
        case .line: return "Line (hold ⇧ for 45°)"
        case .rectangle: return "Rectangle (hold ⇧ for square)"
        case .oval: return "Oval (hold ⇧ for circle)"
        case .fill: return "Paint Bucket"
        case .eyedropper: return "Eyedropper"
        case .text: return "Text (Return = place, ⌥Return = new line, Esc = cancel)"
        }
    }

    var symbol: String {
        switch self {
        case .pencil: return "pencil"
        case .brush: return "paintbrush.pointed"
        case .spray: return "spraycan"
        case .eraser: return "eraser"
        case .line: return "line.diagonal"
        case .rectangle: return "rectangle"
        case .oval: return "circle"
        case .fill: return "drop.fill"
        case .eyedropper: return "eyedropper"
        case .text: return "textformat"
        }
    }

    var isShape: Bool { self == .line || self == .rectangle || self == .oval }
    var isFreehand: Bool { self == .pencil || self == .brush || self == .eraser }
}

// MARK: - Model

final class CanvasModel: ObservableObject {
    // Settings
    @Published var tool: Tool = .brush
    @Published var primaryColor: Color = .black
    @Published var secondaryColor: Color = .white
    @Published var lineWidth: Double = 4
    @Published var fillShapes = false
    @Published var fontSize: Double = 28
    @Published var boldText = false

    // UI state
    @Published var showingNewSheet = false
    @Published private(set) var canvasSize: CGSize
    /// Bumped whenever something changes that the UI should react to (undo availability, etc.)
    @Published private(set) var revision = 0

    // Bitmap (bottom-left origin, matches the non-flipped NSView)
    private(set) var bitmap: CGContext

    private var undoStack: [Data] = []
    private var redoStack: [Data] = []
    private let maxUndo = 30

    /// While true (nothing drawn yet), the blank canvas resizes to fill the window.
    private var autoFit = true

    // Floating (pasted) image, draggable until committed
    private(set) var floatingImage: CGImage?
    private var floatingSize: CGSize = .zero
    var floatingOrigin: CGPoint = .zero
    var floatingRect: CGRect? {
        guard floatingImage != nil else { return nil }
        return CGRect(origin: floatingOrigin, size: floatingSize)
    }

    var canUndo: Bool { !undoStack.isEmpty || floatingImage != nil }
    var canRedo: Bool { !redoStack.isEmpty }

    init(width: Int = 800, height: Int = 600) {
        bitmap = CanvasModel.makeBitmap(width: width, height: height)
        canvasSize = CGSize(width: width, height: height)
    }

    private static func makeBitmap(width: Int, height: Int) -> CGContext {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil,
                            width: width,
                            height: height,
                            bitsPerComponent: 8,
                            bytesPerRow: 0,
                            space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.interpolationQuality = .none
        return ctx
    }

    private var primaryNS: NSColor { NSColor(primaryColor).usingColorSpace(.sRGB) ?? .black }
    private var secondaryNS: NSColor { NSColor(secondaryColor).usingColorSpace(.sRGB) ?? .white }

    // MARK: Canvas management

    func newCanvas(width: Int, height: Int) {
        flushText()
        autoFit = false
        let w = min(max(width, 1), 8000)
        let h = min(max(height, 1), 8000)
        bitmap = CanvasModel.makeBitmap(width: w, height: h)
        canvasSize = CGSize(width: w, height: h)
        floatingImage = nil
        undoStack.removeAll()
        redoStack.removeAll()
        revision += 1
    }

    func clear() {
        flushText()
        commitFloating()
        pushUndo()
        bitmap.saveGState()
        bitmap.setFillColor(CGColor(gray: 1, alpha: 1))
        bitmap.fill(CGRect(origin: .zero, size: canvasSize))
        bitmap.restoreGState()
        revision += 1
    }

    /// Resizes a still-blank canvas to fill the available viewport.
    func fitCanvasToViewport(_ size: CGSize) {
        guard autoFit else { return }
        let w = Int(size.width), h = Int(size.height)
        guard w > 100, h > 100, w != bitmap.width || h != bitmap.height else { return }
        bitmap = CanvasModel.makeBitmap(width: min(w, 8000), height: min(h, 8000))
        canvasSize = CGSize(width: min(w, 8000), height: min(h, 8000))
        revision += 1
    }

    // MARK: Undo / redo (raw pixel snapshots)

    private func snapshot() -> Data {
        Data(bytes: bitmap.data!, count: bitmap.bytesPerRow * bitmap.height)
    }

    private func restore(_ data: Data) {
        guard data.count == bitmap.bytesPerRow * bitmap.height else { return }
        data.withUnsafeBytes { buf in
            if let base = buf.baseAddress {
                memcpy(bitmap.data!, base, data.count)
            }
        }
    }

    /// Call right before any change to the bitmap.
    func pushUndo() {
        autoFit = false
        undoStack.append(snapshot())
        if undoStack.count > maxUndo { undoStack.removeFirst() }
        redoStack.removeAll()
        revision += 1
    }

    func undo() {
        flushText()
        if floatingImage != nil { cancelFloating(); return }
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(snapshot())
        restore(previous)
        revision += 1
    }

    func redo() {
        flushText()
        guard floatingImage == nil, let next = redoStack.popLast() else { return }
        undoStack.append(snapshot())
        restore(next)
        revision += 1
    }

    // MARK: Freehand drawing

    func drawSegment(from a: CGPoint, to b: CGPoint) {
        let ctx = bitmap
        ctx.saveGState()
        defer { ctx.restoreGState() }

        var width = CGFloat(lineWidth)
        let color: CGColor

        switch tool {
        case .pencil:
            ctx.setShouldAntialias(false)
            width = 1
            color = primaryNS.cgColor
        case .eraser:
            width = CGFloat(lineWidth) * 2
            color = CGColor(gray: 1, alpha: 1)
        default:
            color = primaryNS.cgColor
        }

        if a == b {
            ctx.setFillColor(color)
            ctx.fillEllipse(in: CGRect(x: a.x - width / 2, y: a.y - width / 2, width: width, height: width))
        } else {
            ctx.setStrokeColor(color)
            ctx.setLineWidth(width)
            ctx.move(to: a)
            ctx.addLine(to: b)
            ctx.strokePath()
        }
    }

    func spray(at p: CGPoint) {
        let ctx = bitmap
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setShouldAntialias(false)
        ctx.setFillColor(primaryNS.cgColor)
        let radius = CGFloat(lineWidth) * 3
        let dots = max(10, Int(lineWidth) * 4)
        for _ in 0..<dots {
            let angle = CGFloat.random(in: 0..<(2 * .pi))
            let dist = radius * CGFloat.random(in: 0...1).squareRoot()
            ctx.fill(CGRect(x: (p.x + cos(angle) * dist).rounded(),
                            y: (p.y + sin(angle) * dist).rounded(),
                            width: 1, height: 1))
        }
    }

    // MARK: Shapes (used for both live preview and final commit)

    private func endPoint(from a: CGPoint, to b: CGPoint, constrain: Bool) -> CGPoint {
        guard constrain else { return b }
        let dx = b.x - a.x
        let dy = b.y - a.y
        if tool == .line {
            let step = CGFloat.pi / 4
            let snapped = (atan2(dy, dx) / step).rounded() * step
            let len = hypot(dx, dy)
            return CGPoint(x: a.x + cos(snapped) * len, y: a.y + sin(snapped) * len)
        } else {
            let side = max(abs(dx), abs(dy))
            return CGPoint(x: a.x + (dx < 0 ? -side : side),
                           y: a.y + (dy < 0 ? -side : side))
        }
    }

    func drawShape(in ctx: CGContext, from a: CGPoint, to b: CGPoint, constrain: Bool) {
        let e = endPoint(from: a, to: b, constrain: constrain)
        let rect = CGRect(x: min(a.x, e.x), y: min(a.y, e.y),
                          width: abs(e.x - a.x), height: abs(e.y - a.y))

        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setStrokeColor(primaryNS.cgColor)
        ctx.setFillColor(secondaryNS.cgColor)
        ctx.setLineWidth(CGFloat(lineWidth))
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        switch tool {
        case .line:
            ctx.move(to: a)
            ctx.addLine(to: e)
            ctx.strokePath()
        case .rectangle:
            if fillShapes { ctx.fill(rect) }
            ctx.stroke(rect)
        case .oval:
            if fillShapes { ctx.fillEllipse(in: rect) }
            ctx.strokeEllipse(in: rect)
        default:
            break
        }
    }

    // MARK: Paint bucket (scanline flood fill)

    func floodFill(at p: CGPoint, tolerance: Int = 24) {
        let w = bitmap.width
        let h = bitmap.height
        let x0 = Int(p.x.rounded(.down))
        let y0 = h - 1 - Int(p.y.rounded(.down))   // bitmap memory is top-down
        guard x0 >= 0, x0 < w, y0 >= 0, y0 < h, let raw = bitmap.data else { return }

        let px = raw.assumingMemoryBound(to: UInt8.self)
        let bpr = bitmap.bytesPerRow
        @inline(__always) func offset(_ x: Int, _ y: Int) -> Int { y * bpr + x * 4 }

        let start = offset(x0, y0)
        let tr = Int(px[start]), tg = Int(px[start + 1]), tb = Int(px[start + 2])

        let c = primaryNS
        let nr = UInt8((c.redComponent * 255).rounded())
        let ng = UInt8((c.greenComponent * 255).rounded())
        let nb = UInt8((c.blueComponent * 255).rounded())

        @inline(__always) func matches(_ o: Int) -> Bool {
            abs(Int(px[o]) - tr) <= tolerance &&
            abs(Int(px[o + 1]) - tg) <= tolerance &&
            abs(Int(px[o + 2]) - tb) <= tolerance
        }

        var visited = [Bool](repeating: false, count: w * h)
        var stack: [(Int, Int)] = [(x0, y0)]

        while let (sx, sy) = stack.popLast() {
            if visited[sy * w + sx] || !matches(offset(sx, sy)) { continue }

            var lx = sx
            while lx > 0, !visited[sy * w + lx - 1], matches(offset(lx - 1, sy)) { lx -= 1 }
            var rx = sx
            while rx < w - 1, !visited[sy * w + rx + 1], matches(offset(rx + 1, sy)) { rx += 1 }

            for x in lx...rx {
                visited[sy * w + x] = true
                let o = offset(x, sy)
                px[o] = nr; px[o + 1] = ng; px[o + 2] = nb; px[o + 3] = 255
            }

            for ny in [sy - 1, sy + 1] where ny >= 0 && ny < h {
                var inSpan = false
                for x in lx...rx {
                    let ok = !visited[ny * w + x] && matches(offset(x, ny))
                    if ok && !inSpan { stack.append((x, ny)); inSpan = true }
                    else if !ok { inSpan = false }
                }
            }
        }
    }

    // MARK: Eyedropper

    func pickColor(at p: CGPoint) {
        let w = bitmap.width
        let h = bitmap.height
        let x = Int(p.x.rounded(.down))
        let y = h - 1 - Int(p.y.rounded(.down))
        guard x >= 0, x < w, y >= 0, y < h, let raw = bitmap.data else { return }
        let px = raw.assumingMemoryBound(to: UInt8.self)
        let o = y * bitmap.bytesPerRow + x * 4
        primaryColor = Color(.sRGB,
                             red: Double(px[o]) / 255,
                             green: Double(px[o + 1]) / 255,
                             blue: Double(px[o + 2]) / 255,
                             opacity: 1)
    }

    // MARK: Text

    /// Set by the canvas view; places any text box that is currently being edited.
    var textFlusher: (() -> Void)?
    func flushText() { textFlusher?() }

    var textFont: NSFont {
        NSFont.systemFont(ofSize: CGFloat(fontSize), weight: boldText ? .bold : .regular)
    }
    var textColor: NSColor { primaryNS }

    /// Stamps text into the bitmap. `rect` is in canvas coordinates (bottom-left origin).
    func drawText(_ text: NSAttributedString, in rect: CGRect) {
        pushUndo()
        // Extra room so nothing wraps or clips; the top edge stays where it was.
        let drawRect = CGRect(x: rect.minX, y: rect.minY - 4, width: rect.width + 20, height: rect.height + 4)
        bitmap.saveGState()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: bitmap, flipped: false)
        text.draw(in: drawRect)
        NSGraphicsContext.restoreGraphicsState()
        bitmap.restoreGState()
        revision += 1
    }

    // MARK: Paste (floating image)

    /// Pastes an image (e.g. a screenshot) from the clipboard as a draggable floating layer.
    @discardableResult
    func pasteFromClipboard() -> Bool {
        guard let ns = (NSPasteboard.general.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage])?.first,
              let cg = ns.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return false }

        autoFit = false
        flushText()
        commitFloating()

        // Use point size so Retina screenshots appear at their natural size
        var size = ns.size
        if size.width <= 0 || size.height <= 0 {
            size = CGSize(width: cg.width, height: cg.height)
        }
        growCanvas(toFit: size)

        floatingImage = cg
        floatingSize = size
        floatingOrigin = CGPoint(x: 0, y: CGFloat(bitmap.height) - size.height)   // top-left
        revision += 1
        return true
    }

    /// Stamps the floating image onto the canvas.
    func commitFloating() {
        guard let image = floatingImage, let rect = floatingRect else { return }
        pushUndo()   // snapshot before stamping
        bitmap.saveGState()
        bitmap.interpolationQuality = .high
        bitmap.draw(image, in: rect)
        bitmap.restoreGState()
        floatingImage = nil
        revision += 1
    }

    func cancelFloating() {
        guard floatingImage != nil else { return }
        floatingImage = nil
        revision += 1
    }

    /// Enlarges the canvas (keeping existing content at the top-left) if the pasted image is bigger.
    private func growCanvas(toFit size: CGSize) {
        let oldW = bitmap.width, oldH = bitmap.height
        let newW = max(oldW, Int(ceil(size.width)))
        let newH = max(oldH, Int(ceil(size.height)))
        guard newW != oldW || newH != oldH, let old = bitmap.makeImage() else { return }

        let grown = CanvasModel.makeBitmap(width: newW, height: newH)
        grown.draw(old, in: CGRect(x: 0, y: newH - oldH, width: oldW, height: oldH))
        bitmap = grown
        canvasSize = CGSize(width: newW, height: newH)
        undoStack.removeAll()   // snapshots no longer match the new size
        redoStack.removeAll()
    }

    // MARK: File I/O

    func saveImage() {
        flushText()
        commitFloating()
        guard let image = bitmap.makeImage() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.nameFieldStringValue = "Untitled.png"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let rep = NSBitmapImageRep(cgImage: image)
        let ext = url.pathExtension.lowercased()
        let type: NSBitmapImageRep.FileType = (ext == "jpg" || ext == "jpeg") ? .jpeg : .png
        if let data = rep.representation(using: type, properties: [:]) {
            try? data.write(to: url)
        }
    }

    func openImage() {
        flushText()
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK,
              let url = panel.url,
              let nsImage = NSImage(contentsOf: url),
              let cg = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return }

        newCanvas(width: cg.width, height: cg.height)
        bitmap.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        revision += 1
    }

    func copyToClipboard() {
        flushText()
        commitFloating()
        guard let image = bitmap.makeImage() else { return }
        let ns = NSImage(cgImage: image, size: canvasSize)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([ns])
    }
}
