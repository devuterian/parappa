import FluidAudio
import Foundation
import NaturalLanguage

/// What Cohere Transcribe, the accuracy model, is doing; shown in the menu
/// and the settings window.
@Observable
final class RefinerStatus {
    static let shared = RefinerStatus()
    enum State: Equatable { case waiting, downloading(Double), preparing, ready, failed(String) }
    var state: State = .waiting
}

/// Downloads and loads Cohere Transcribe once for the whole app, however
/// often the model is switched: a 2 GB download can't be interrupted, and
/// two at once would write the same files.
@MainActor
final class CohereLoader {
    static let shared = CohereLoader()
    private var task: Task<CoherePipeline.LoadedModels, Error>?

    func models() async throws -> CoherePipeline.LoadedModels {
        if let task { return try await task.value }
        let status = RefinerStatus.shared
        let task = Task.detached(priority: .utility) { () async throws -> CoherePipeline.LoadedModels in
            let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("FluidAudio/Models", isDirectory: true)
            let dir = root.appendingPathComponent(Repo.cohereTranscribeCoreml.folderName, isDirectory: true)
            return try await ModelHub.loadWithRecovery(
                .cohereTranscribeCoreml, directory: root,
                requiredFiles: ModelNames.CohereTranscribe.requiredModels,
                progressHandler: { progress in
                    DispatchQueue.main.async { status.state = .downloading(progress.fractionCompleted) }
                }
            ) {
                await MainActor.run { status.state = .preparing }
                // Neural Engine only: its compiled model is cached by macOS, so
                // later launches load in a second. On the GPU, every launch
                // spends ~90 s of one core expanding the int8 weights.
                let models = try await CoherePipeline.loadModels(
                    encoderDir: dir, decoderDir: dir, vocabDir: dir, computeUnits: .cpuAndNeuralEngine)
                // The first transcription after a launch takes ~10 s more; spend it now, not on speech.
                _ = try? await CoherePipeline().transcribe(audio: [Float](repeating: 0, count: 16_000), models: models)
                return models
            }
        }
        self.task = task
        do {
            let models = try await task.value
            status.state = .ready
            return models
        } catch {
            self.task = nil  // the next engine tries again
            status.state = .failed(error.localizedDescription)
            throw error
        }
    }
}

/// Nemotron's words as they're spoken, shown dim as a draft; each stretch
/// of speech is then transcribed again whole by Cohere Transcribe (more
/// accurate, but it needs the stretch to be over) and its text replaces the
/// draft and is locked in.
///
/// Stretches are cut where Silero VAD hears speech stop, or at the quietest
/// moment once one runs past `maxSegment`. Nemotron's words are placed in
/// the audio by how much it had heard when it wrote them, so the ones a
/// stretch replaces are those written before its end (plus Nemotron's lag).
/// Until Cohere is ready, or for a language it doesn't know, Nemotron's own
/// words are locked in instead.
final class HybridEngine: Engine {
    private static let rate = 16_000
    private static let maxSegment = 16 * rate        // Cohere v2 decodes 108 tokens per call at most
    private static let pad = rate / 5                // audio kept either side of a stretch at a pause
    /// How long after a word is spoken Nemotron may write it: one 560 ms
    /// chunk, plus the VAD's padding.
    private static let lag = 8_960 + 1_600

    private let onEvent: (EngineEvent) -> Void
    private let waitForRefiner: Bool
    private var nemotron: NemotronEngine?
    private let audio = AudioLog()
    private var refiner: Task<Void, Never>?

    // Main thread only.
    private struct Word { var text: String; var at: Int }
    private var committed: [Word] = []   // words Nemotron has locked
    private var tail: [Word] = []        // its unlocked words
    private var refining = false         // Cohere is loaded: drafts wait for it

    /// `waitForRefiner` holds back `.ready` until Cohere is loaded too (the bench).
    init(rehearseFirstLaunch: Bool = false, waitForRefiner: Bool = false, onEvent: @escaping (EngineEvent) -> Void) {
        self.onEvent = onEvent
        self.waitForRefiner = waitForRefiner
        nemotron = NemotronEngine(rehearseFirstLaunch: rehearseFirstLaunch) { [weak self] event, at in
            self?.heard(event, at: at)
        }
    }

    func send(_ pcm: Data) {
        nemotron?.send(pcm)
        audio.append(pcm)
    }

    func stop() {
        nemotron?.stop()
        refiner?.cancel()
    }

    /// Waits for the last stretch to be transcribed (the bench's trailing silence ends it).
    func finish() async {
        for _ in 0..<600 where !audio.drained { try? await Task.sleep(for: .milliseconds(100)) }
        try? await Task.sleep(for: .seconds(1))
    }

    // MARK: Nemotron's side (main thread)

    private func heard(_ event: EngineEvent, at: Int) {
        switch event {
        case .ready:
            if !waitForRefiner { onEvent(.ready) }
            startRefiner()
        case .partial(let text) where refining:
            tail = Self.words(text, keeping: tail, at: at)
            showDraft()
        case .final(let text) where refining, .fragment(let text) where refining:
            lock(Self.split(text), at: at)
            showDraft()
        case .exited:
            refiner?.cancel()
            onEvent(event)
        default:
            onEvent(event)  // downloads, and Nemotron's own captions until Cohere is ready
        }
    }

    /// Nemotron locked these words: the tail's first ones. Japanese and
    /// Chinese aren't spaced, so a lock at "。" can end inside a tail
    /// "word"; what's left of it stays in the tail.
    private func lock(_ words: [String], at: Int) {
        for word in words {
            guard var first = tail.first else {
                committed.append(Word(text: word, at: at))
                continue
            }
            committed.append(Word(text: word, at: first.at))
            if first.text.count > word.count, first.text.hasPrefix(word) {
                first.text.removeFirst(word.count)
                tail[0] = first
            } else {
                tail.removeFirst()
            }
        }
    }

    private var draft: String { Self.join((committed + tail).map(\.text)) }

    private func showDraft() { onEvent(.partial(draft)) }

    /// The draft's words written up to `end` (in samples), without removing them.
    private func draft(upTo end: Int) -> String {
        Self.join((committed + tail).prefix { $0.at <= end }.map(\.text))
    }

    /// Locks in a stretch: Cohere's text if it has one, else the draft's
    /// words written up to `end`, which leave the draft either way.
    private func confirm(upTo end: Int, text: String?) {
        let fromCommitted = committed.prefix { $0.at <= end }.count
        var words = Array(committed.prefix(fromCommitted))
        committed.removeFirst(fromCommitted)
        if committed.isEmpty {
            let fromTail = tail.prefix { $0.at <= end }.count
            words += tail.prefix(fromTail)
            tail.removeFirst(fromTail)
        }
        let locked = (text?.isEmpty == false ? text : nil) ?? Self.join(words.map(\.text))
        if !locked.isEmpty {
            onEvent(locked.last.map { ".?!。？！".contains($0) } == true ? .final(locked) : .fragment(locked))
        }
        showDraft()
    }

    /// Cohere is gone (it failed): lock the draft as it is and caption with Nemotron alone.
    private func stopRefining() {
        guard refining else { return }
        refining = false
        let rest = draft
        committed = []
        tail = []
        if !rest.isEmpty { onEvent(.fragment(rest)) }
    }

    // MARK: Cohere's side

    private func startRefiner() {
        guard refiner == nil else { return }
        let audio = audio
        refiner = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let models = try await CohereLoader.shared.models()
                let vad = try await VadManager()
                // The download may finish after this engine was stopped.
                try Task.checkCancellation()
                await MainActor.run {
                    guard let self else { return }
                    self.refining = true
                    if self.waitForRefiner { self.onEvent(.ready) }
                }
                try await self?.listen(audio: audio, vad: vad, cohere: models)
            } catch is CancellationError {
            } catch {
                let reason = error.localizedDescription
                await MainActor.run {
                    guard let self else { return }
                    self.stopRefining()
                    if self.waitForRefiner { self.onEvent(.exited(reason)) }
                }
            }
        }
    }

    /// Follows the audio with the VAD and hands each finished stretch of speech to Cohere.
    private func listen(audio: AudioLog, vad: VadManager, cohere models: CoherePipeline.LoadedModels) async throws {
        let pipeline = CoherePipeline()
        let chunk = VadManager.chunkSize
        // Short enough to end a stretch between sentences, even in a newsreader's pace.
        let config = VadSegmentationConfig(minSilenceDuration: 0.35, speechPadding: 0.1)
        var state = await vad.makeStreamState()
        audio.recording = true
        defer { audio.recording = false }
        var cursor = audio.end              // next sample for the VAD
        var start: Int?                     // where the stretch being heard began
        var startPadded = true              // began at a pause, not a cut
        var quiet: [(at: Int, p: Float)] = [] // recent speech probabilities, to cut a long stretch where it's quietest
        var language = Self.defaultLanguage // the last one heard, for stretches the draft can't tell
        var waiting = Date()                // since audio last arrived

        /// `paused`: it ended at a pause (padded with what's around it, and
        /// Nemotron's lag allowed for); else it was cut mid-speech.
        func transcribe(_ from: Int, _ to: Int, paused: Bool) async {
            let behind = audio.end - cursor
            let samples = audio.slice(from: startPadded ? from - Self.pad : from, to: paused ? to + Self.pad : to)
            let end = paused ? to + Self.lag : to
            let heard = await MainActor.run { self.draft(upTo: end) }
            switch Self.language(of: heard) {
            case .some(let known): language = known
            case .none: break
            }
            var text: String?
            // Fallen far behind (a slow Mac), or a language Cohere doesn't know: the draft stands.
            if behind < 8 * Self.rate, samples.count >= Self.rate / 3, let language {
                let t0 = Date()
                do {
                    let result = try await pipeline.transcribe(audio: samples, models: models, language: language)
                    text = Self.trusted(result, over: heard)
                    if Self.verbose {
                        FileHandle.standardError.write(Data(String(format: "cohere %.2fs for %.1fs [%@] %d tokens%@: %@\n  draft: %@\n",
                            Date().timeIntervalSince(t0), Double(samples.count) / Double(Self.rate), language.rawValue,
                            result.tokenIds.count, text == nil ? " (kept draft)" : "",
                            result.text.replacingOccurrences(of: "\n", with: " "), heard).utf8))
                    }
                } catch {
                    if Self.verbose { FileHandle.standardError.write(Data("cohere failed: \(error)\n".utf8)) }
                }
            }
            let locked = text
            await MainActor.run { self.confirm(upTo: end, text: locked) }
            startPadded = paused
        }

        while !Task.isCancelled {
            guard let samples = audio.slice(from: cursor, count: chunk) else {
                let idle = Date().timeIntervalSince(waiting)
                // Audio stopped coming (captions turned off): end the stretch there.
                if idle > 1, let begun = start {
                    start = nil
                    await transcribe(begun, cursor, paused: true)
                    state = await vad.makeStreamState()
                }
                audio.drained = start == nil
                // Nothing playing for a while: check less often.
                try await Task.sleep(for: .milliseconds(idle > 2 ? 250 : 60))
                continue
            }
            waiting = Date()
            audio.drained = false
            cursor += chunk
            // Digital silence between stretches: nothing for the VAD to do.
            if start == nil, !samples.contains(where: { abs($0) > 1e-4 }) {
                audio.trim(before: cursor - Self.rate)
                continue
            }
            let result = try await vad.processStreamingChunk(samples, state: state, config: config)
            state = result.state
            let offset = cursor - state.processedSamples  // VAD sample index → ours
            if Self.verbose, let event = result.event {
                FileHandle.standardError.write(Data(String(format: "vad %.2fs %@\n", Double(event.sampleIndex + offset) / Double(Self.rate),
                    event.isStart ? "start" : "end").utf8))
            }
            quiet.append((cursor - chunk / 2, result.probability))
            quiet.removeAll { $0.at < cursor - 7 * Self.rate }

            if let event = result.event {
                if event.isStart, start == nil {
                    start = event.sampleIndex + offset
                    startPadded = true
                } else if event.isEnd, let begun = start {
                    start = nil
                    await transcribe(begun, event.sampleIndex + offset, paused: true)
                }
            }
            // Too long to wait for a pause: cut at the quietest moment of the last few seconds.
            if let begun = start, cursor - begun > Self.maxSegment {
                let candidates = quiet.filter { $0.at > cursor - 6 * Self.rate && $0.at < cursor - Self.rate / 2 }
                let cut = candidates.min { $0.p < $1.p }?.at ?? cursor
                start = cut
                await transcribe(begun, cut, paused: false)
            }
            audio.trim(before: (start ?? cursor) - Self.rate)
        }
    }

    static var verbose = false

    /// Before anything is heard: the Mac's own language, if Cohere knows it.
    private static let defaultLanguage: CohereAsrConfig.Language? =
        Locale.preferredLanguages.lazy.compactMap { Locale.Language(identifier: $0).languageCode?.identifier }
            .compactMap { CohereAsrConfig.Language(rawValue: $0) }.first

    /// Cohere needs the language named; it's taken from the draft. `.some(nil)`
    /// for a language Cohere doesn't know (the draft stands), nil when the
    /// draft is too short or unclear to tell (the last language is used).
    private static func language(of text: String) -> CohereAsrConfig.Language?? {
        guard text.count >= 4 else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let (heard, sure) = recognizer.languageHypotheses(withMaximum: 1).first, sure >= 0.5 else { return nil }
        let code = Locale.Language(identifier: heard.rawValue).languageCode?.identifier ?? heard.rawValue
        return .some(CohereAsrConfig.Language(rawValue: code))
    }

    /// Cohere's text, unless it looks wrong next to the draft: empty, or far
    /// longer (a decoder stuck repeating itself), or cut off at the token cap.
    private static func trusted(_ result: CoherePipeline.TranscriptionResult, over draft: String) -> String? {
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return nil }
        if !draft.isEmpty, text.count > draft.count * 3 + 30 { return nil }
        // Clearly shorter than what Nemotron heard: Cohere dropped speech (it
        // can skip a sentence, or give "그, 음." for one). Numbers written as
        // digits make it a little shorter on its own, hence the slack.
        let length = { (s: String) in s.filter { !$0.isWhitespace }.count }
        if length(draft) >= 12, length(text) * 10 < length(draft) * 7 { return nil }
        if result.tokenIds.count >= CohereAsrConfig.maxSeqLen - 4 { return nil }
        return text
    }

    // MARK: Words

    private static func split(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// Japanese and Chinese words aren't spaced.
    private static func join(_ words: [String]) -> String {
        words.reduce(into: "") { joined, word in
            let unspaced = joined.last?.unicodeScalars.first.map { (0x3000...0x9FFF).contains($0.value) } ?? false
            joined += joined.isEmpty || unspaced ? word : " " + word
        }
    }

    /// The tail's words now, keeping when each was first written; a word
    /// still growing (more tokens of it came) takes the latest time.
    private static func words(_ text: String, keeping old: [Word], at: Int) -> [Word] {
        split(text).enumerated().map { i, word in
            i < old.count && old[i].text == word ? old[i] : Word(text: word, at: at)
        }
    }
}

/// The audio heard so far, by absolute sample index; the oldest is dropped
/// once nothing needs it. Written by the audio tap, read by the refiner.
final class AudioLog: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    private var base = 0    // index of samples[0]
    private var _drained = true
    private var _recording = false

    /// Kept only while the refiner is listening; until then audio is dropped.
    var recording: Bool {
        get { lock.withLock { _recording } }
        set { lock.withLock { _recording = newValue; if !newValue { base += samples.count; samples = [] } } }
    }

    /// The refiner has caught up and holds no unfinished stretch (the bench waits for it).
    var drained: Bool {
        get { lock.withLock { _drained } }
        set { lock.withLock { _drained = newValue } }
    }

    var end: Int { lock.withLock { base + samples.count } }

    func append(_ pcm: Data) {
        let new = pcm.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        lock.withLock {
            if _recording { samples += new.map { $0.isFinite ? min(1, max(-1, $0)) : 0 } } else { base += new.count }
        }
    }

    /// Exactly `count` samples from `from`, or nil until they've all arrived.
    func slice(from: Int, count: Int) -> [Float]? {
        lock.withLock {
            let start = from - base
            guard start >= 0, start + count <= samples.count else { return nil }
            return Array(samples[start..<start + count])
        }
    }

    /// Whatever is still kept of `from..<to`.
    func slice(from: Int, to: Int) -> [Float] {
        lock.withLock {
            let start = max(0, from - base), end = min(samples.count, to - base)
            return start < end ? Array(samples[start..<end]) : []
        }
    }

    func trim(before index: Int) {
        lock.withLock {
            let drop = min(samples.count, index - base)
            guard drop > Self.trimBatch else { return }  // not on every chunk
            samples.removeFirst(drop)
            base += drop
        }
    }

    private static let trimBatch = 16_000 * 5
}
