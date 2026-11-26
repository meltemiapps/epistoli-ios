// contrast_check.swift: worst-case contrast of white text in app screenshots.
//
// Usage: swift scripts/contrast_check.swift [--min 4.5] <screenshot.png> ...
//
// Text on glass can't be checked from colour values alone: the glass blurs and tints whatever
// background is behind it. This measures the rendered result instead. The image is cut into
// 18 px tiles; a tile with white text in it (enough near-white pixels) gets a background
// estimate, the median luminance of its other pixels, and the WCAG ratio of white against that.
// Pure white surfaces (the QR tile) are skipped. Dark text on solid fills (the badges) is
// covered by AppTests/ThemeTests instead. Exit code 1 if any screenshot is below the minimum.
//
// --skip <file-substring>:<x>,<y>,<w>,<h> leaves out a pixel rectangle in matching files, for
// white that isn't text. Every skip must say why where it is used (scripts/design_screenshots.sh).
import CoreGraphics
import Foundation
import ImageIO

func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }

var args = Array(CommandLine.arguments.dropFirst())
var minimum = 4.5
if let i = args.firstIndex(of: "--min"), i + 1 < args.count {
    minimum = Double(args[i + 1]) ?? 4.5
    args.removeSubrange(i...(i + 1))
}
var skips: [(file: String, rect: (Int, Int, Int, Int))] = []
while let i = args.firstIndex(of: "--skip"), i + 1 < args.count {
    let spec = args[i + 1].split(separator: ":", maxSplits: 1)
    let n = spec.count == 2 ? spec[1].split(separator: ",").compactMap { Int($0) } : []
    guard n.count == 4 else { print("contrast_check: bad --skip \(args[i + 1])"); exit(2) }
    skips.append((String(spec[0]), (n[0], n[1], n[2], n[3])))
    args.removeSubrange(i...(i + 1))
}
guard !args.isEmpty else {
    print("usage: swift scripts/contrast_check.swift [--min 4.5] <screenshot.png> ...")
    exit(2)
}

var failed = false
for path in args {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        print("contrast_check: can't read \(path)"); failed = true; continue
    }
    let w = image.width, h = image.height
    var pixels = [UInt8](repeating: 0, count: w * h * 4)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    pixels.withUnsafeMutableBytes { buffer in
        let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
    func lum(_ i: Int) -> Double {
        0.2126 * linear(Double(pixels[i]) / 255) + 0.7152 * linear(Double(pixels[i + 1]) / 255) + 0.0722 * linear(Double(pixels[i + 2]) / 255)
    }
    func nearWhite(_ i: Int) -> Bool {
        let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
        return min(r, g, b) >= 235 && max(r, g, b) - min(r, g, b) <= 12
    }

    let tile = 18
    let name = URL(fileURLWithPath: path).lastPathComponent
    let skipped = skips.filter { name.contains($0.file) }.map(\.rect)
    func isSkipped(_ x: Int, _ y: Int) -> Bool {
        skipped.contains { x + tile > $0.0 && x < $0.0 + $0.2 && y + tile > $0.1 && y < $0.1 + $0.3 }
    }
    let top = Int(Double(h) * 0.065)          // skip the system status bar
    let bottom = h - Int(Double(h) * 0.03)    // and the home indicator
    var worst = (ratio: 99.0, x: 0, y: 0)
    var tiles = 0
    var y = top
    while y + tile <= bottom {
        var x = 0
        while x + tile <= w {
            if isSkipped(x, y) { x += tile; continue }
            var white = 0
            var others: [Double] = []
            others.reserveCapacity(tile * tile)
            for ty in y..<(y + tile) {
                for tx in x..<(x + tile) {
                    let i = (ty * w + tx) * 4
                    if nearWhite(i) { white += 1 } else { others.append(lum(i)) }
                }
            }
            let n = tile * tile
            if white >= n / 25 && others.count >= n / 3 {
                others.sort()
                let background = others[others.count / 2]
                if background < 0.8 {
                    tiles += 1
                    let ratio = 1.05 / (background + 0.05)
                    if ratio < worst.ratio { worst = (ratio, x, y) }
                }
            }
            x += tile
        }
        y += tile
    }
    let ok = worst.ratio >= minimum
    if !ok { failed = true }
    print(String(format: "%@ %@  worst %.2f:1 at (%d,%d) over %d text tiles", ok ? "PASS" : "FAIL", name, worst.ratio, worst.x, worst.y, tiles))
}
exit(failed ? 1 : 0)
