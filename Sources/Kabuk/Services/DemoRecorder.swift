import AppKit
import AVFoundation
import ScreenCaptureKit

/// Records the part of the screen under Kabuk's window to an .mp4, glass and all, for the
/// demo video. Only the demo mode uses it, so the Screen Recording permission it needs is
/// asked of the demo copy alone.
final class DemoRecorder: NSObject, SCStreamOutput, @unchecked Sendable {
    enum Failure: LocalizedError {
        case noDisplay, notRecording, writer(String)
        var errorDescription: String? {
            switch self {
            case .noDisplay: return "The window's display isn't available for capture."
            case .notRecording: return "Nothing is being recorded."
            case .writer(let message): return message
            }
        }
    }

    private let queue = DispatchQueue(label: "dev.kabuk.demo-recorder")
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var sessionStarted = false

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }
    static func requestPermission() { CGRequestScreenCaptureAccess() }

    @MainActor
    func start(window: NSWindow, to url: URL) async throws {
        guard let screen = window.screen,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            throw Failure.noDisplay
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == number.uint32Value }) else {
            throw Failure.noDisplay
        }
        // Display coordinates start at the top left; the window's frame at the bottom left.
        let frame = window.frame
        let region = CGRect(x: frame.minX - screen.frame.minX, y: screen.frame.maxY - frame.maxY,
                            width: frame.width, height: frame.height)
        let scale = screen.backingScaleFactor
        let width = Int(region.width * scale) & ~1, height = Int(region.height * scale) & ~1

        let config = SCStreamConfiguration()
        config.sourceRect = region
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false
        config.queueDepth = 6

        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 24_000_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ])
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw Failure.writer("Can't write H.264 video.") }
        writer.add(input)
        guard writer.startWriting() else { throw Failure.writer(writer.error?.localizedDescription ?? "Can't start writing.") }

        let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: config, delegate: nil)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        queue.sync {
            self.writer = writer
            self.input = input
            self.sessionStarted = false
        }
        try await stream.startCapture()
        self.stream = stream
    }

    @MainActor
    func stop() async throws {
        guard let stream else { throw Failure.notRecording }
        try await stream.stopCapture()
        self.stream = nil
        let (writer, input) = queue.sync { (self.writer, self.input) }
        guard let writer, let input else { throw Failure.notRecording }
        input.markAsFinished()
        await writer.finishWriting()
        if let error = writer.error { throw Failure.writer(error.localizedDescription) }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, buffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let writer, let input else { return }
        if !sessionStarted {
            writer.startSession(atSourceTime: buffer.presentationTimeStamp)
            sessionStarted = true
        }
        if input.isReadyForMoreMediaData { input.append(buffer) }
    }
}
