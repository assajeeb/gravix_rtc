// Client side of the Unix domain socket the app opens at
// <app group container>/rtc_SSFD (flutter_webrtc's FlutterSocketConnection).

import Foundation

final class SocketConnection: NSObject, StreamDelegate {
    var didClose: ((Error?) -> Void)?
    var didOpen: (() -> Void)?
    var streamHasSpaceAvailable: (() -> Void)?

    private let filePath: String
    private var socketHandle: Int32 = -1
    private var inputStream: InputStream?
    private var outputStream: OutputStream?
    private var networkQueue: DispatchQueue?
    private var shouldKeepRunning = false

    init?(filePath path: String) {
        filePath = path
        super.init()
        guard !path.isEmpty, path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else { return nil }
    }

    /// Connects to the app. Returns false while the app is not listening yet.
    func open() -> Bool {
        if outputStream != nil { return true }
        let handle = socket(AF_UNIX, SOCK_STREAM, 0)
        guard handle != -1 else { return false }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            filePath.withCString { strncpy(UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self), $0, MemoryLayout.size(ofValue: address.sun_path) - 1) }
        }
        let status = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(handle, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard status == 0 else {
            Darwin.close(handle)
            return false
        }
        socketHandle = handle

        var readStream: Unmanaged<CFReadStream>?
        var writeStream: Unmanaged<CFWriteStream>?
        CFStreamCreatePairWithSocket(kCFAllocatorDefault, handle, &readStream, &writeStream)
        inputStream = readStream?.takeRetainedValue()
        outputStream = writeStream?.takeRetainedValue()
        guard let inputStream, let outputStream else {
            close()
            return false
        }
        for stream in [inputStream as Stream, outputStream as Stream] {
            stream.delegate = self
            stream.setProperty(kCFBooleanTrue, forKey: Stream.PropertyKey(kCFStreamPropertyShouldCloseNativeSocket as String))
        }

        networkQueue = DispatchQueue(label: "gravix.broadcast.socket")
        shouldKeepRunning = true
        networkQueue?.async { [weak self] in
            guard let self else { return }
            inputStream.schedule(in: .current, forMode: .common)
            outputStream.schedule(in: .current, forMode: .common)
            inputStream.open()
            outputStream.open()
            while self.shouldKeepRunning, RunLoop.current.run(mode: .default, before: .distantFuture) {}
        }
        return true
    }

    func close() {
        shouldKeepRunning = false
        for stream in [inputStream as Stream?, outputStream as Stream?].compactMap({ $0 }) {
            stream.delegate = nil
            stream.close()
        }
        inputStream = nil
        outputStream = nil
        if socketHandle != -1 {
            socketHandle = -1 // closed by the streams (ShouldCloseNativeSocket)
        }
    }

    func writeToStream(buffer: UnsafePointer<UInt8>, maxLength length: Int) -> Int {
        outputStream?.write(buffer, maxLength: length) ?? -1
    }

    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        switch eventCode {
        case .openCompleted:
            if aStream == outputStream { didOpen?() }
        case .hasSpaceAvailable:
            if aStream == outputStream { streamHasSpaceAvailable?() }
        case .errorOccurred:
            let error = aStream.streamError
            close()
            DispatchQueue.main.async { self.didClose?(error) }
        case .endEncountered:
            close()
            DispatchQueue.main.async { self.didClose?(nil) }
        default:
            break
        }
    }
}
