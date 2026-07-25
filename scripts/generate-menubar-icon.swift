import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

guard CommandLine.arguments.count == 3 else {
  fatalError("usage: generate-menubar-icon.swift INPUT OUTPUT")
}

let input = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
guard let source = CGImageSourceCreateWithURL(input as CFURL, nil),
  let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
else {
  fatalError("Unable to read \(input.path)")
}

let width = 44
let height = 44
let bytesPerRow = width * 4
var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)

guard
  pixels.withUnsafeMutableBytes({ buffer in
    guard
      let context = CGContext(
        data: buffer.baseAddress,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    else { return false }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return true
  })
else {
  fatalError("Unable to create bitmap")
}

for offset in stride(from: 0, to: pixels.count, by: 4) {
  let luminance = (Int(pixels[offset]) + Int(pixels[offset + 1]) + Int(pixels[offset + 2])) / 3
  let alpha = luminance >= 245 ? 0 : min(255, (245 - luminance) * 255 / 245)
  pixels[offset] = 0
  pixels[offset + 1] = 0
  pixels[offset + 2] = 0
  pixels[offset + 3] = UInt8(alpha)
}

// Menu-bar artwork is the central mark only. Ignore the outer safe area so
// borders or presentation artifacts in an app-icon master cannot leak in.
let safeAreaInset = 5
for y in 0..<height {
  for x in 0..<width {
    if x < safeAreaInset || x >= width - safeAreaInset
      || y < safeAreaInset || y >= height - safeAreaInset
    {
      pixels[y * bytesPerRow + x * 4 + 3] = 0
    }
  }
}

guard
  let rendered = pixels.withUnsafeMutableBytes({ buffer -> CGImage? in
    let context = CGContext(
      data: buffer.baseAddress,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: bytesPerRow,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )
    return context?.makeImage()
  }),
  let destination = CGImageDestinationCreateWithURL(
    output as CFURL,
    UTType.png.identifier as CFString,
    1,
    nil
  )
else {
  fatalError("Unable to create output image")
}

CGImageDestinationAddImage(destination, rendered, nil)
guard CGImageDestinationFinalize(destination) else {
  fatalError("Unable to write \(output.path)")
}

let cornerAlphas = [
  pixels[3],
  pixels[(width - 1) * 4 + 3],
  pixels[(height - 1) * bytesPerRow + 3],
  pixels[pixels.count - 1],
]
let maximumAlpha = stride(from: 3, to: pixels.count, by: 4).map { pixels[$0] }.max() ?? 0
guard cornerAlphas.allSatisfy({ $0 == 0 }), maximumAlpha > 200 else {
  fatalError("Invalid template alpha: corners=\(cornerAlphas), max=\(maximumAlpha)")
}
print("Verified transparent template: corners=\(cornerAlphas), max=\(maximumAlpha)")
