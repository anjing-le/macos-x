import Foundation
import CoreGraphics
import Vision

enum CaptureTextRecognition {
    static func request() -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.automaticallyDetectsLanguage = true
        request.usesLanguageCorrection = true
        if let supported = try? request.supportedRecognitionLanguages() {
            request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"].filter(supported.contains)
        }
        return request
    }
    /// On-demand, local recognition of the selected pixels; no downloaded model,
    /// disk cache or idle task. Caller owns request cancellation and stale results.
    static func recognize(_ image: CGImage, request: VNRecognizeTextRequest) throws -> String {
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).prefix(2000).compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }
}
