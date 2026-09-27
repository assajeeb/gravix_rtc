// Encodes ReplayKit video samples as JPEG and writes them to the app in the
// framing flutter_webrtc's FlutterSocketConnectionFrameReader parses.

import CoreImage
import Foundation
import ReplayKit

final class SampleUploader {
    private static let imageContext = CIContext(options: nil)
    // Downscale to keep the extension under its ~50 MB memory limit and the
    // socket ahead of the capture rate.
    private static let scale: CGFloat = 0.5
    private static let jpegQuality: CGFloat = 0.6

    private let connection: SocketConnection
    private let queue = DispatchQueue(label: "gravix.broadcast.uploader")
    private var isReady = false
    private var pending: Data?
    private var byteIndex = 0

    init(connection: SocketConnection) {
        self.connection = connection
        connection.didOpen = { [weak self] in self?.queue.async { self?.isReady = true } }
        connection.streamHasSpaceAvailable = { [weak self] in
            self?.queue.async {
                guard let self else { return }
                self.isReady = !self.writePending()
            }
        }
    }

    /// Drops the frame when the previous one is still being written.
    @discardableResult
    func send(sample buffer: CMSampleBuffer) -> Bool {
        guard let message = Self.frame(from: buffer) else { return false }
        var accepted = false
        queue.sync {
            guard isReady, pending == nil else { return }
            isReady = false
            pending = message
            byteIndex = 0
            isReady = !writePending()
            accepted = true
        }
        return accepted
    }

    /// Returns true while bytes are still outstanding.
    private func writePending() -> Bool {
        guard let data = pending else { return false }
        let written = data.withUnsafeBytes { raw -> Int in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return -1 }
            return connection.writeToStream(buffer: base.advanced(by: byteIndex), maxLength: data.count - byteIndex)
        }
        if written > 0 { byteIndex += written }
        if byteIndex >= data.count || written < 0 {
            pending = nil
            byteIndex = 0
            return false
        }
        return true
    }

    private static func frame(from buffer: CMSampleBuffer) -> Data? {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(imageBuffer)
        let height = CVPixelBufferGetHeight(imageBuffer)
        let image = CIImage(cvPixelBuffer: imageBuffer)
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let jpeg = imageContext.jpegRepresentation(
                  of: image, colorSpace: colorSpace,
                  options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: jpegQuality]
              )
        else { return nil }

        let orientation = (CMGetAttachment(buffer, key: RPVideoSampleOrientationKey as CFString, attachmentModeOut: nil) as? NSNumber)?.uint32Value ?? 1

        let message = CFHTTPMessageCreateResponse(kCFAllocatorDefault, 200, nil, kCFHTTPVersion1_1).takeRetainedValue()
        CFHTTPMessageSetHeaderFieldValue(message, "Content-Length" as CFString, String(jpeg.count) as CFString)
        CFHTTPMessageSetHeaderFieldValue(message, "Buffer-Width" as CFString, String(Int(CGFloat(width) * scale)) as CFString)
        CFHTTPMessageSetHeaderFieldValue(message, "Buffer-Height" as CFString, String(Int(CGFloat(height) * scale)) as CFString)
        CFHTTPMessageSetHeaderFieldValue(message, "Buffer-Orientation" as CFString, String(orientation) as CFString)
        CFHTTPMessageSetBody(message, jpeg as CFData)
        return CFHTTPMessageCopySerializedMessage(message)?.takeRetainedValue() as Data?
    }
}
