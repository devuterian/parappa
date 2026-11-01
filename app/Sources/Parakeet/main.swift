import FluidAudio
import AppKit
import ServiceManagement
import Sparkle
import SwiftUI
import Translation

/// `Parappa <command>` talks to the running app over distributed notifications.
enum Control {
    static let command = Notification.Name("com.marierie.parappa.command")
    static let reply = Notification.Name("com.marierie.parappa.status")
    static let usage = "usage: Parappa status | captions on|off"
}

/// Which speech model to run: the one picked in Settings (Nemotron alone,
/// or Nemotron corrected by Cohere Transcribe), or one named with
/// `--engine nemotron|hybrid|ultra` for side-by-side debugging.
enum EngineKind: String {
    case nemotron, ultra, hybrid

    static let override: EngineKind? = {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count >= 2, args[0] == "--engine" else { return nil }
        return EngineKind(rawValue: args[1])
    }()

    static var current: EngineKind { override ?? (Prefs.shared.model == .accurate ? .hybrid : .nemotron) }

    var modelName: String {
        switch self {
        case .nemotron: return "Nemotron 3.5"
        case .ultra: return "Parakeet Ultra"
        case .hybrid: return "Nemotron 3.5 + Cohere Transcribe"
        }
    }

    func make(rehearseFirstLaunch: Bool, bench: Bool = false, onEvent: @escaping (EngineEvent) -> Void) -> Engine {
        switch self {
        case .nemotron: return NemotronEngine(rehearseFirstLaunch: rehearseFirstLaunch, onEvent: onEvent)
        case .ultra: return UltraEngine(rehearseFirstLaunch: rehearseFirstLaunch, onEvent: onEvent)
        case .hybrid: return HybridEngine(rehearseFirstLaunch: rehearseFirstLaunch, waitForRefiner: bench, onEvent: onEvent)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let captions = Captions()
    private let translator = Translator()
    private lazy var panel = makePanel()

    private func makePanel() -> CaptionPanel {
        CaptionPanel(captions: captions, translator: translator,
                     onClose: { [weak self] in self?.stopListening() },
                     onCopy: { [weak self] in self?.copyTranscript() })
    }

    /// A locked panel ignores the mouse everywhere; AppKit can't be told to
    /// go back to letting only its clear parts through, so unlocking swaps
    /// in a new panel.
    private func followLock() {
        let locked = Prefs.shared.locked
        withObservationTracking { _ = Prefs.shared.locked } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.followLock()
                if locked, !Prefs.shared.locked {
                    let shown = self.panel.isVisible
                    self.panel.close()
                    self.panel = self.makePanel()
                    if shown { self.panel.orderFrontRegardless() }
                }
            }
        }
    }
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let tap = SystemAudioTap()
    // Into the captions' language, else the user's own if Translation knows it, else English.
    private lazy var snap = SnapTranslate { [translator] in
        if let target = translator.target { return target }
        let supported = await LanguageAvailability().supportedLanguages
        return supported.first { $0.isSame(as: Locale.current.language) } ?? Locale.Language(identifier: "en")
    }
    private lazy var updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
    private var engine: Engine?
    private var engineKind = EngineKind.current
    /// Counts engines started; events from one already replaced are dropped
    /// (a stopped engine's model download can't be interrupted).
    private var generation = 0
    /// Whether captions start once the model is ready: not after a model
    /// switch while they were off.
    private var resumeListening = true
    private lazy var settings = SettingsWindow(translator: translator)
    private var onboarding: Onboarding?   // set while the first-launch window is open
    private var onboardingWindow: OnboardingWindow?
    private var status = String(localized: "Loading speech model…")
    private var ready = false
    private var listening = false
    private var rehearse = false

    /// What the menu and `Parappa status` show; a revoked permission explains
    /// why nothing is being captioned.
    private var statusLine: String {
        listening && AudioPermission.status == .denied
            ? String(localized: "Audio access is off. Open System Settings and turn on Parappa.") : status
    }

    private var engineTag: String {
        EngineKind.override == .ultra ? " [Parakeet Ultra]" : ""
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGPIPE, SIG_IGN)
        // Sparkle's own schedule checks at most daily and skips the first launch;
        // also check on every launch, right after the updater starts (as Sparkle advises).
        if updater.updater.automaticallyChecksForUpdates { updater.updater.checkForUpdatesInBackground() }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()
        // `open Parappa.app --args --rehearse-first-launch` replays what a new user sees.
        rehearse = CommandLine.arguments.contains("--rehearse-first-launch")
        if rehearse || !UserDefaults.standard.bool(forKey: "onboarded") { showOnboarding() }
        startEngine()
        _ = snap
        SystemAudioTap.onOutputDeviceChange { [weak self] in self?.restartTap() }
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [captions, translator] _ in
            if captions.partial.isEmpty { translator.settle(after: 2) }  // nobody mid-sentence
            // Fade out once nobody has spoken for a while; the original and its
            // translation go together, though the translation arrives later.
            let shown = translator.target == nil ? [captions] : [captions, translator.output]
            if shown.allSatisfy({ $0.idle > 6 }) { shown.forEach { $0.clear() } }
        }
        DistributedNotificationCenter.default().addObserver(forName: Control.command, object: nil, queue: .main) { [weak self] note in
            self?.run(command: note.object as? String ?? "")
        }
        followModelChoice()
        followLock()
    }

    /// Restarts the engine when another model is picked in Settings.
    private func followModelChoice() {
        withObservationTracking { _ = Prefs.shared.model } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.followModelChoice()
                if EngineKind.current != self.engineKind { self.switchModel() }
            }
        }
    }

    private func switchModel() {
        // Still loading: whatever was meant to happen once it's ready still holds.
        resumeListening = listening || (!ready && resumeListening)
        if listening { stopListening() }
        engine?.stop()
        engine = nil
        ready = false
        captions.clear()
        startEngine()
    }

    @objc private func showSettings() {
        // The box shows sample text while Settings is open, captions on or off.
        settings.onClose = { [weak self] in if self?.listening == false { self?.panel.orderOut(nil) } }
        settings.show()
        panel.orderFrontRegardless()
    }

    func applicationWillTerminate(_ notification: Notification) {
        tap.stop()
        engine?.stop()
    }

    private func showOnboarding() {
        let onboarding = Onboarding()
        let window = OnboardingWindow(onboarding)
        onboarding.onFinish = { [weak self] in self?.finishOnboarding() }
        onboarding.onRetry = { [weak self] in self?.startEngine() }
        // If macOS quits and reopens Parappa to apply Screen Recording, it comes back set up.
        // (Open at Login waits for the page that shows its switch.)
        onboarding.onScreenRecording = { [rehearse] in if !rehearse { UserDefaults.standard.set(true, forKey: "onboarded") } }
        self.onboarding = onboarding
        onboardingWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func finishOnboarding() {
        guard let onboarding else { return }
        self.onboarding = nil
        UserDefaults.standard.set(true, forKey: "onboarded")
        if onboarding.openAtLogin, SMAppService.mainApp.status != .enabled { try? SMAppService.mainApp.register() }
        onboardingWindow?.close()
        onboardingWindow = nil
        if ready { startListening() }
    }

    private func run(command: String) {
        switch command {
        case "captions on": if ready, !listening { startListening() }
        case "captions off": if listening { stopListening() }
        default: break
        }
        DistributedNotificationCenter.default().postNotificationName(Control.reply, object: statusLine, userInfo: nil, deliverImmediately: true)
    }

    // Rebuilt each time it opens so it always reflects current state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(withTitle: statusLine + engineTag, action: nil, keyEquivalent: "")
        if engineKind == .hybrid, ready {
            menu.addItem(withTitle: RefinerStatus.shared.line, action: nil, keyEquivalent: "")
        }
        if engine == nil {
            menu.addItem(withTitle: String(localized: "Try Again"), action: #selector(startEngine), keyEquivalent: "")
        } else if listening, AudioPermission.status == .denied {
            menu.addItem(withTitle: String(localized: "Open System Settings"), action: #selector(openAudioSettings), keyEquivalent: "")
        }
        menu.addItem(.separator())
        let toggle = menu.addItem(withTitle: String(localized: "Captions"), action: #selector(toggleListening), keyEquivalent: "l")
        toggle.state = listening ? .on : .off
        toggle.isEnabled = ready
        let copy = menu.addItem(withTitle: String(localized: "Copy Transcript"), action: #selector(copyTranscript), keyEquivalent: "")
        copy.isEnabled = !captions.transcript.isEmpty
        let translate = NSMenu()
        for language in [nil] + translator.languages.map(Optional.some) {
            let item = translate.addItem(withTitle: language.map(Translator.name) ?? String(localized: "Off"), action: #selector(translateTo(_:)), keyEquivalent: "")
            item.representedObject = language?.minimalIdentifier
            item.state = language?.minimalIdentifier == translator.target?.minimalIdentifier ? .on : .off
        }
        menu.setSubmenu(translate, for: menu.addItem(withTitle: String(localized: "Translate To"), action: nil, keyEquivalent: ""))
        let screen = menu.addItem(withTitle: String(localized: "Translate Screen"), action: #selector(SnapTranslate.start), keyEquivalent: "1")
        screen.keyEquivalentModifierMask = [.command, .shift]
        screen.target = snap
        menu.addItem(.separator())
        let login = menu.addItem(withTitle: String(localized: "Open at Login"), action: #selector(toggleOpenAtLogin), keyEquivalent: "")
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(withTitle: String(localized: "Settings…"), action: #selector(showSettings), keyEquivalent: ",")
        let update = menu.addItem(withTitle: String(localized: "Check for Updates…"), action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "")
        update.target = updater
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Quit Parappa"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    private func handle(_ event: EngineEvent) {
        switch event {
        case .downloading(let fraction):
            status = String(localized: "Downloading speech model… \(Int(fraction * 100))%")
            onboarding?.model = .downloading(fraction)
        case .preparing:
            status = String(localized: "Preparing speech model…")
            onboarding?.model = .preparing
        case .ready:
            ready = true
            status = String(localized: "Ready")
            onboarding?.model = .ready
            // Captions start once the welcome window is done with.
            if onboarding == nil, resumeListening, !listening { startListening() }
        case .partial(let text):
            if translator.hear(text) { captions.clear() }  // a fresh box when the language flips
            captions.update(text)
        case .final(let text):
            lock(text, endsSentence: true)
        case .fragment(let text):
            lock(text, endsSentence: false)
        case .exited(let reason):
            let reason = reason.isEmpty ? String(localized: "unknown error") : reason
            ready = false
            engine = nil
            stopListening()
            status = String(localized: "Speech model stopped: \(reason)")
            onboarding?.model = .failed(reason)
        }
        updateIcon()
    }

    /// Loads the speech model; runs again from "Try Again" after a failure.
    @objc private func startEngine() {
        guard engine == nil else { return }
        status = String(localized: "Loading speech model…")
        onboarding?.model = .waiting
        engineKind = EngineKind.current
        generation += 1
        let current = generation
        engine = engineKind.make(rehearseFirstLaunch: rehearse) { [weak self] event in
            guard let self, self.generation == current else { return }
            self.handle(event)
        }
        updateIcon()
    }

    private func lock(_ text: String, endsSentence: Bool) {
        if translator.hear(text) { captions.clear() }
        captions.lock(text)
        translator.translate(text, ends: endsSentence)
    }

    @objc private func toggleListening() {
        listening ? stopListening() : startListening()
        resumeListening = listening
    }

    private func startListening() {
        do {
            try tap.start { [weak self] pcm in self?.engine?.send(pcm) }
            listening = true
            status = String(localized: "Listening to system audio")
            panel.orderFrontRegardless()
        } catch {
            tap.stop()
            status = String(localized: "Can't capture audio: \(error.localizedDescription)")
        }
        updateIcon()
    }

    /// Rebuilds the tap on the new output device, which keeps captions going
    /// when headphones are plugged in or disconnected.
    private func restartTap() {
        guard listening else { return }
        stopListening()
        startListening()
    }

    private func stopListening() {
        tap.stop()
        listening = false
        panel.orderOut(nil)
        if ready { status = String(localized: "Off") }
        updateIcon()
    }

    @objc private func translateTo(_ item: NSMenuItem) {
        translator.target = (item.representedObject as? String).map(Locale.Language.init(identifier:))
    }

    @objc private func openAudioSettings() { AudioPermission.openSettings() }

    @objc private func copyTranscript() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(captions.transcript.joined(separator: "\n"), forType: .string)
    }

    @objc private func toggleOpenAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            // Usually means the user switched it off in System Settings; send them there.
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    private func updateIcon() {
        let name = listening ? "captions.bubble.fill" : "captions.bubble"
        statusItem.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: "Parappa")
    }
}

extension AppDelegate: SPUStandardUserDriverDelegate {
    // A menu bar app is never the active app, so Sparkle would leave an update it
    // found waiting behind other windows. Bring it to the front instead.
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        guard !handleShowingUpdate else { return }
        DispatchQueue.main.async { [self] in
            NSApp.activate()
            updater.checkForUpdates(nil)
        }
    }
}

// A fresh copy asked by the running app whether Screen Recording is allowed
// now (see ScreenRecording.allowed): answer, and quit before anything else.
if CommandLine.arguments.contains(ScreenRecording.checkFlag) { exit(CGPreflightScreenCaptureAccess() ? 0 : 1) }

let args = Array(CommandLine.arguments.dropFirst())
// Drop a leading "--engine <name>" (read by EngineKind.current) so the
// commands below only see their own arguments.
let commands = args.count >= 2 && args[0] == "--engine" ? Array(args.dropFirst(2)) : args

if let first = commands.first, ["status", "captions"].contains(first) {
    let command = commands.joined(separator: " ")
    guard ["status", "captions on", "captions off"].contains(command) else { print(Control.usage); exit(2) }
    DistributedNotificationCenter.default().addObserver(forName: Control.reply, object: nil, queue: .main) { note in
        print(note.object as? String ?? "")
        exit(0)
    }
    DistributedNotificationCenter.default().postNotificationName(Control.command, object: command, userInfo: nil, deliverImmediately: true)
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { print("Parappa isn't running"); exit(1) }
    RunLoop.main.run()
}

// `Parappa --bench file.wav` plays a 16 kHz float32 WAV into the engine in
// real time and prints what it heard and the CPU time it took.
if commands.count == 2, commands[0] == "--bench" {
    let data = try! Data(contentsOf: URL(fileURLWithPath: commands[1]))
    // Find the start of the "data" chunk's payload: its own 4-byte size field
    // sits between the id and the samples, and other chunks may come first.
    var pcm = Data()
    var offset = 12  // past RIFF size and WAVE id
    while offset + 8 <= data.count {
        let id = data[offset..<offset + 4]
        let size = data[offset + 4..<offset + 8].withUnsafeBytes { $0.load(as: UInt32.self) }
        if id == Data("data".utf8) {
            pcm = data[(offset + 8)..<min(offset + 8 + Int(size), data.count)]
            break
        }
        offset += 8 + Int(size) + Int(size % 2)  // chunks are 2-byte aligned
    }
    guard !pcm.isEmpty else { print("no data chunk in", commands[1]); exit(2) }
    let started = Date()
    var engine: Engine?
    HybridEngine.verbose = true
    engine = EngineKind.current.make(rehearseFirstLaunch: false, bench: true) { event in
        let t = String(format: "%5.2f", Date().timeIntervalSince(started))
        switch event {
        case .downloading, .preparing: break
        case .ready:
            print(t, "ready")
            DispatchQueue.global().async {
                func cpuTime() -> Double {
                    var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
                    return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
                }
                let cpu0 = cpuTime(), t0 = Date()
                let step = 1600 * 4
                for i in stride(from: pcm.startIndex, to: pcm.endIndex, by: step) {
                    engine?.send(pcm[i..<min(i + step, pcm.endIndex)])
                    Thread.sleep(forTimeInterval: 0.1)
                }
                // The tap keeps streaming silence after speech stops.
                for _ in 0..<30 { engine?.send(Data(count: step)); Thread.sleep(forTimeInterval: 0.1) }
                // Ultra's sliding window still holds up to a chunk of audio; flush it.
                let sem = DispatchSemaphore(value: 0)
                Task { await engine?.finish(); sem.signal() }
                sem.wait()
                print(String(format: "cpu %.0f%% of one core", (cpuTime() - cpu0) / Date().timeIntervalSince(t0) * 100))
                exit(0)
            }
        case .final(let text): print(t, "final:", text)
        case .fragment(let text): print(t, "fragment:", text)
        case .partial(let text): print(t, "  ~", text)
        case .exited(let reason): print("exited:", reason); exit(1)
        }
    }
    RunLoop.main.run()
}

// `Parappa --cohere file.wav ko [from] [to]` transcribes a 16 kHz float32 WAV
// (or the seconds from..to of it) with Cohere Transcribe in one call.
if commands.count >= 3, commands[0] == "--cohere" {
    let data = try! Data(contentsOf: URL(fileURLWithPath: commands[1]))
    let range = data.range(of: Data("data".utf8))!
    var samples = data[(range.upperBound + 4)...].withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    if commands.count >= 5, let from = Double(commands[3]), let to = Double(commands[4]) {
        samples = Array(samples[Int(from * 16_000)..<min(samples.count, Int(to * 16_000))])
    }
    let language = CohereAsrConfig.Language(rawValue: commands[2])!
    Task {
        let models = try await CohereLoader.shared.models()
        let result = try await CoherePipeline().transcribe(audio: samples, models: models, language: language)
        print(result.tokenIds.count, "tokens:", result.text)
        exit(0)
    }
    RunLoop.main.run()
}

// `Parappa --snap in.png out.png [language]` reads and translates an image
// as ⇧⌘1 does the screen, and writes it out with every translation laid in.
if commands.count >= 3, commands[0] == "--snap" {
    guard let source = NSImage(contentsOfFile: commands[1])?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        print("can't read", commands[1]); exit(2)
    }
    NSApplication.shared.setActivationPolicy(.accessory)
    setvbuf(stdout, nil, _IOLBF, 0)  // timings show up as they happen, even piped
    let job = SnapJob(image: source, scale: 2, target: Locale.Language(identifier: commands.count > 3 ? commands[3] : "ko"))
    let started = Date()
    var patches: [Patch] = []
    job.onFail = { print("nothing to translate, or translation failed"); exit(1) }
    job.onFound = { print(String(format: "%.2f s  read: %d paragraphs", Date().timeIntervalSince(started), $0.count)) }
    job.onReady = {
        patches += $0
        print(String(format: "%.2f s  %d translated", Date().timeIntervalSince(started), $0.count))
    }
    // What the card would tick: macOS asks before downloading each.
    job.onMissing = { missing in
        print("offered:", missing.map { "\($0.language.minimalIdentifier)\($0.likely ? "" : " (unticked)") “\($0.sample)”" })
        // Downloading means macOS asking first; only with PARAKEET_DOWNLOAD set, so a run never stops to wait.
        job.download(ProcessInfo.processInfo.environment["PARAKEET_DOWNLOAD"] == nil ? [] : missing.filter(\.likely).map(\.language))
    }
    job.onFinished = {
        try! NSBitmapImageRep(cgImage: Painter.compose(patches, over: source)!).representation(using: .png, properties: [:])!
            .write(to: URL(fileURLWithPath: commands[2]))
        print(String(format: "%.2f s", Date().timeIntervalSince(started)))
        exit(0)
    }
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1, height: 1), styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = NSHostingView(rootView: TranslationHost(job: job))
    window.orderFrontRegardless()
    job.read()
    NSApplication.shared.run()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
