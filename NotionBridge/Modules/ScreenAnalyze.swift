// ScreenAnalyze.swift – V3-SCREEN-002 Screen Color Analysis Tool
// NotionBridge · Modules
//
// Extends ScreenModule with screen_analyze: dominant color extraction
// from screenshot files using CoreGraphics pixel sampling.
// Input: file path to an existing screenshot (from screen_capture).
// Output: dominant colors (hex + percentage), average luminance, pixel dimensions.
// Classified as Open tier (read-only, zero side effects).
//
// Algorithm: Downsampled pixel read → 5-bit RGB quantization → frequency sort → top-N colors.
// No external framework dependencies beyond CoreGraphics + ImageIO (already linked).

import Foundation
import MCP
import CoreGraphics
import ImageIO

extension ScreenModule {

    /// Register the screen_analyze tool on the given router.
    public static func registerAnalyze(on router: ToolRouter) async {

        await router.register(ToolRegistration(
            name: "screen_analyze",
            module: moduleName,
            tier: .open,
            description: "Analyze a screenshot file for dominant colors and luminance. Input: filePath from screen_capture.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "filePath": .object([
                        "type": .string("string"),
                        "description": .string("Absolute path to a PNG or JPEG screenshot file (e.g. from screen_capture output)")
                    ]),
                    "topN": .object([
                        "type": .string("integer"),
                        "description": .string("Number of dominant colors to return (default: 8, max: 20)")
                    ]),
                    "sampleStride": .object([
                        "type": .string("integer"),
                        "description": .string("Pixel sampling stride — higher = faster but less accurate (default: 4, range: 1-16)")
                    ])
                ]),
                "required": .array([.string("filePath")])
            ]),
            handler: { arguments in
                let args: [String: Value] = {
                    if case .object(let a) = arguments { return a }
                    return [:]
                }()

                guard case .string(let filePath) = args["filePath"] else {
                    return .object([
                        "error": .string("invalid_parameters"),
                        "message": .string("filePath (string) is required")
                    ])
                }

                let topN: Int = {
                    if case .int(let n) = args["topN"] { return min(max(n, 1), 20) }
                    return 8
                }()

                let sampleStride: Int = {
                    if case .int(let s) = args["sampleStride"] { return min(max(s, 1), 16) }
                    return 4
                }()

                // Load image from file via ImageIO
                let url = URL(fileURLWithPath: filePath) as CFURL
                guard let imageSource = CGImageSourceCreateWithURL(url, nil),
                      let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
                    return .object([
                        "error": .string("file_load_failed"),
                        "message": .string("Could not load image from \(filePath). Ensure the file exists and is a valid PNG or JPEG.")
                    ])
                }

                let width = cgImage.width
                let height = cgImage.height

                // Draw into a normalized RGBA context to get predictable pixel format
                let bytesPerPixel = 4
                let bytesPerRow = width * bytesPerPixel
                var pixelData = [UInt8](repeating: 0, count: height * bytesPerRow)

                guard let context = CGContext(
                    data: &pixelData,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ) else {
                    return .object([
                        "error": .string("context_failed"),
                        "message": .string("Failed to create CGContext for pixel analysis")
                    ])
                }

                context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

                // Sample pixels with stride and quantize to 5-bit per channel (32 levels)
                var colorCounts: [Int: Int] = [:]
                var totalLuminance: Double = 0
                var sampleCount = 0

                for y in Swift.stride(from: 0, to: height, by: sampleStride) {
                    for x in Swift.stride(from: 0, to: width, by: sampleStride) {
                        let offset = (y * bytesPerRow) + (x * bytesPerPixel)
                        let r = pixelData[offset]
                        let g = pixelData[offset + 1]
                        let b = pixelData[offset + 2]

                        // Quantize to 5-bit per channel (32^3 = 32768 possible buckets)
                        let qr = Int(r) >> 3
                        let qg = Int(g) >> 3
                        let qb = Int(b) >> 3
                        let key = (qr << 10) | (qg << 5) | qb

                        colorCounts[key, default: 0] += 1

                        // Relative luminance (ITU-R BT.709)
                        totalLuminance += 0.2126 * Double(r) / 255.0
                            + 0.7152 * Double(g) / 255.0
                            + 0.0722 * Double(b) / 255.0

                        sampleCount += 1
                    }
                }

                guard sampleCount > 0 else {
                    return .object([
                        "error": .string("empty_image"),
                        "message": .string("Image produced no pixels to analyze")
                    ])
                }

                // Sort by frequency, take top N
                let sorted = colorCounts.sorted { $0.value > $1.value }
                let topColors = sorted.prefix(topN)

                let colorResults: [Value] = topColors.map { (key, count) in
                    // Dequantize: spread 5-bit back to 8-bit
                    let qr = (key >> 10) & 0x1F
                    let qg = (key >> 5) & 0x1F
                    let qb = key & 0x1F
                    let r = (qr << 3) | (qr >> 2)
                    let g = (qg << 3) | (qg >> 2)
                    let b = (qb << 3) | (qb >> 2)
                    let hex = String(format: "#%02x%02x%02x", r, g, b)
                    let pct = Double(count) / Double(sampleCount) * 100.0
                    let roundedPct = (pct * 10).rounded() / 10

                    return .object([
                        "hex": .string(hex),
                        "percentage": .double(roundedPct),
                        "rgb": .object([
                            "r": .int(r),
                            "g": .int(g),
                            "b": .int(b)
                        ])
                    ])
                }

                let avgLuminance = totalLuminance / Double(sampleCount)
                let roundedLum = (avgLuminance * 1000).rounded() / 1000
                let theme: String = avgLuminance < 0.5 ? "dark" : "light"

                return .object([
                    "dominantColors": .array(colorResults),
                    "averageLuminance": .double(roundedLum),
                    "theme": .string(theme),
                    "width": .int(width),
                    "height": .int(height),
                    "sampledPixels": .int(sampleCount),
                    "sampleStride": .int(sampleStride)
                ])
            }
        ))
    }
}
