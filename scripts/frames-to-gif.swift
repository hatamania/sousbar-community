// Turns a folder of numbered PNG frames into an animated GIF, using each frame's
// capture time for its delay. No ffmpeg or gifski needed: ImageIO ships with macOS.
//
//   swift scripts/frames-to-gif.swift <frames-dir> <out.gif> [scale]
//
// Frames are named <milliseconds>.png (see scripts/record-touchbar.sh).
// scale (default 1) shrinks the frames, e.g. 0.5 for a half-size GIF.
import AppKit
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("usage: frames-to-gif.swift <frames-dir> <out.gif> [scale]")
    exit(1)
}
let dir = URL(fileURLWithPath: args[1])
let out = URL(fileURLWithPath: args[2])
let scale = args.count > 3 ? Double(args[3]) ?? 1 : 1

let frames = (try FileManager.default.contentsOfDirectory(atPath: dir.path))
    .filter { $0.hasSuffix(".png") }
    .compactMap { name -> (Int, URL)? in
        guard let ms = Int(name.dropLast(4)) else { return nil }
        return (ms, dir.appendingPathComponent(name))
    }
    .sorted { $0.0 < $1.0 }
guard frames.count > 1 else {
    print("Need at least 2 frames in \(dir.path)")
    exit(1)
}

guard let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.gif.identifier as CFString, frames.count, nil) else {
    print("Couldn't create \(out.path)")
    exit(1)
}
CGImageDestinationSetProperties(dest, [
    kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
] as CFDictionary)

func load(_ url: URL) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
    guard scale != 1 else { return image }
    let w = Int(Double(image.width) * scale), h = Int(Double(image.height) * scale)
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    return ctx.makeImage() ?? image
}

for (i, frame) in frames.enumerated() {
    guard let image = load(frame.1) else { continue }
    // Each frame lasts until the next was captured; the last one holds for 1.5 s before looping.
    let delay = i + 1 < frames.count ? Double(frames[i + 1].0 - frame.0) / 1000 : 1.5
    CGImageDestinationAddImage(dest, image, [
        kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: max(delay, 0.02)],
    ] as CFDictionary)
}
guard CGImageDestinationFinalize(dest) else {
    print("Couldn't write \(out.path)")
    exit(1)
}
print("Wrote \(out.path) (\(frames.count) frames)")
