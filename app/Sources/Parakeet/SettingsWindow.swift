import AppKit
import SwiftUI

/// Where captions sit, how they look, what they're translated into, and
/// which speech model listens. While it's open the caption box shows
/// sample text, so changes can be seen and the box dragged into place.
final class SettingsWindow: NSWindow, NSWindowDelegate {
    init(translator: Translator) {
        super.init(contentRect: .init(x: 0, y: 0, width: 520, height: 780),
                   styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        title = String(localized: "Parappa Settings")
        isReleasedWhenClosed = false
        contentViewController = NSHostingController(rootView: SettingsView(translator: translator))
        setContentSize(.init(width: 520, height: 780))
        center()
        delegate = self
    }

    func show() {
        Prefs.shared.previewing = true
        makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    var onClose: (() -> Void)?

    func windowWillClose(_ notification: Notification) {
        Prefs.shared.previewing = false
        onClose?()
    }
}

private struct SettingsView: View {
    let translator: Translator
    @Bindable private var prefs = Prefs.shared
    private let refiner = RefinerStatus.shared
    @State private var screens = NSScreen.screens.map(\.localizedName)
    private let families = NSFontManager.shared.availableFontFamilies
        .filter { !$0.hasPrefix(".") }
        .map { (name: $0, shown: NSFontManager.shared.localizedName(forFamily: $0, face: nil)) }
        .sorted { $0.shown.localizedStandardCompare($1.shown) == .orderedAscending }

    var body: some View {
        Form {
            Section("Caption Position") {
                Picker("Position", selection: $prefs.placement) {
                    Text("Bottom of Screen").tag(CaptionPlacement.bottom)
                    Text("Top of Screen").tag(CaptionPlacement.top)
                    Text("Where Dragged").tag(CaptionPlacement.custom)
                }
                if screens.count > 1 {
                    Picker("Display", selection: $prefs.screenName) {
                        Text("Main Display").tag("")
                        ForEach(screens, id: \.self) { Text($0).tag($0) }
                    }
                }
                Toggle(isOn: $prefs.locked) {
                    Text("Lock Position")
                    Text("Clicks pass through the captions, so they can't be dragged and their buttons don't show.")
                }
                .accessibilityLabel(Text("Lock Position"))
                Text("Drag the caption box to move it anywhere. While this window is open, sample captions show where it is.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Text") {
                Picker("Font", selection: $prefs.fontFamily) {
                    Text("System Font").tag("")
                    Divider()
                    ForEach(families, id: \.name) { Text($0.shown).tag($0.name) }
                }
                Picker("Weight", selection: $prefs.weight) {
                    Text("Regular").tag(CaptionWeight.regular)
                    Text("Medium").tag(CaptionWeight.medium)
                    Text("Semibold").tag(CaptionWeight.semibold)
                    Text("Bold").tag(CaptionWeight.bold)
                }
                SizeSlider(title: "Caption Size", value: $prefs.mainSize, range: 14...56)
                SizeSlider(title: "Original Size", detail: "The original shown small under its translation.",
                           value: $prefs.originalSize, range: 10...40)
            }

            Section("Translation") {
                Picker("Translate To", selection: Binding(
                    get: { translator.target?.minimalIdentifier },
                    set: { translator.target = $0.map(Locale.Language.init(identifier:)) })) {
                    Text("Off").tag(String?.none)
                    ForEach(translator.languages, id: \.self) { Text(Translator.name($0)).tag(Optional($0.minimalIdentifier)) }
                }
                if let target = translator.target {
                    let name = Translator.name(target)
                    Toggle(isOn: $prefs.showNative) {
                        Text("Show \(name) Speech Too")
                        Text("When off, captions hide while the speech is already in \(name).")
                    }
                    .accessibilityLabel(Text("Show \(name) Speech Too"))
                }
            }

            Section("Speech Recognition") {
                Picker("Model", selection: $prefs.model) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Fast")
                        Text("Nemotron 3.5. Words show as they're spoken.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    .tag(ModelChoice.fast)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Accurate")
                        Text("Nemotron 3.5 shows words dimmed as they're spoken, then Cohere Transcribe corrects each sentence when it ends. Downloads about 2 GB more and uses more power.")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .tag(ModelChoice.accurate)
                }
                .pickerStyle(.radioGroup)
                if prefs.model == .accurate {
                    Text(refiner.line).font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            screens = NSScreen.screens.map(\.localizedName)
        }
    }
}

private struct SizeSlider: View {
    let title: LocalizedStringKey
    var detail: LocalizedStringKey?
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        LabeledContent {
            HStack(spacing: 10) {
                // Whole points, without a step (which draws a tick for every point).
                Slider(value: Binding(get: { value }, set: { value = $0.rounded() }), in: range)
                    .accessibilityLabel(Text(title))
                Text("\(Int(value)) pt")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
            .frame(width: 240)
        } label: {
            Text(title)
            if let detail { Text(detail) }
        }
    }
}

extension RefinerStatus {
    /// One line on what Cohere Transcribe is doing, or nil when it isn't in use.
    var line: String {
        switch state {
        case .waiting: String(localized: "Cohere Transcribe waits for the speech model.")
        case .downloading(let fraction): String(localized: "Downloading Cohere Transcribe… \(Int(fraction * 100))%")
        case .preparing: String(localized: "Preparing Cohere Transcribe. The first time takes a few minutes.")
        case .ready: String(localized: "Cohere Transcribe ready")
        case .failed(let reason): String(localized: "Cohere Transcribe couldn't load (\(reason)). Captions continue with Nemotron alone; reopen Parappa to try again.")
        }
    }
}
