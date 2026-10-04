import Foundation

/// Keeps a local `phonon serve` running (or reuses one already running) so the
/// model stays loaded between dictations.
final class PhononServer {
    let port = 8010
    var endpoint: URL { URL(string: "http://127.0.0.1:\(port)/v1/audio/transcriptions")! }
    private(set) var isReady = false
    private var process: Process?

    func start(completion: @escaping (Bool) -> Void) {
        DispatchQueue.global().async {
            let ok = self.ping() || self.launchAndWait()
            if ok {
                // The first request after launch compiles shaders; do it now, not on your first words.
                _ = transcribeWords([Float](repeating: 0, count: 8000)[...], endpoint: self.endpoint)
            }
            DispatchQueue.main.async {
                self.isReady = ok
                completion(ok)
            }
        }
    }

    func stop() {
        process?.terminate()
    }

    private func launchAndWait() -> Bool {
        guard let command = Bundle.main.object(forInfoDictionaryKey: "PhononCommand") as? String else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = ["serve", "--port", String(port)]
        process.standardOutput = FileHandle.nullDevice  // nothing is logged
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        self.process = process

        for _ in 0..<180 {
            if ping() { return true }
            if !process.isRunning { return false }
            Thread.sleep(forTimeInterval: 1)
        }
        return false
    }

    private func ping() -> Bool {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/models")!)
        request.timeoutInterval = 1
        let done = DispatchSemaphore(value: 0)
        var ok = false
        URLSession.shared.dataTask(with: request) { _, response, _ in
            ok = (response as? HTTPURLResponse)?.statusCode == 200
            done.signal()
        }.resume()
        done.wait()
        return ok
    }
}

struct Word {
    let word: String
    let start: Double  // seconds from the start of the samples sent
    let end: Double
}

/// Sends 16 kHz mono samples to the server and returns the words with their timings.
/// `leadSeconds` of silence go before the audio and half a second after it:
/// Phonon tends to invent a trailing "but"/"and" when audio stops abruptly.
func transcribeWords(_ samples: ArraySlice<Float>, endpoint: URL, leadSeconds: Double = 0.2) -> [Word]? {
    let lead = [Float](repeating: 0, count: Int(leadSeconds * Recorder.sampleRate))
    let tail = [Float](repeating: 0, count: Int(0.5 * Recorder.sampleRate))
    let field = { (name: String, value: String, boundary: String) in
        "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!
    }
    let boundary = "phonon-\(UUID().uuidString)"
    var body = Data()
    body.append(field("model", "phonon-2", boundary))
    body.append(field("response_format", "verbose_json", boundary))
    body.append(field("timestamp_granularities[]", "word", boundary))
    body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"chunk.wav\"\r\nContent-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
    body.append(wavData(lead + samples + tail))
    body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.timeoutInterval = 30
    request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    request.httpBody = body

    let done = DispatchSemaphore(value: 0)
    var words: [Word]?
    URLSession.shared.dataTask(with: request) { data, _, _ in
        guard let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            done.signal()
            return
        }
        if let list = json["words"] as? [[String: Any]] {
            words = list.compactMap { item in
                guard let word = item["word"] as? String, let start = item["start"] as? Double, let end = item["end"] as? Double else { return nil }
                return Word(word: word, start: max(0, start - leadSeconds), end: max(0, end - leadSeconds))
            }
        } else if (json["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            words = []  // the server leaves `words` out when it heard nothing
        }
        done.signal()
    }.resume()
    done.wait()
    return words
}

/// 16-bit PCM WAV at 16 kHz mono.
func wavData(_ samples: [Float]) -> Data {
    let rate = UInt32(Recorder.sampleRate)
    let dataSize = UInt32(samples.count * 2)
    var data = Data()
    func put<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    data.append("RIFF".data(using: .ascii)!); put(36 + dataSize)
    data.append("WAVEfmt ".data(using: .ascii)!); put(UInt32(16)); put(UInt16(1)); put(UInt16(1))
    put(rate); put(rate * 2); put(UInt16(2)); put(UInt16(16))
    data.append("data".data(using: .ascii)!); put(dataSize)
    for sample in samples {
        put(Int16(max(-1, min(1, sample)) * Float(Int16.max)))
    }
    return data
}
