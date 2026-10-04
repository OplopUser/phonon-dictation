import AVFoundation

// Streams a 16 kHz WAV through Streamer (the same code the app runs) and checks
// the pasted text against one transcription of the whole file: chunking must
// not lose, double or invent words. Exits 1 on failure.

let url = URL(fileURLWithPath: CommandLine.arguments[1])
let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
try file.read(into: buffer)
precondition(file.processingFormat.sampleRate == Recorder.sampleRate, "expects 16 kHz audio")
let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
let endpoint = URL(string: "http://127.0.0.1:8010/v1/audio/transcriptions")!

var pasted = ""
let streamer = Streamer(endpoint: endpoint) { text in
    print("  paste: \"\(text)\"")
    pasted += text
}
for start in stride(from: 0, to: samples.count, by: 1600) {  // 100 ms blocks, like the mic
    streamer.append(Array(samples[start..<min(start + 1600, samples.count)]))
}
streamer.finish()
Streamer.waitUntilIdle()

func words(_ text: String) -> [String] {
    text.split(separator: " ").map { $0.lowercased().filter { $0.isLetter || $0.isNumber } }.filter { !$0.isEmpty }
}
func editDistance(_ a: [String], _ b: [String]) -> Int {
    var row = Array(0...b.count)
    for i in 1...max(1, a.count) where !a.isEmpty {
        var previous = row[0]
        row[0] = i
        for j in stride(from: 1, through: b.count, by: 1) {
            let current = row[j]
            row[j] = min(row[j] + 1, row[j - 1] + 1, previous + (a[i - 1] == b[j - 1] ? 0 : 1))
            previous = current
        }
    }
    return a.isEmpty ? b.count : row[b.count]
}

let whole = (transcribeWords(samples[...], endpoint: endpoint) ?? []).map(\.word).joined(separator: " ")
let distance = editDistance(words(pasted), words(whole))
print("  whole: \"\(whole)\"")
let allowed = 2  // the model may hear a word slightly differently with less context
print(distance <= allowed ? "PASS (\(distance) word differences)" : "FAIL (\(distance) word differences)")
exit(distance <= allowed ? 0 : 1)
