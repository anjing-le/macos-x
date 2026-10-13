import Foundation
@preconcurrency import AVFoundation

struct RecordingAudioOptions: Equatable {
    static let systemKey = "recording.audio.system"
    static let microphoneKey = "recording.audio.microphone"
    var system = false
    var microphone = false
    var enabled: Bool { system || microphone }
    init(system: Bool = false, microphone: Bool = false) {
        self.system = system; self.microphone = microphone
    }
    init(defaults: UserDefaults) {
        system = defaults.bool(forKey: Self.systemKey)
        microphone = defaults.bool(forKey: Self.microphoneKey)
    }
    func save(to defaults: UserDefaults) {
        defaults.set(system, forKey: Self.systemKey)
        defaults.set(microphone, forKey: Self.microphoneKey)
    }
}

/// One fixed-size stereo ring per selected source. Late samples are discarded;
/// missing intervals stay silent. No recording-length buffers or final remix.
final class RecordingAudioMixer {
    enum Source: Int { case system, microphone }
    static let rate = 48_000
    static let capacity = 48_000
    private var rings = [[Float]](repeating: [Float](repeating: 0, count: capacity * 2), count: 2)
    private(set) var cursor: Int64 = 0
    private let options: RecordingAudioOptions
    init(options: RecordingAudioOptions) { self.options = options }

    func add(_ pcm: AVAudioPCMBuffer, at frame: Int64, source: Source) {
        guard pcm.format.sampleRate == Double(Self.rate), pcm.format.channelCount == 2,
              let channels = pcm.floatChannelData else { return }
        let count = Int64(pcm.frameLength)
        let begin = max(cursor, frame), end = min(cursor + Int64(Self.capacity), frame + count)
        guard begin < end, source == .system ? options.system : options.microphone else { return }
        for position in begin..<end {
            let offset = Int(position - frame), slot = Int(position % Int64(Self.capacity)) * 2
            rings[source.rawValue][slot] = channels[0][offset].isFinite ? channels[0][offset] : 0
            rings[source.rawValue][slot + 1] = channels[1][offset].isFinite ? channels[1][offset] : 0
        }
    }

    func take(_ count: Int) -> AVAudioPCMBuffer {
        precondition(count > 0 && count <= Self.capacity)
        let format = AVAudioFormat(standardFormatWithSampleRate: Double(Self.rate), channels: 2)!
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
        pcm.frameLength = AVAudioFrameCount(count)
        let channels = pcm.floatChannelData!
        let gain: Float = options.system && options.microphone ? 0.5 : 1
        for i in 0..<count {
            let slot = Int((cursor + Int64(i)) % Int64(Self.capacity)) * 2
            channels[0][i] = max(-1, min(1, (rings[0][slot] + rings[1][slot]) * gain))
            channels[1][i] = max(-1, min(1, (rings[0][slot + 1] + rings[1][slot + 1]) * gain))
            for source in 0..<2 { rings[source][slot] = 0; rings[source][slot + 1] = 0 }
        }
        cursor += Int64(count)
        return pcm
    }
}

/// Normalizes actual device formats, aligns sources on the host clock and
/// writes one AAC track, so ordinary players play both sources together.
final class RecordingAudioWriter {
    let input: AVAssetWriterInput
    private let mixer: RecordingAudioMixer
    private var converters: [RecordingAudioMixer.Source: AVAudioConverter] = [:]
    private var anchor: CMTime?
    private(set) var receivedSources: Set<RecordingAudioMixer.Source> = []
    private(set) var droppedBlocks = 0
    private let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!

    init(writer: AVAssetWriter, options: RecordingAudioOptions) throws {
        mixer = RecordingAudioMixer(options: options)
        input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128_000
        ])
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw CaptureFailure.message("当前编码器无法写入录屏声音。") }
        writer.add(input)
    }

    func begin(at hostTime: CMTime) { anchor = hostTime }

    func receive(_ sample: CMSampleBuffer, source: RecordingAudioMixer.Source, hostTime: CMTime) throws {
        guard let anchor, sample.isValid, CMSampleBufferDataIsReady(sample), hostTime.isNumeric,
              let description = sample.formatDescription,
              CMFormatDescriptionGetMediaType(description) == kCMMediaType_Audio else { return }
        let sourceFormat = AVAudioFormat(cmAudioFormatDescription: description)
        guard sourceFormat.sampleRate.isFinite, sourceFormat.sampleRate > 0,
              sourceFormat.channelCount > 0, sourceFormat.channelCount <= 8,
              sourceFormat.streamDescription.pointee.mFormatID == kAudioFormatLinearPCM else { return }
        let count = sample.numSamples
        guard count > 0, count <= 192_000,
              let sourcePCM = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(count)) else { return }
        sourcePCM.frameLength = AVAudioFrameCount(count)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(count),
                                                         into: sourcePCM.mutableAudioBufferList) == noErr else {
            throw CaptureFailure.message("无法读取录屏声音数据。")
        }
        let converter: AVAudioConverter
        if let existing = converters[source], existing.inputFormat == sourceFormat { converter = existing }
        else {
            guard let created = AVAudioConverter(from: sourceFormat, to: format) else {
                throw CaptureFailure.message("当前音频设备的格式无法录制。")
            }
            created.primeMethod = .none; converters[source] = created; converter = created
        }
        let capacity = ceil(Double(count) * 48_000 / sourceFormat.sampleRate) + 256
        guard capacity.isFinite, capacity <= 96_000,
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(capacity)) else { return }
        var supplied = false, error: NSError?
        let result = converter.convert(to: pcm, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true; status.pointee = .haveData; return sourcePCM
        }
        guard result != .error else { throw error ?? CaptureFailure.message("录屏声音转换失败。") }
        guard pcm.frameLength > 0 else { return }
        let offset = CMTimeSubtract(hostTime, anchor).seconds * 48_000
        guard offset.isFinite, abs(offset) < Double(Int64.max) / 2 else { return }
        mixer.add(pcm, at: Int64(offset.rounded()), source: source)
        receivedSources.insert(source)
    }

    /// Called only during an active recording. Real-time pressure drops one
    /// bounded block instead of queuing audio indefinitely.
    @discardableResult
    func flush(through elapsed: TimeInterval, final: Bool = false) throws -> Bool {
        guard let anchor, elapsed.isFinite, elapsed > 0, elapsed < Double(Int64.max) / 48_000 else { return true }
        let end = Int64((elapsed * 48_000).rounded(.down))
        let chunk: Int64 = 4_800
        while mixer.cursor < end {
            let count = Int(min(chunk, end - mixer.cursor))
            if !final && count < Int(chunk) { return true }
            if final && !input.isReadyForMoreMediaData { return false }
            let start = mixer.cursor
            let pcm = mixer.take(count)
            guard input.isReadyForMoreMediaData else { droppedBlocks += 1; continue }
            let pts = CMTimeAdd(anchor, CMTime(value: start, timescale: 48_000))
            let sample = try Self.sample(pcm, at: pts)
            guard input.append(sample) else { throw CaptureFailure.message("录屏声音写入失败。") }
        }
        return true
    }

    static func sample(_ pcm: AVAudioPCMBuffer, at time: CMTime) throws -> CMSampleBuffer {
        var description: CMAudioFormatDescription?
        var asbd = pcm.format.streamDescription.pointee
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil,
            formatDescriptionOut: &description) == noErr, let description else { throw CaptureFailure.unavailable }
        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(pcm.format.sampleRate)),
                                      presentationTimeStamp: time, decodeTimeStamp: .invalid)
        guard CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: true,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: description,
            sampleCount: Int(pcm.frameLength), sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample) == noErr,
              let sample,
              CMSampleBufferSetDataBufferFromAudioBufferList(sample, blockBufferAllocator: kCFAllocatorDefault,
                blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0,
                bufferList: pcm.audioBufferList) == noErr else { throw CaptureFailure.unavailable }
        return sample
    }
}
