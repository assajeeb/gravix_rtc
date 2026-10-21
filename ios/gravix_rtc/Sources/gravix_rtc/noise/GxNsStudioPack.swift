// Copyright (c) 2024-2026 Gravity Compile. MIT License; see LICENSE.

import Compression
import CryptoKit
import Foundation
#if canImport(CoreML)
import CoreML
#endif

/// Downloadable studio pack (DFN3 low-latency, Core ML) — plan §3 Phase 3 item 16.
///
/// The URL is configuration (`studioLlUrl`); the SHA-256 and size are compiled
/// into the SDK (release manifest `download/ll/manifest.json`), so a CDN or
/// app-provided file can only ever deliver this exact model. Flow:
/// download -> verify size + SHA-256 -> unzip (.mlpackage) -> MLModel.compileModel
/// -> cache `<Application Support>/gravix_ns/<sha>/model.mlmodelc`; the next
/// run uses the cache without network.
enum GxNsStudioPack {
    struct Spec {
        let id: String
        let sha256: String
        let bytes: Int
        let latencySamples: Int32
    }

    /// dfn3_ll_int8.mlpackage.zip, release 0.1.0-spike (2026-10-21).
    static let ll = Spec(
        id: "dfn3-ll-coreml-int8",
        sha256: "293304adbdde9165585babb31407af7fda87e2c10677873f3f44de9d22342168",
        bytes: 9_044_104,
        latencySamples: 480
    )

    enum Download: String {
        case never, unmeteredIdle, any
    }

    static func cacheRoot() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        let dir = base.appendingPathComponent("gravix_ns", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var d = dir
        try? d.setResourceValues(values)
        return dir
    }

    /// Compiled model already in the cache?
    static func cachedModel(_ spec: Spec) -> URL? {
        guard let root = try? cacheRoot() else { return nil }
        let url = root.appendingPathComponent(spec.sha256, isDirectory: true).appendingPathComponent("model.mlmodelc")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Downloads (if allowed), verifies, unzips, compiles and caches. Blocking:
    /// call on a background queue. `remote` may be https:// or file://.
    @available(iOS 16.0, macOS 13.0, *)
    static func ensure(_ spec: Spec, remote: URL?, policy: Download,
                       log: (String) -> Void) throws -> URL {
        if let cached = cachedModel(spec) { log("pack src=cache sha=ok id=\(spec.id)"); return cached }
        guard policy != .never else { throw error("download_never") }
        guard let remote else { throw error("no_url") }
        let t0 = Date()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("gxns-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let zip = tmp.appendingPathComponent("pack.zip")
        try fetch(remote, to: zip, unmeteredOnly: policy == .unmeteredIdle)
        try verify(zip, spec)
        let unpacked = tmp.appendingPathComponent("unzipped", isDirectory: true)
        try GxNsZip.extract(zip, to: unpacked)
        guard let pkg = try FileManager.default.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "mlpackage" })
        else { throw error("no_mlpackage") }
        #if canImport(CoreML)
        let compiled = try MLModel.compileModel(at: pkg)
        #else
        throw error("no_coreml")
        #endif
        let dstDir = try cacheRoot().appendingPathComponent(spec.sha256, isDirectory: true)
        try? FileManager.default.removeItem(at: dstDir)
        try FileManager.default.createDirectory(at: dstDir, withIntermediateDirectories: true)
        let dst = dstDir.appendingPathComponent("model.mlmodelc")
        try FileManager.default.moveItem(at: compiled, to: dst)
        log("pack src=\(remote.isFileURL ? "file" : "cdn") sha=ok id=\(spec.id) bytes=\(spec.bytes) +\(Int(Date().timeIntervalSince(t0) * 1000))ms")
        return dst
    }

    static func verify(_ file: URL, _ spec: Spec) throws {
        let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? -1
        guard size == spec.bytes else { throw error("size_mismatch got=\(size)") }
        guard try sha256(file) == spec.sha256 else { throw error("sha_mismatch") }
    }

    static func sha256(_ file: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: file)
        defer { try? h.close() }
        var hasher = SHA256()
        while true {
            let chunk = h.readData(ofLength: 1 << 20)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func fetch(_ remote: URL, to dst: URL, unmeteredOnly: Bool) throws {
        if remote.isFileURL {
            try FileManager.default.copyItem(at: remote, to: dst)
            return
        }
        guard remote.scheme == "https" else { throw error("https_only") }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.allowsExpensiveNetworkAccess = !unmeteredOnly
        cfg.allowsConstrainedNetworkAccess = !unmeteredOnly
        cfg.timeoutIntervalForResource = 300
        let session = URLSession(configuration: cfg)
        defer { session.finishTasksAndInvalidate() }
        let done = DispatchSemaphore(value: 0)
        var failure: Error?
        session.downloadTask(with: remote) { tmp, resp, err in
            defer { done.signal() }
            if let err { failure = err; return }
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200, let tmp else {
                failure = GxNsStudioPack.error("http_\((resp as? HTTPURLResponse)?.statusCode ?? -1)"); return
            }
            do { try FileManager.default.moveItem(at: tmp, to: dst) } catch { failure = error }
        }.resume()
        done.wait()
        if let failure { throw failure }
    }

    static func error(_ msg: String) -> NSError {
        NSError(domain: "GravixNS.pack", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
    }
}

/// Minimal .zip reader (stored + deflate, no zip64/encryption) for the
/// studio pack; iOS has no public unzip API. Rejects absolute paths and "..".
enum GxNsZip {
    static func extract(_ zip: URL, to dir: URL) throws {
        let data = try Data(contentsOf: zip, options: .mappedIfSafe)
        func u16(_ o: Int) -> Int { Int(data[o]) | Int(data[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
        // End of central directory (last 22 + comment bytes).
        var eocd = -1
        var i = data.count - 22
        while i >= max(0, data.count - 22 - 65535) {
            if u32(i) == 0x0605_4B50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw GxNsStudioPack.error("zip_no_eocd") }
        let entries = u16(eocd + 10)
        var p = u32(eocd + 16)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for _ in 0 ..< entries {
            guard p + 46 <= data.count, u32(p) == 0x0201_4B50 else { throw GxNsStudioPack.error("zip_bad_cd") }
            let flags = u16(p + 8), method = u16(p + 10)
            let csize = u32(p + 20), usize = u32(p + 24)
            let nlen = u16(p + 28), xlen = u16(p + 30), clen = u16(p + 32)
            let local = u32(p + 42)
            guard let name = String(data: data[(p + 46) ..< (p + 46 + nlen)], encoding: .utf8) else {
                throw GxNsStudioPack.error("zip_bad_name")
            }
            p += 46 + nlen + xlen + clen
            guard flags & 1 == 0 else { throw GxNsStudioPack.error("zip_encrypted") }
            guard !name.hasPrefix("/"), !name.split(separator: "/").contains("..") else {
                throw GxNsStudioPack.error("zip_bad_path")
            }
            if name.hasPrefix("__MACOSX/") || name.split(separator: "/").last?.hasPrefix("._") == true { continue }
            let target = dir.appendingPathComponent(name)
            if name.hasSuffix("/") {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard u32(local) == 0x0403_4B50 else { throw GxNsStudioPack.error("zip_bad_local") }
            let start = local + 30 + u16(local + 26) + u16(local + 28)
            guard start + csize <= data.count else { throw GxNsStudioPack.error("zip_truncated") }
            let body = data[start ..< (start + csize)]
            let out: Data
            switch method {
            case 0:
                out = Data(body)
            case 8:
                out = try inflate(Data(body), size: usize)
            default:
                throw GxNsStudioPack.error("zip_method_\(method)")
            }
            guard out.count == usize else { throw GxNsStudioPack.error("zip_size") }
            try out.write(to: target)
        }
    }

    /// Raw DEFLATE (COMPRESSION_ZLIB is RFC 1951 without a header).
    private static func inflate(_ src: Data, size: Int) throws -> Data {
        if size == 0 { return Data() }
        var dst = Data(count: size)
        let n = dst.withUnsafeMutableBytes { d in
            src.withUnsafeBytes { s in
                compression_decode_buffer(d.bindMemory(to: UInt8.self).baseAddress!, size,
                                          s.bindMemory(to: UInt8.self).baseAddress!, src.count,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        guard n == size else { throw GxNsStudioPack.error("zip_inflate") }
        return dst
    }
}
