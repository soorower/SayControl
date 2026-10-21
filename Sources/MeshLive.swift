// The first seconds of a dictation, heard twice.
//
// The local models are at their best with context: give Cohere a sentence and
// it beats the cloud, but hand it "open Claude" cold and it guesses. The paid
// sockets are the opposite — sharpest from the first word. So the mesh runs
// both from the same press of fn: a paid provider's live socket AND the local
// re-decoder, each with its own mic tap. Released inside the window, the
// dictation was a short command and the paid text pastes. Held past it, the
// paid socket is cancelled — its job is done, its billing stops — and the
// local model, which re-runs over the WHOLE clip on every pass including
// those first seconds, owns the preview and the paste. Nothing is merged
// between the two, so nothing ever needs syncing.
//
// Fail-safe shape: the local ear is the one that must not fail (it hears the
// whole clip), the paid head is optional. A dead socket degrades the mesh to
// plain local dictation; a dead local ear keeps the paid socket for the whole
// take rather than going deaf at the handover; and a local ear that comes
// back EMPTY past the window pastes what the paid ear heard in its seconds
// rather than nothing — the words it already showed are not thrown away.
import AVFoundation
import Cocoa

final class MeshLiveTranscriber: LiveSession {
    var onText: ((String) -> Void)?
    var onLevel: ((CGFloat) -> Void)?
    var onFinish: ((Result<String, Error>) -> Void)?
    /// The tape rides the local session: it runs the whole clip at 16 kHz
    /// whatever the paid socket streams at, so the header never lies.
    var tape: AudioTape? {
        didSet { local.tape = tape }
    }
    var sampleRate: Double { local.sampleRate }

    private let paid: LiveTranscriber
    private let paidTitle: String
    private let local: LocalLiveTranscriber
    private let window: TimeInterval

    // Main-queue owned — both children deliver every callback on main, the
    // timer fires on main, and finish()/cancel() are called from main.
    private var pastWindow = false
    private var finishing = false
    private var delivered = false
    private var lastLocal = ""
    /// The paid ear's words as they stood when the window closed — the net
    /// under a local ear that decodes the whole take to nothing.
    private var lastPaid = ""
    private var paidResult: Result<String, Error>?
    private var localResult: Result<String, Error>?
    private var handover: Timer?

    /// Nil unless the mesh is switched on, pointed at a provider with a key,
    /// and local live streaming is actually available — the call site falls
    /// back to plain local, which is also what the mesh degrades to at runtime.
    static func make() -> MeshLiveTranscriber? {
        let config = Config.shared
        guard config.meshEnabled else { return nil }
        let provider = config.meshProvider
        guard let key = config.apiKey(for: provider) else { return nil }
        let paid = LiveTranscriber(provider: provider,
                                   model: config.model(for: provider, live: true),
                                   key: key)
        return MeshLiveTranscriber(paid: paid, provider: provider,
                                   local: LocalLiveTranscriber(),
                                   window: config.meshSeconds)
    }

    init(paid: LiveTranscriber, provider: Provider, local: LocalLiveTranscriber,
         window: TimeInterval) {
        self.paid = paid
        self.paidTitle = provider.title
        self.local = local
        self.window = window
    }

    // MARK: - Start

    func start() throws {
        paid.onText = { [weak self] text in
            guard let self = self, !self.pastWindow else { return }
            self.lastPaid = text
            self.onText?(text)
        }
        local.onText = { [weak self] text in
            guard let self = self else { return }
            // Always kept warm, shown only after the handover — so the swap
            // is to text that already covers the whole clip, not to a blank.
            self.lastLocal = text
            if self.pastWindow { self.onText?(text) }
        }
        local.onLevel = { [weak self] level in self?.onLevel?(level) }
        paid.onFinish = { [weak self] result in self?.childFinished(paid: true, result) }
        local.onFinish = { [weak self] result in self?.childFinished(paid: false, result) }

        try local.start()
        do {
            try paid.start()
        } catch {
            Config.shared.log("Mesh: \(paidTitle) couldn't start (\(error.localizedDescription)) — running local only")
            handOver()
            return
        }
        Config.shared.log("Mesh: \(paidTitle) hears the first \(Int(window))s, then local takes over")
        handover = Timer.scheduledTimer(withTimeInterval: window, repeats: false) { [weak self] _ in
            self?.windowClosed()
        }
    }

    /// The window elapsed: this take is a sentence, not a command.
    private func windowClosed() {
        guard !finishing, !delivered else { return }
        if case .some(.failure) = localResult {
            Config.shared.log("Mesh: local ear failed — staying on \(paidTitle) for the whole take")
            return
        }
        paid.cancel()
        handOver()
    }

    private func handOver() {
        guard !pastWindow else { return }
        pastWindow = true
        if !lastLocal.isEmpty { onText?(lastLocal) }
    }

    // MARK: - Finish

    func finish(grace: TimeInterval? = nil) {
        guard !finishing, !delivered else { return }
        finishing = true
        handover?.invalidate()
        if pastWindow {
            local.finish(grace: grace)
        } else {
            paid.finish(grace: grace)
            // The local pass is nearly free and is the net under the paid
            // result — an ear that heard nothing must not cost the dictation.
            local.finish(grace: grace)
        }
        // Both children may already have called back before fn was released.
        maybeDeliver()
    }

    func cancel() {
        guard !delivered else { return }
        delivered = true
        handover?.invalidate()
        onFinish = nil
        onText = nil
        onLevel = nil
        paid.cancel()
        local.cancel()
    }

    private func childFinished(paid isPaid: Bool, _ result: Result<String, Error>) {
        if isPaid { paidResult = result } else { localResult = result }
        // The paid socket ending mid-window — dropped, refused, or salvaged —
        // means the local ear is the only one still listening: swap the
        // preview now rather than freezing the last paid words on screen.
        if isPaid, !finishing, !pastWindow {
            handover?.invalidate()
            if case .failure(let error) = result {
                Config.shared.log("Mesh: \(paidTitle) dropped mid-window (\(error.localizedDescription)) — local takes over early")
            }
            handOver()
            return
        }
        maybeDeliver()
    }

    private func maybeDeliver() {
        guard finishing, !delivered else { return }
        if pastWindow {
            // Local owns the take; a late paid echo changes nothing — unless
            // local came back with nothing at all, when the paid ear's first
            // seconds beat an empty paste.
            guard let result = localResult else { return }
            if case .success(let text) = result, !text.isEmpty { return deliver(result) }
            if !lastPaid.isEmpty {
                Config.shared.log("Mesh: local ear came back empty past the window — pasting what \(paidTitle) heard in the first \(Int(window))s")
                return deliver(.success(lastPaid))
            }
            deliver(result)
            return
        }
        // A short take: the paid text wins whenever there is any.
        if case .some(.success(let text)) = paidResult, !text.isEmpty {
            return deliver(.success(text))
        }
        guard let paidOutcome = paidResult, let localOutcome = localResult else { return }
        // The paid ear came back empty or broken — whatever the local one
        // heard beats it, and an honest empty beats a socket error.
        if case .success = localOutcome { return deliver(localOutcome) }
        deliver(paidOutcome)
    }

    private func deliver(_ result: Result<String, Error>) {
        guard !delivered else { return }
        delivered = true
        handover?.invalidate()
        paid.cancel()
        local.cancel()
        let callback = onFinish
        onFinish = nil
        onText = nil
        onLevel = nil
        DispatchQueue.main.async { callback?(result) }
    }
}
