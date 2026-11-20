import AppKit
import SwiftUI

final class HUDModel: ObservableObject {
    enum Mode { case listening, handsFree, finishing, message }
    @Published var mode: Mode = .listening
    @Published var level: CGFloat = 0
    @Published var text: String = ""
    @Published var showText = true
}

/// Small Liquid Glass pill at the bottom of the active screen. Non-activating and
/// click-through: it never steals focus from the app you're dictating into.
final class HUD {
    let model = HUDModel()
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?
    private var lastLevelPush = 0.0

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 64),
                        styleMask: [.nonactivatingPanel, .borderless],
                        backing: .buffered, defer: true)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false
        let host = NSHostingView(rootView: HUDView(model: model))
        host.frame = p.contentRect(forFrameRect: p.frame)
        p.contentView = host
        return p
    }

    func show(_ mode: HUDModel.Mode, text: String = "") {
        hideWork?.cancel()
        model.mode = mode
        model.text = text
        if mode == .listening { model.level = 0 }
        let p = panel ?? makePanel()
        panel = p
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let vf = screen?.visibleFrame {
            p.setFrameOrigin(NSPoint(x: vf.midX - p.frame.width / 2, y: vf.minY + 28))
        }
        p.orderFrontRegardless()
    }

    func flash(_ message: String, seconds: Double = 2.2) {
        show(.message, text: message)
        hide(after: seconds)
    }

    func hide(after delay: Double = 0) {
        hideWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.panel?.orderOut(nil) }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    /// From the audio thread; coalesced to ~30 fps on main.
    func pushLevel(_ v: Float) {
        let now = CACurrentMediaTime()
        guard now - lastLevelPush > 1.0 / 30 else { return }
        lastLevelPush = now
        DispatchQueue.main.async { self.model.level = CGFloat(v) }
    }

    func pushText(_ s: String) {
        DispatchQueue.main.async { self.model.text = s }
    }
}

struct HUDView: View {
    @ObservedObject var model: HUDModel

    var body: some View {
        HStack(spacing: 10) {
            indicator.frame(width: 34, height: 22)
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .truncationMode(.head)
                .foregroundStyle(.primary)
                .frame(maxWidth: 320, alignment: .leading)
                .opacity(label.isEmpty ? 0 : 1)
        }
        .padding(.horizontal, 16)
        .frame(height: 40)
        .fixedSize()
        .glassEffect(.regular, in: Capsule())
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.12), value: model.level)
    }

    private var label: String {
        switch model.mode {
        case .listening, .handsFree:
            if model.showText, !model.text.isEmpty { return model.text }
            return model.mode == .handsFree ? "Hands-free — tap key to finish" : "Listening…"
        case .finishing: return model.text.isEmpty ? "…" : model.text
        case .message: return model.text
        }
    }

    @ViewBuilder private var indicator: some View {
        switch model.mode {
        case .listening, .handsFree:
            HStack(spacing: 3) {
                ForEach(0..<5, id: \.self) { i in
                    let shape: [CGFloat] = [0.45, 0.75, 1.0, 0.75, 0.45]
                    Capsule()
                        .fill(model.mode == .handsFree ? Color.orange : Color.accentColor)
                        .frame(width: 4, height: max(4, 22 * model.level * shape[i]))
                }
            }
        case .finishing:
            ProgressView().controlSize(.small)
        case .message:
            Image(systemName: "waveform").foregroundStyle(.secondary)
        }
    }
}
