import AppKit
import Foundation
import ImageIO

enum RenderError: Error, CustomStringConvertible {
    case usage
    case invalidSize(String)
    case cannotLoadSVG(String)
    case cannotCreateBitmap
    case cannotCreateGraphicsContext
    case cannotCreateCGImage
    case cannotEncodePNG

    var description: String {
        switch self {
        case .usage:
            return "usage: render-svg.swift input.svg output.png width height"
        case .invalidSize(let value):
            return "invalid pixel size: \(value)"
        case .cannotLoadSVG(let path):
            return "could not load SVG: \(path)"
        case .cannotCreateBitmap:
            return "could not create bitmap context"
        case .cannotCreateGraphicsContext:
            return "could not create graphics context"
        case .cannotCreateCGImage:
            return "could not create CGImage"
        case .cannotEncodePNG:
            return "could not encode PNG"
        }
    }
}

func fail(_ error: Error) -> Never {
    FileHandle.standardError.write((String(describing: error) + "\n").data(using: .utf8)!)
    exit(1)
}

do {
    let args = CommandLine.arguments
    guard args.count == 5 else { throw RenderError.usage }

    let inputPath = args[1]
    let outputPath = args[2]
    guard let width = Int(args[3]), width > 0 else { throw RenderError.invalidSize(args[3]) }
    guard let height = Int(args[4]), height > 0 else { throw RenderError.invalidSize(args[4]) }

    guard let image = NSImage(contentsOfFile: inputPath) else {
        throw RenderError.cannotLoadSVG(inputPath)
    }

    let pixelSize = NSSize(width: CGFloat(width), height: CGFloat(height))
    image.size = pixelSize

    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: width,
        pixelsHigh: height,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw RenderError.cannotCreateBitmap
    }

    bitmap.size = pixelSize
    let bounds = NSRect(origin: .zero, size: pixelSize)

    NSGraphicsContext.saveGraphicsState()
    guard let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw RenderError.cannotCreateGraphicsContext
    }
    graphicsContext.imageInterpolation = .high
    NSGraphicsContext.current = graphicsContext
    graphicsContext.cgContext.clear(CGRect(x: 0, y: 0, width: width, height: height))
    image.draw(in: bounds, from: bounds, operation: .sourceOver, fraction: 1.0, respectFlipped: false, hints: [.interpolation: NSImageInterpolation.high])
    NSGraphicsContext.restoreGraphicsState()

    guard let cgImage = bitmap.cgImage else {
        throw RenderError.cannotCreateCGImage
    }

    let outputURL = URL(fileURLWithPath: outputPath)
    guard let destination = CGImageDestinationCreateWithURL(outputURL as CFURL, "public.png" as CFString, 1, nil) else {
        throw RenderError.cannotEncodePNG
    }

    CGImageDestinationAddImage(destination, cgImage, [:] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
        throw RenderError.cannotEncodePNG
    }
} catch {
    fail(error)
}
