
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: CanvasModel

    private let swatches: [Color] = [
        .black, .gray, .white, .red, .orange, .yellow,
        .green, .teal, .blue, .purple, .pink, .brown
    ]
    private let toolColumns = [GridItem(.fixed(40)), GridItem(.fixed(40)), GridItem(.fixed(40))]
    private let swatchColumns = [GridItem(.fixed(24)), GridItem(.fixed(24)), GridItem(.fixed(24)), GridItem(.fixed(24))]

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            canvasArea
        }
        .toolbar {
            ToolbarItemGroup {
                Button { model.showingNewSheet = true } label: {
                    Label("New", systemImage: "doc")
                }
                Button { model.openImage() } label: {
                    Label("Open", systemImage: "folder")
                }
                Button { model.saveImage() } label: {
                    Label("Save", systemImage: "square.and.arrow.down")
                }
                Button { model.pasteFromClipboard() } label: {
                    Label("Paste", systemImage: "doc.on.clipboard")
                }
                .help("Paste image from clipboard (⌘V)")
            }
            ToolbarItemGroup {
                Button { model.undo() } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
                .disabled(!model.canUndo)

                Button { model.redo() } label: {
                    Label("Redo", systemImage: "arrow.uturn.forward")
                }
                .disabled(!model.canRedo)

                Button { model.clear() } label: {
                    Label("Clear", systemImage: "trash")
                }
            }
        }
        .sheet(isPresented: $model.showingNewSheet) {
            NewCanvasSheet().environmentObject(model)
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle("Tools")
            LazyVGrid(columns: toolColumns, spacing: 6) {
                ForEach(Tool.allCases) { tool in
                    Button { model.tool = tool } label: {
                        Image(systemName: tool.symbol)
                            .font(.system(size: 16))
                            .frame(width: 36, height: 30)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(model.tool == tool ? Color.accentColor.opacity(0.3) : Color.clear)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(model.tool == tool ? Color.accentColor : Color.secondary.opacity(0.3))
                            )
                            .contentShape(RoundedRectangle(cornerRadius: 6))   // whole button is clickable
                    }
                    .buttonStyle(.plain)
                    .help(tool.label)
                }
            }

            sectionTitle("Colors")
            HStack(spacing: 10) {
                VStack(spacing: 2) {
                    ColorPicker("", selection: $model.primaryColor).labelsHidden()
                    Text("Stroke").font(.caption2)
                }
                VStack(spacing: 2) {
                    ColorPicker("", selection: $model.secondaryColor).labelsHidden()
                    Text("Fill").font(.caption2)
                }
                Button {
                    let tmp = model.primaryColor
                    model.primaryColor = model.secondaryColor
                    model.secondaryColor = tmp
                } label: {
                    Image(systemName: "arrow.left.arrow.right")
                }
                .help("Swap colors")
            }

            LazyVGrid(columns: swatchColumns, spacing: 4) {
                ForEach(swatches.indices, id: \.self) { i in
                    let c = swatches[i]
                    Button { model.primaryColor = c } label: {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(c)
                            .frame(width: 22, height: 22)
                            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.secondary.opacity(0.5)))
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Set as Fill Color") { model.secondaryColor = c }
                    }
                }
            }
            Text("Right-click a swatch to use it as fill")
                .font(.caption2)
                .foregroundStyle(.secondary)

            sectionTitle("Size: \(Int(model.lineWidth)) px")
            Slider(value: $model.lineWidth, in: 1...50)

            Toggle("Fill shapes", isOn: $model.fillShapes)
                .font(.callout)

            if model.tool == .text {
                sectionTitle("Text")
                Stepper("Size: \(Int(model.fontSize)) pt", value: $model.fontSize, in: 8...200, step: 2)
                    .font(.callout)
                Toggle("Bold", isOn: $model.boldText)
                    .font(.callout)
                Text("Return places the text.\n⌥Return adds a line.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(12)
        .frame(width: 150)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.headline)
    }

    // MARK: Canvas

    private var canvasArea: some View {
        GeometryReader { geo in
            ScrollView([.horizontal, .vertical]) {
                CanvasRepresentable(model: model)
                    .frame(width: model.canvasSize.width, height: model.canvasSize.height)
                    .shadow(radius: 3)
                    .padding(24)
            }
            .background(Color(nsColor: .underPageBackgroundColor))
            .onAppear { fitCanvas(to: geo.size) }
            .onChange(of: geo.size) { newSize in fitCanvas(to: newSize) }
        }
    }

    /// Fills the visible area (minus padding) with a blank canvas.
    private func fitCanvas(to size: CGSize) {
        DispatchQueue.main.async {
            model.fitCanvasToViewport(CGSize(width: size.width - 52, height: size.height - 52))
        }
    }
}

// MARK: - New canvas sheet

struct NewCanvasSheet: View {
    @EnvironmentObject var model: CanvasModel
    @Environment(\.dismiss) private var dismiss
    @State private var width = 800
    @State private var height = 600

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Canvas").font(.headline)
            HStack {
                Text("Width").frame(width: 50, alignment: .leading)
                TextField("Width", value: $width, format: .number)
                    .frame(width: 80)
                Text("px")
            }
            HStack {
                Text("Height").frame(width: 50, alignment: .leading)
                TextField("Height", value: $height, format: .number)
                    .frame(width: 80)
                Text("px")
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") {
                    model.newCanvas(width: width, height: height)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 300)
        .onAppear {
            width = Int(model.canvasSize.width)
            height = Int(model.canvasSize.height)
        }
    }
}
