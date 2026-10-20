// Rasterize the unchanged website logo. Run `swift tool/create_icons.swift`
// from the project root on macOS; no website checkout or network is required.
import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let source = root.appendingPathComponent("assets/brand/huarun-icon.svg")
guard let logo = NSImage(contentsOf: source) else {
    fatalError("Cannot load website logo: \(source.path)")
}

func png(size: Int, macOS: Bool = false, opaque: Bool = false) -> Data {
    let pixels = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8,
        bytesPerRow: size * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: (opaque ? CGImageAlphaInfo.noneSkipLast : .premultipliedLast).rawValue
    )!
    let context = NSGraphicsContext(cgContext: pixels, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    let canvas = NSRect(x: 0, y: 0, width: size, height: size)
    context.cgContext.clear(canvas)
    if opaque {
        // iOS applies its own icon mask and requires an opaque square asset.
        NSColor(srgbRed: 0, green: 113.0 / 255, blue: 227.0 / 255, alpha: 1).setFill()
        canvas.fill()
    }
    // Match macOS icon canvas margins while retaining the website's silhouette.
    let inset = macOS ? CGFloat(size) * 100 / 1024 : 0
    logo.draw(in: canvas.insetBy(dx: inset, dy: inset))
    NSGraphicsContext.restoreGraphicsState()
    return NSBitmapImageRep(cgImage: pixels.makeImage()!)
        .representation(using: .png, properties: [:])!
}

for platform in ["macos", "ios"] {
    let directory = root.appendingPathComponent("\(platform)/Runner/Assets.xcassets/AppIcon.appiconset")
    let data = try Data(contentsOf: directory.appendingPathComponent("Contents.json"))
    let content = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    for item in content["images"] as! [[String: String]] {
        guard let name = item["filename"], let dimensions = item["size"],
              let scale = item["scale"] else { continue }
        let size = Int(Double(dimensions.split(separator: "x")[0])! * Double(scale.dropLast())!)
        try png(size: size, macOS: platform == "macos", opaque: platform == "ios")
            .write(to: directory.appendingPathComponent(name))
    }
}

for (density, size) in [("mdpi", 48), ("hdpi", 72), ("xhdpi", 96), ("xxhdpi", 144), ("xxxhdpi", 192)] {
    try png(size: size).write(to: root.appendingPathComponent(
        "android/app/src/main/res/mipmap-\(density)/ic_launcher.png"
    ))
}

// Windows ICO directory containing PNG frames for each standard display size.
func littleEndian<T: FixedWidthInteger>(_ value: T) -> Data {
    var bytes = value.littleEndian
    return withUnsafeBytes(of: &bytes) { Data($0) }
}
let sizes = [16, 24, 32, 48, 64, 128, 256]
let frames = sizes.map { png(size: $0) }
var ico = Data()
ico.append(littleEndian(UInt16(0)))
ico.append(littleEndian(UInt16(1)))
ico.append(littleEndian(UInt16(sizes.count)))
var offset = 6 + 16 * sizes.count
for (index, size) in sizes.enumerated() {
    let dimension = UInt8(size == 256 ? 0 : size)
    ico.append(contentsOf: [dimension, dimension, 0, 0])
    ico.append(littleEndian(UInt16(1)))
    ico.append(littleEndian(UInt16(32)))
    ico.append(littleEndian(UInt32(frames[index].count)))
    ico.append(littleEndian(UInt32(offset)))
    offset += frames[index].count
}
for frame in frames { ico.append(frame) }
try ico.write(to: root.appendingPathComponent("windows/runner/resources/app_icon.ico"))

// Embedded sidebar branding uses the same source, without system-icon margins.
try png(size: 256).write(to: root.appendingPathComponent("assets/brand/huarun-icon.png"))
print("Generated macOS, iOS, Android, Windows and in-app icons from the website logo.")
