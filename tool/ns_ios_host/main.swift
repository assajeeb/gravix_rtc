// Copyright (c) 2024-2026 Gravity Compile. MIT License; see LICENSE.
// macOS host check of the iOS studio path (GxNsDfn3CoreML, GxNsStudioPack, GxNsZip,
// GxNsBenchmark). Run: tool/ns_ios_host/run.sh <dfn3 release dir> <out dir>.
// NOTE: writes the LL cache to ~/Library/Application Support/gravix_ns (delete after).
import CoreML
setvbuf(stdout, nil, _IONBF, 0)
import Foundation

let args = CommandLine.arguments
let wav = URL(fileURLWithPath: args[1]), stdModelc = URL(fileURLWithPath: args[2])
let stdZip = URL(fileURLWithPath: args[3]), llZip = URL(fileURLWithPath: args[4]), outDir = URL(fileURLWithPath: args[5])

func readWav16(_ u: URL) -> [Float] {
    let d = try! Data(contentsOf: u)
    var p = 12
    while p + 8 < d.count {
        let id = String(data: d[p..<p+4], encoding: .ascii)!
        let sz = Int(d[p+4]) | Int(d[p+5])<<8 | Int(d[p+6])<<16 | Int(d[p+7])<<24
        if id == "data" {
            var out = [Float](); out.reserveCapacity(sz/2)
            var i = p + 8
            while i + 1 < p + 8 + sz { out.append(Float(Int16(bitPattern: UInt16(d[i]) | UInt16(d[i+1])<<8)) / 32768); i += 2 }
            return out
        }
        p += 8 + sz
    }
    fatalError("no data")
}
func run(_ e: GxNsStudioEngine, _ x: [Float], name: String) {
    var out = [Float](repeating: 0, count: x.count - x.count % 480)
    var times = [Double]()
    for f in stride(from: 0, to: out.count, by: 480) {
        let t0 = DispatchTime.now().uptimeNanoseconds
        let rc = x.withUnsafeBufferPointer { i in out.withUnsafeMutableBufferPointer { o in e.process(o.baseAddress! + f, i.baseAddress! + f, 480) } }
        times.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1000)
        precondition(rc == 0, "process rc=\(rc)")
    }
    let s = times.dropFirst(20).sorted()
    print("\(name): frames=\(times.count) p50=\(Int(s[s.count/2]))us p95=\(Int(s[Int(Double(s.count)*0.95)]))us max=\(Int(s.last!))us")
    try! out.withUnsafeBufferPointer { Data(buffer: $0) }.write(to: outDir.appendingPathComponent("\(name).f32"))
}
let x = readWav16(wav)
// 1. zip + sha on the std zip
let stdSpec = GxNsStudioPack.Spec(id: "std", sha256: GxNsStudioEngines.bundledModelSha256, bytes: 2_276_531, latencySamples: 1440)
try! GxNsStudioPack.verify(stdZip, stdSpec); print("std zip sha ok")
do { try GxNsStudioPack.verify(stdZip, GxNsStudioPack.ll); print("FAIL: wrong spec accepted") } catch { print("wrong spec rejected: \(error.localizedDescription)") }
let un = outDir.appendingPathComponent("unz"); try? FileManager.default.removeItem(at: un)
try! GxNsZip.extract(stdZip, to: un)
print("unzipped:", try! FileManager.default.contentsOfDirectory(atPath: un.path))
// 2. bundled (repo) compiled model
let e = try! GxNsDfn3CoreML(compiledModel: stdModelc, name: "std", modelSha256: "", latencySamples: 1440)
run(e, x, name: "std_swift")
let b = GxNsBenchmark.run(e); print("benchmark std: p95=\(b.p95Us)us max=\(b.maxUs)us ok=\(b.outputOk)")
e.reset(); run(e, x, name: "std_swift_after_reset")
// 3. LL via the full pack path (file:// source)
let ll = try! GxNsStudioPack.ensure(GxNsStudioPack.ll, remote: llZip, policy: .any) { print($0) }
let ll2 = try! GxNsStudioPack.ensure(GxNsStudioPack.ll, remote: nil, policy: .never) { print($0) }
precondition(ll.standardizedFileURL.path == ll2.standardizedFileURL.path)
let le = try! GxNsDfn3CoreML(compiledModel: ll, name: "ll", modelSha256: GxNsStudioPack.ll.sha256, latencySamples: 480)
run(le, x, name: "ll_swift")
print("cache:", ll.path)
