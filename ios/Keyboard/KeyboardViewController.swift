import SwiftUI
import UIKit

/// The Speak keyboard. iOS doesn't allow microphone access inside keyboards, so
/// dictation happens in the Speak app (🎙 opens it) and this keyboard inserts the
/// result into any app, joined smartly to the text already before the cursor.
final class KeyboardViewController: UIInputViewController {
    private var host: UIHostingController<KeyboardView>?

    override func viewDidLoad() {
        super.viewDidLoad()
        let view = KeyboardView(actions: KeyboardActions(controller: self))
        let host = UIHostingController(rootView: view)
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(host)
        self.view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: self.view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: self.view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: self.view.bottomAnchor),
            host.view.heightAnchor.constraint(equalToConstant: 260),
        ])
        host.didMove(toParent: self)
        self.host = host
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        host?.rootView = KeyboardView(actions: KeyboardActions(controller: self))
    }

    /// Keyboards can't call UIApplication.open directly; walk the responder chain to the host app's
    /// UIApplication (the approach used by shipping dictation keyboards).
    func openSpeakApp() {
        guard let url = URL(string: "speak://dictate") else { return }
        var responder: UIResponder? = self
        while let r = responder {
            if let app = r as? UIApplication {
                app.open(url, options: [:], completionHandler: nil)
                return
            }
            responder = r.next
        }
        extensionContext?.open(url, completionHandler: nil)
    }
}

struct KeyboardActions {
    weak var controller: KeyboardViewController?

    var hasFullAccess: Bool { controller?.hasFullAccess ?? false }
    var needsGlobe: Bool { controller?.needsInputModeSwitchKey ?? true }

    func insert(_ text: String) {
        guard let proxy = controller?.textDocumentProxy else { return }
        proxy.insertText(SmartJoin.adapt(text, after: proxy.documentContextBeforeInput))
    }
    func space() { controller?.textDocumentProxy.insertText(" ") }
    func newline() { controller?.textDocumentProxy.insertText("\n") }
    func delete() { controller?.textDocumentProxy.deleteBackward() }
    func nextKeyboard() { controller?.advanceToNextInputMode() }
    func dictate() { controller?.openSpeakApp() }
}

struct KeyboardView: View {
    let actions: KeyboardActions
    @State private var items: [SharedStore.Item] = SharedStore.recent()

    var body: some View {
        VStack(spacing: 8) {
            if !actions.hasFullAccess {
                Text("To insert your dictations, turn on Allow Full Access:\nSettings → General → Keyboard → Keyboards → Speak.")
                    .font(.footnote).multilineTextAlignment(.center).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty {
                Text("Tap 🎙 to dictate in Speak, then come back and tap your text to insert it.")
                    .font(.footnote).multilineTextAlignment(.center).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(items.prefix(8)) { item in
                            Button { actions.insert(item.text) } label: {
                                Text(item.text)
                                    .font(.callout).lineLimit(2).multilineTextAlignment(.leading)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 12).padding(.vertical, 8)
                                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 8)
                }
            }
            HStack(spacing: 8) {
                if actions.needsGlobe {
                    key(Image(systemName: "globe"), width: 44) { actions.nextKeyboard() }
                }
                key(Image(systemName: "mic.fill").foregroundStyle(.white), width: 56, tint: .accentColor) { actions.dictate() }
                key(Text("space"), width: nil) { actions.space() }
                key(Image(systemName: "delete.left"), width: 52) { actions.delete() }
                key(Image(systemName: "return"), width: 52) { actions.newline() }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 6)
        }
        .padding(.top, 8)
        .onAppear { items = SharedStore.recent() }
    }

    private func key<L: View>(_ label: L, width: CGFloat?, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            label
                .font(.system(size: 17, weight: .medium))
                .frame(maxWidth: width == nil ? .infinity : width, minHeight: 44)
                .frame(width: width)
                .background(tint ?? Color(.systemBackground).opacity(0.9), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}
