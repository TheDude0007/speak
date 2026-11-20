import SwiftUI

@main
struct SpeakApp: App {
    @StateObject private var model = DictationModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .task { await model.prepare() }
                .onOpenURL { url in
                    // speak://dictate — sent by the Speak keyboard
                    if url.host == "dictate" {
                        Task {
                            while model.phase == .preparing { try? await Task.sleep(nanoseconds: 100_000_000) }
                            model.start()
                        }
                    }
                }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var model: DictationModel
    @State private var showSettings = false
    @State private var showHistory = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                transcript
                Spacer(minLength: 0)
                MicButton()
                Text(hint).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
            .navigationTitle("Speak")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showHistory = true } label: { Image(systemName: "clock.arrow.circlepath") }
                        .accessibilityLabel("History")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView().environmentObject(model) }
            .sheet(isPresented: $showHistory) { HistoryView().environmentObject(model) }
        }
    }

    private var hint: String {
        switch model.phase {
        case .preparing: return model.status
        case .failed: return model.status
        case .recording: return "Release to finish · or tap again if you tapped to start"
        case .finishing: return "Polishing…"
        case .ready:
            if let ms = model.lastMs { return "Hold to talk · tap for hands-free · last: \(ms) ms" }
            return "Hold to talk · tap for hands-free\nCopied automatically · insert anywhere with the Speak keyboard"
        }
    }

    @ViewBuilder private var transcript: some View {
        let showing = model.isRecording || model.phase == .finishing ? model.live : model.result
        VStack(alignment: .leading, spacing: 12) {
            if model.isRecording || model.phase == .finishing || model.result.isEmpty {
                Text(showing.isEmpty ? (model.isRecording ? "Listening…" : "Your words appear here.") : showing)
                    .font(.title3)
                    .foregroundStyle(showing.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, minHeight: 160, alignment: .topLeading)
                    .animation(.easeOut(duration: 0.1), value: showing)
            } else {
                TextEditor(text: $model.result)
                    .font(.title3)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 160)
                HStack {
                    Button { model.copy(model.result) } label: { Label("Copy", systemImage: "doc.on.doc") }
                    ShareLink(item: model.result) { Label("Share", systemImage: "square.and.arrow.up") }
                    Spacer()
                    Button(role: .destructive) { model.result = "" } label: { Image(systemName: "xmark.circle") }
                        .accessibilityLabel("Clear")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(18)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24))
    }
}

struct MicButton: View {
    @EnvironmentObject var model: DictationModel
    @State private var pressing = false

    var body: some View {
        let recording = model.isRecording
        ZStack {
            Circle()
                .fill(recording ? Color.red.opacity(0.18) : Color.accentColor.opacity(0.14))
                .frame(width: 168, height: 168)
                .scaleEffect(recording ? 1 + model.level * 0.35 : 1)
                .animation(.easeOut(duration: 0.08), value: model.level)
            Circle()
                .fill(recording ? Color.red : Color.accentColor)
                .frame(width: 120, height: 120)
                .shadow(radius: pressing ? 2 : 8)
            if model.phase == .finishing {
                ProgressView().tint(.white).controlSize(.large)
            } else {
                Image(systemName: recording ? "waveform" : "mic.fill")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(.white)
                    .symbolEffect(.variableColor.iterative, isActive: recording)
            }
        }
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !pressing { pressing = true; model.pressBegan() }
                }
                .onEnded { _ in
                    pressing = false
                    model.pressEnded()
                }
        )
        .disabled(model.phase == .preparing || model.phase == .finishing || model.phase == .failed)
        .accessibilityLabel(recording ? "Stop dictation" : "Start dictation")
        .accessibilityAddTraits(.isButton)
    }
}

struct HistoryView: View {
    @EnvironmentObject var model: DictationModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if model.recent.isEmpty {
                    Text("Nothing yet").foregroundStyle(.secondary)
                }
                ForEach(model.recent) { item in
                    Button {
                        model.copy(item.text)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.text).foregroundStyle(.primary).lineLimit(4)
                            Text(item.date, style: .relative).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            SharedStore.remove(item); model.recent = SharedStore.recent()
                        } label: { Label("Delete", systemImage: "trash") }
                    }
                }
            }
            .navigationTitle("Recent — tap to copy")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .destructiveAction) {
                    Button("Clear") { SharedStore.clear(); model.recent = [] }.disabled(model.recent.isEmpty)
                }
            }
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: DictationModel
    @Environment(\.dismiss) private var dismiss
    @State private var apiKey = Keychain.apiKey ?? ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Smart grammar & punctuation", isOn: $model.smartGrammar)
                        .disabled(model.grammarNote != nil)
                        .onChange(of: model.smartGrammar) { model.reloadEngine() }
                    Toggle("Remove filler words (um, uh)", isOn: $model.removeFillers)
                    Toggle("Copy result automatically", isOn: $model.autoCopy)
                } footer: {
                    Text(model.grammarNote.map { "Smart grammar needs Apple Intelligence: \($0)." }
                         ?? "Runs on-device with Apple Intelligence. Pause to think as long as you like: punctuation follows meaning, not pauses.")
                }
                Section {
                    Text("1. Settings → General → Keyboard → Keyboards → Add New Keyboard → Speak\n2. Tap Speak → turn on Allow Full Access (lets the keyboard read your dictations; nothing is sent anywhere)\n3. In any app, switch to the Speak keyboard with 🌐 and tap a dictation to insert it, or 🎙 to dictate.")
                        .font(.callout)
                } header: { Text("Speak keyboard") }
                Section {
                    Toggle("AI polish with Claude", isOn: $model.aiPolish)
                        .onChange(of: model.aiPolish) { model.reloadEngine() }
                    SecureField("Claude API key (sk-ant-…)", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit { Keychain.apiKey = apiKey.isEmpty ? nil : apiKey; model.reloadEngine() }
                } footer: {
                    Text("Optional. Sends the transcript text (never audio) to Claude. Key is stored in your Keychain.")
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { Keychain.apiKey = apiKey.isEmpty ? nil : apiKey; dismiss() }
                }
            }
        }
    }
}
