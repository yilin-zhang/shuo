#!/usr/bin/env swift

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let projectURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let inputURL = projectURL.appendingPathComponent("Resources/ShuoIcon.png")
let outputDirectory = projectURL.appendingPathComponent("Resources/AppIcon.icon/Assets")
let outputURL = outputDirectory.appendingPathComponent("ShuoGlyph.png")

guard
    let source = CGImageSourceCreateWithURL(inputURL as CFURL, nil),
    let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
else {
    fatalError("Could not read \(inputURL.path)")
}

let size = 1024
let colorSpace = CGColorSpaceCreateDeviceRGB()
let bytesPerRow = size * 4
var pixels = [UInt8](repeating: 0, count: size * bytesPerRow)

guard let context = CGContext(
    data: &pixels,
    width: size,
    height: size,
    bitsPerComponent: 8,
    bytesPerRow: bytesPerRow,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    fatalError("Could not create bitmap context")
}

context.interpolationQuality = .high
context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))

for offset in stride(from: 0, to: pixels.count, by: 4) {
    let red = Double(pixels[offset])
    let green = Double(pixels[offset + 1])
    let blue = Double(pixels[offset + 2])
    let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
    let alpha = UInt8(clamping: Int(((250 - luminance) / 250 * 255).rounded()))

    pixels[offset] = 0
    pixels[offset + 1] = 0
    pixels[offset + 2] = 0
    pixels[offset + 3] = alpha
}

guard let outputImage = context.makeImage() else {
    fatalError("Could not create output image")
}

try FileManager.default.createDirectory(
    at: outputDirectory,
    withIntermediateDirectories: true
)

guard
    let destination = CGImageDestinationCreateWithURL(
        outputURL as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    )
else {
    fatalError("Could not create PNG destination")
}

CGImageDestinationAddImage(destination, outputImage, nil)
guard CGImageDestinationFinalize(destination) else {
    fatalError("Could not write \(outputURL.path)")
}

print(outputURL.path)
