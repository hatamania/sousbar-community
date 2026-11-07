// Keeps only some time ranges of a GIF, joined end to end, with the original frame timing.
//
//   swift scripts/trim-gif.swift <in.gif> <out.gif> <from-to> [<from-to> …]
//
// Times are in seconds, e.g. `4.2-26` or, to cut a dull middle out, `2.3-4 11.8-14.4`.
// The last kept frame holds for 1.5 s before the GIF loops.
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count >= 4 else {
    print("usage: trim-gif.swift <in.gif> <out.gif> <from-to> [<from-to> …]")
    exit(1)
}
let ranges: [(Double, Double)] = args[3...].compactMap {
    let p = $0.split(separator: "-").compactMap { Double($0) }
    return p.count == 2 ? (p[0], p[1]) : nil
}
guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil) else {
    print("Couldn't read \(args[1])")
    exit(1)
}

var kept: [(index: Int, delay: Double)] = []
var t = 0.0
for i in 0..<CGImageSourceGetCount(src) {
    let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any]
    let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
    let delay = gif?[kCGImagePropertyGIFDelayTime] as? Double ?? 0.1
    if ranges.contains(where: { t >= $0.0 && t < $0.1 }) { kept.append((i, delay)) }
    t += delay
}
guard !kept.isEmpty else {
    print("No frames in those ranges (the GIF is \(String(format: "%.1f", t)) s long)")
    exit(1)
}

// Write to a temporary file first, so the input can also be the output.
let tmp = URL(fileURLWithPath: args[2] + ".tmp")
guard let dest = CGImageDestinationCreateWithURL(tmp as CFURL, UTType.gif.identifier as CFString, kept.count, nil) else { exit(1) }
CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
for (n, frame) in kept.enumerated() {
    guard let image = CGImageSourceCreateImageAtIndex(src, frame.index, nil) else { continue }
    let delay = n == kept.count - 1 ? 1.5 : frame.delay
    CGImageDestinationAddImage(dest, image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary)
}
guard CGImageDestinationFinalize(dest) else { exit(1) }
_ = try? FileManager.default.removeItem(atPath: args[2])
try FileManager.default.moveItem(at: tmp, to: URL(fileURLWithPath: args[2]))
print("Wrote \(args[2]) (\(kept.count) frames)")
