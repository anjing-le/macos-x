import AppKit
import AVFoundation

@main struct RecordingAudioRegression {
    static var checks = 0
    static func check(_ value: Bool, _ message: String) throws {
        checks += 1
        if !value { throw NSError(domain: "audio-regression", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func pcm(rate: Double = 48_000, channels: AVAudioChannelCount = 2, frames: Int = 960,
                    frequency: Double = 440, phase: Int = 0, value: Float? = nil) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for channel in 0..<Int(channels) { for i in 0..<frames {
            buffer.floatChannelData![channel][i] = value ?? Float(0.25 * sin(2 * .pi * frequency * Double(phase + i) / rate))
        } }
        return buffer
    }
    static func main() async throws {
        setbuf(stdout, nil)
        print("Checking audio preferences and bounded mixer")
        let suite = "cc.anjing.macos-x.audio-fixture.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try check(RecordingAudioOptions(defaults: defaults) == .init(), "silent remains the default")
        for system in [false, true] { for mic in [false, true] {
            let options = RecordingAudioOptions(system: system, microphone: mic)
            options.save(to: defaults)
            try check(RecordingAudioOptions(defaults: UserDefaults(suiteName: suite)!) == options, "all four choices survive reopening")
        } }
        let mixer = RecordingAudioMixer(options: .init(system: true, microphone: true))
        mixer.add(pcm(frames: 4800, value: 0.25), at: 0, source: .system)
        mixer.add(pcm(frames: 2400, value: 0.75), at: 2400, source: .microphone)
        let mixed = mixer.take(4800)
        try check(abs(mixed.floatChannelData![0][0] - 0.125) < 0.0001, "missing microphone interval is silent")
        try check(abs(mixed.floatChannelData![0][3000] - 0.5) < 0.0001, "two sources mix at the correct timestamp")
        mixer.add(pcm(frames: 4800, value: 1), at: 0, source: .system)
        mixer.add(pcm(frames: 4800, value: 1), at: 100_000, source: .system)
        let empty = mixer.take(4800)
        try check(empty.floatChannelData![0][0] == 0, "late and far-future packets cannot wrap into current audio")
        let onlyMic = RecordingAudioMixer(options: .init(microphone: true))
        onlyMic.add(pcm(value: 1), at: 0, source: .system)
        onlyMic.add(pcm(value: 0.25), at: 0, source: .microphone)
        let micOnlyPCM = onlyMic.take(960)
        try check(micOnlyPCM.floatChannelData![1][100] == 0.25, "disabled source is ignored and single-source gain stays unchanged")
        let wrapping = RecordingAudioMixer(options: .init(system: true))
        for _ in 0..<12 {
            wrapping.add(pcm(frames: 4800, value: 0.4), at: wrapping.cursor, source: .system)
            let wrappedPCM = wrapping.take(4800)
            try check(abs(wrappedPCM.floatChannelData![0][10] - 0.4) < 0.0001, "bounded ring survives wraparound")
        }
        wrapping.add(pcm(value: .nan), at: wrapping.cursor, source: .system)
        let finitePCM = wrapping.take(960)
        try check(finitePCM.floatChannelData![0][10] == 0, "nonfinite source samples do not poison the file")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("recording-audio-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for options in [RecordingAudioOptions(system: true), .init(microphone: true), .init(system: true, microphone: true)] {
            print("Checking MP4 system=\(options.system) microphone=\(options.microphone)")
            let url = folder.appendingPathComponent("\(options.system)-\(options.microphone).mp4")
            let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
            let audio = try RecordingAudioWriter(writer: writer, options: options)
            try check(writer.startWriting(), "actual AAC encoder starts")
            let anchor = CMTime(seconds: 10, preferredTimescale: 48_000)
            writer.startSession(atSourceTime: anchor); audio.begin(at: anchor)
            for packet in 0..<50 {
                let time = CMTimeAdd(anchor, CMTime(seconds: Double(packet) / 50, preferredTimescale: 48_000))
                if options.system {
                    let buffer = pcm(frequency: 440, phase: packet * 960)
                    try audio.receive(RecordingAudioWriter.sample(buffer, at: time), source: .system, hostTime: time)
                }
                if options.microphone {
                    // Real resampling and mono-to-stereo conversion, like a device using a different rate.
                    let buffer = pcm(rate: 44_100, channels: 1, frames: 882, frequency: 1000, phase: packet * 882)
                    try audio.receive(RecordingAudioWriter.sample(buffer, at: time), source: .microphone, hostTime: time)
                }
                try audio.flush(through: max(0, Double(packet + 1) / 50 - 0.15))
                try await Task.sleep(nanoseconds: 4_000_000)
            }
            try audio.flush(through: 1, final: true)
            writer.endSession(atSourceTime: CMTimeAdd(anchor, CMTime(seconds: 1, preferredTimescale: 48_000)))
            audio.input.markAsFinished()
            await writer.finishWriting()
            print("Decoding saved AAC")
            try check(writer.status == .completed, "real MP4 finalizes: \(writer.error?.localizedDescription ?? "")")
            try check(audio.droppedBlocks == 0, "fixture does not hide dropped audio")
            let asset = AVURLAsset(url: url)
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            try check(tracks.count == 1, "ordinary players receive one mixed AAC track")
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: tracks[0], outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMIsFloatKey: true,
                AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false
            ])
            reader.add(output); try check(reader.startReading(), "AAC playback decoder starts")
            var samples = [Float]()
            while let sample = output.copyNextSampleBuffer() {
                let format = AVAudioFormat(cmAudioFormatDescription: sample.formatDescription!)
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sample.numSamples))!
                buffer.frameLength = AVAudioFrameCount(sample.numSamples)
                try check(CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(sample.numSamples),
                    into: buffer.mutableAudioBufferList) == noErr, "decoded PCM is readable")
                let floats = buffer.floatChannelData![0]
                for i in 0..<sample.numSamples { samples.append(floats[i * Int(format.channelCount)]) }
            }
            try check(reader.status == .completed && samples.count >= 45_000, "saved audio plays for the full duration")
            func amplitude(_ frequency: Double) -> Double {
                let window = samples.dropFirst(4800).prefix(38_400)
                var cosine = 0.0, sine = 0.0
                for (i, value) in window.enumerated() {
                    let angle = 2 * .pi * frequency * Double(i) / 48_000
                    cosine += Double(value) * cos(angle); sine += Double(value) * sin(angle)
                }
                return 2 * hypot(cosine, sine) / Double(window.count)
            }
            try check(options.system ? amplitude(440) > 0.08 : amplitude(440) < 0.02, "system tone is present only when selected")
            try check(options.microphone ? amplitude(1000) > 0.08 : amplitude(1000) < 0.02, "microphone tone is present only when selected")
            try check(amplitude(3000) < 0.02, "conversion does not introduce a spurious tone")
        }
        print("PASS recording audio: \(checks) assertions; preferences, bounded timestamp mixing, real AAC MP4 encode/decode and both audible sources; synthetic inputs, no live capture or microphone permission")
    }
}
