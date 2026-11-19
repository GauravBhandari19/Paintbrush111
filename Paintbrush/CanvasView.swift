import SwiftUI
import AppKit

// MARK: - SwiftUI wrapper

struct CanvasRepresentable: NSViewRepresentable {
    @ObservedObject var model: CanvasModel

    func makeNSView(context: Context) -> CanvasNSView {
        CanvasNSView(model: model)
    }

    func updateNSView(_ nsView: CanvasNSView, context: Context) {
        nsView.needsDisplay = true
        nsView.modelDidChange()
    }
}

// MARK: - AppKit view that handles mouse input

final class CanvasNSView: NSView {
    private let model: CanvasModel

    private var startPoint: CGPoint?
    private var lastPoint: CGPoint = .zero
    private var currentPoint: CGPoint = .zero
    private var constrain = false

    private var isDraggingFloating = false
    private var floatingGrabOffset: CGPoint = .zero

    // Text tool
    private var activeTextView: NSTextView?
    private var textTopLeft: CGPoint = .zero   // top-left corner of the text box (canvas coordinates)

    init(model: CanvasModel) {
        self.model = model
        super.init(frame: .zero)
        model.textFlusher = { [weak self] in self?.commitText() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Become first responder so ⌘V (Edit ▸ Paste) reaches this view
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.window?.makeFirstResponder(self)
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    // MARK: Paste (Edit ▸ Paste / ⌘V)

    @objc func paste(_ sender: Any?) {
        if model.pasteFromClipboard() {
            window?.makeFirstResponder(self)
            needsDisplay = true
        } else {
            NSSound.beep()
        }
    }

    // MARK: Keyboard (Return = place pasted image, Esc = cancel)

    override func keyDown(with event: NSEvent) {
        guard model.floatingImage != nil else { super.keyDown(with: event); return }
        switch event.keyCode {
        case 36, 76:  model.commitFloating()   // Return / Enter
        case 53:      model.cancelFloating()   // Escape
        default:      super.keyDown(with: event)
        }
        needsDisplay = true
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let cg = NSGraphicsContext.current?.cgContext,
              let image = model.bitmap.makeImage() else { return }

        cg.interpolationQuality = .none
        cg.draw(image, in: bounds)

        // Live preview for shape tools
        if let start = startPoint, model.tool.isShape {
            model.drawShape(in: cg, from: start, to: currentPoint, constrain: constrain)
        }

        // Floating pasted image with dashed border
        if let floating = model.floatingImage, let rect = model.floatingRect {
            cg.saveGState()
            cg.interpolationQuality = .high
            cg.draw(floating, in: rect)
            cg.setStrokeColor(NSColor.systemBlue.cgColor)
            cg.setLineWidth(1)
            cg.setLineDash(phase: 0, lengths: [5, 3])
            cg.stroke(rect.insetBy(dx: 0.5, dy: 0.5))
            cg.restoreGState()
        }
    }

    // MARK: Mouse

    private func location(of event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = location(of: event)

        // A pasted image is pending: drag it, or click outside to place it
        if let rect = model.floatingRect {
            if rect.contains(p) {
                isDraggingFloating = true
                floatingGrabOffset = CGPoint(x: p.x - rect.origin.x, y: p.y - rect.origin.y)
            } else {
                model.commitFloating()
            }
            needsDisplay = true
            return
        }

        lastPoint = p
        currentPoint = p
        constrain = event.modifierFlags.contains(.shift)

        switch model.tool {
        case .eyedropper:
            model.pickColor(at: p)
        case .fill:
            model.pushUndo()
            model.floodFill(at: p)
        case .pencil, .brush, .eraser:
            startPoint = p
            model.pushUndo()
            model.drawSegment(from: p, to: p)
        case .spray:
            startPoint = p
            model.pushUndo()
            model.spray(at: p)
        case .line, .rectangle, .oval:
            startPoint = p
        case .text:
            beginText(at: p)
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = location(of: event)

        if isDraggingFloating {
            model.floatingOrigin = CGPoint(x: (p.x - floatingGrabOffset.x).rounded(),
                                           y: (p.y - floatingGrabOffset.y).rounded())
            needsDisplay = true
            return
        }

        guard startPoint != nil else { return }
        constrain = event.modifierFlags.contains(.shift)
        currentPoint = p

        if model.tool.isFreehand {
            model.drawSegment(from: lastPoint, to: p)
            lastPoint = p
        } else if model.tool == .spray {
            model.spray(at: p)
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if isDraggingFloating {
            isDraggingFloating = false
            return
        }

        guard let start = startPoint else { return }
        let p = location(of: event)
        constrain = event.modifierFlags.contains(.shift)

        if model.tool.isShape {
            model.pushUndo()
            model.drawShape(in: model.bitmap, from: start, to: p, constrain: constrain)
        }
        startPoint = nil
        needsDisplay = true
    }
}

// MARK: - Text tool

extension CanvasNSView {
    /// Called whenever the model changes (tool, font size, color, ...).
    func modelDidChange() {
        guard activeTextView != nil else { return }
        if model.tool != .text {
            DispatchQueue.main.async { [weak self] in self?.commitText() }
        } else {
            applyTextStyle()
        }
    }

    func beginText(at point: CGPoint) {
        commitText()

        let tv = NSTextView(frame: .zero)
        tv.delegate = self
        tv.isRichText = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.containerSize = NSSize(width: 100_000, height: 100_000)
        tv.isHorizontallyResizable = true
        tv.isVerticallyResizable = true
        tv.maxSize = NSSize(width: 100_000, height: 100_000)
        tv.wantsLayer = true
        tv.layer?.borderWidth = 1
        tv.layer?.borderColor = NSColor.systemBlue.cgColor

        activeTextView = tv
        textTopLeft = point
        addSubview(tv)
        applyTextStyle()
        window?.makeFirstResponder(tv)
    }

    fileprivate func applyTextStyle() {
        guard let tv = activeTextView else { return }
        tv.font = model.textFont
        tv.textColor = model.textColor
        tv.insertionPointColor = model.textColor
        resizeTextView()
    }

    fileprivate func resizeTextView() {
        guard let tv = activeTextView, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
        lm.ensureLayout(for: tc)
        let used = lm.usedRect(for: tc)
        let lineH = lm.defaultLineHeight(for: model.textFont)
        let w = max(used.width + 8, 40)
        let h = max(used.height, lineH)
        // Keep the top-left corner fixed while the box grows
        tv.frame = NSRect(x: textTopLeft.x, y: textTopLeft.y - h, width: w, height: h)
    }

    /// Stamps the text box contents into the image and removes the box.
    func commitText() {
        guard let tv = activeTextView else { return }
        activeTextView = nil
        let text = tv.string
        let rect = tv.frame
        let font = tv.font ?? model.textFont
        let color = tv.textColor ?? model.textColor
        tv.removeFromSuperview()
        window?.makeFirstResponder(self)

        if !text.isEmpty {
            let attributed = NSAttributedString(string: text,
                                                attributes: [.font: font, .foregroundColor: color])
            model.drawText(attributed, in: rect)
        }
        needsDisplay = true
    }

    fileprivate func cancelText() {
        guard let tv = activeTextView else { return }
        activeTextView = nil
        tv.removeFromSuperview()
        window?.makeFirstResponder(self)
        needsDisplay = true
    }
}

extension CanvasNSView: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        resizeTextView()
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            commitText()          // Return places the text
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            cancelText()          // Esc discards it
            return true
        default:
            return false          // ⌥Return etc. use default behavior (new line)
        }
    }
}
