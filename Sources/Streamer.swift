import Accelerate
import Foundation

/// Turns one hold of the key into text, pasted roughly every 5 seconds.
///
/// Every ~5 s it transcribes the audio and pastes the new words that end more
/// than a second before the end (those have enough context to be final).
/// On release the rest is transcribed and pasted.
///
/// Phonon sometimes skips a whole sentence when a clip starts in the middle of
/// speech, so clips only ever start where you started talking or in a real
/// pause: old audio is dropped only up to a silence of at least 0.3 s.
final class Streamer {
    /// All dictations share one queue so text is never pasted out of order.
    private static let queue = DispatchQueue(label: "phonon.streamer")

    private let rate = Recorder.sampleRate
    private let passSeconds = 5.0
    private let settleSeconds = 1.0  // words ending this close to the end wait for the next pass
    private let trimAfterSeconds = 20.0  // past this, drop already-pasted audio up to a pause

    private let endpoint: URL
    private let output: (String) -> Void
    private var audio: [Float] = []
    private var pastedUntil = 0.0  // seconds into `audio`; words centred before this were pasted
    private var nextPassAt = 5.0  // seconds of `audio`
    private var pastedAny = false
    private var pastedTail: [String] = []  // last few pasted words, normalised
    private var loudestWord: Float = 0

    init(endpoint: URL, output: @escaping (String) -> Void = Paster.paste) {
        self.endpoint = endpoint
        self.output = output
    }

    private var duration: Double { Double(audio.count) / rate }

    /// Blocks until every queued pass and paste has run (for the tests).
    static func waitUntilIdle() {
        queue.sync {}
    }

    func append(_ samples: [Float]) {
        Self.queue.async {
            self.audio += samples
            if self.duration >= self.nextPassAt {
                self.pass()
            }
        }
    }

    func finish() {
        Self.queue.async {
            defer { self.audio.removeAll() }
            guard self.duration - self.pastedUntil >= 0.3,
                  let words = self.newWords() ?? self.newWords() else { return }  // one retry: these are your last words
            self.paste(words)
        }
    }

    private func pass() {
        guard let words = newWords() else {
            nextPassAt = duration + settleSeconds  // server hiccup: try again a little later
            return
        }
        let settled = words.prefix { $0.end <= duration - settleSeconds }

        if let last = settled.last {
            paste(Array(settled))
            let next = words.dropFirst(settled.count).first
            pastedUntil = next.map { (last.end + $0.start) / 2 } ?? last.end + 0.05
        } else if words.isEmpty {
            pastedUntil = max(pastedUntil, duration - settleSeconds)  // only silence since the last paste
        }
        if duration > trimAfterSeconds || words.isEmpty {
            trimToPause()
        }
        nextPassAt = settled.isEmpty && !words.isEmpty ? duration + settleSeconds : pastedUntil + passSeconds
    }

    /// Words in `audio` not pasted yet, or nil if the server did not answer.
    private func newWords() -> [Word]? {
        guard let heard = transcribeWords(audio[...], endpoint: endpoint) else { return nil }
        let byTiming = heard.firstIndex { ($0.start + $0.end) / 2 > pastedUntil } ?? heard.count
        return heard[aligned(byTiming, in: heard)...].filter(isSpoken)
    }

    /// Timings move by a frame or two between passes, which can shift the
    /// boundary by a word. Nudge it so the words just before it match the end
    /// of what was already pasted, preferring a two-word match.
    private func aligned(_ start: Int, in words: [Word]) -> Int {
        guard !pastedTail.isEmpty else { return start }
        let candidates = [start, start + 1, start - 1, start + 2, start - 2].filter { $0 >= 1 && $0 <= words.count }
        for needed in [min(2, pastedTail.count), 1] {
            if let j = candidates.first(where: { j in
                j >= needed && words[(j - needed)..<j].map { normalised($0.word) } == Array(pastedTail.suffix(needed))
            }) {
                return j
            }
        }
        return start
    }

    /// Drops already-pasted audio up to the middle of the latest silence of at
    /// least 0.3 s, so the next clip starts in a pause. Keeps it all if there is none.
    private func trimToPause() {
        let frame = Int(0.02 * rate)
        let quiet = max(0.003, loudestWord * 0.05)
        let limit = min(audio.count, Int((pastedUntil - 0.3) * rate))
        var cut: Int?
        var runEnd: Int?
        var at = limit - frame
        while at >= 0 {
            if level(from: at, to: at + frame) < quiet {
                if runEnd == nil { runEnd = at + frame }
            } else {
                if let end = runEnd, end - (at + frame) >= Int(0.3 * rate) {
                    cut = (at + frame + end) / 2
                    break
                }
                runEnd = nil
            }
            at -= frame
        }
        if cut == nil, let end = runEnd, end >= Int(0.3 * rate) {
            cut = end / 2  // silence from the very start
        }
        guard let cut, cut > 0 else { return }
        audio.removeFirst(cut)
        let dropped = Double(cut) / rate
        pastedUntil -= dropped
        nextPassAt -= dropped
    }

    /// False for words heard in near silence, which the model sometimes invents ("Okay.").
    private func isSpoken(_ word: Word) -> Bool {
        // Short words' timings can land in the gap beside them, so look 0.1 s either side.
        let wordLevel = level(from: Int((word.start - 0.1) * rate), to: Int((word.end + 0.1) * rate))
        guard wordLevel >= max(0.003, loudestWord * 0.03) else { return false }
        loudestWord = max(loudestWord, wordLevel)
        return true
    }

    /// RMS of `audio` between two sample positions (clamped to the audio).
    private func level(from: Int, to: Int) -> Float {
        let lower = min(audio.count, max(0, from))
        let upper = min(audio.count, max(lower + 1, to))
        guard upper > lower else { return 0 }
        var result: Float = 0
        audio[lower..<upper].withUnsafeBufferPointer { vDSP_rmsqv($0.baseAddress!, 1, &result, vDSP_Length($0.count)) }
        return result
    }

    private func paste(_ words: [Word]) {
        guard !words.isEmpty else { return }
        let text = words.map(\.word).joined(separator: " ")
        output(pastedAny ? " " + text : text)
        pastedAny = true
        pastedTail = Array((pastedTail + words.map { normalised($0.word) }).suffix(3))
    }
}

private func normalised(_ word: String) -> String {
    word.lowercased().filter { $0.isLetter || $0.isNumber }
}
