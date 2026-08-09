import AppKit
import CoreImage
import Foundation

guard CommandLine.arguments.count == 4 else {
    fputs("usage: apply-windows-screen.swift HERO SCREEN OUTPUT\n", stderr)
    exit(2)
}

let heroURL = URL(fileURLWithPath: CommandLine.arguments[1])
let screenURL = URL(fileURLWithPath: CommandLine.arguments[2])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[3])

guard let hero = CIImage(contentsOf: heroURL),
      let screen = CIImage(contentsOf: screenURL),
      let perspective = CIFilter(name: "CIPerspectiveTransform") else {
    fputs("could not load images or perspective filter\n", stderr)
    exit(3)
}

// Coordinates use Core Image's bottom-left origin. These four points are the
// inner corners of the Windows display in the 1536 x 1024 marketing render.
perspective.setValue(screen, forKey: kCIInputImageKey)
perspective.setValue(CIVector(x: 793, y: 917), forKey: "inputTopLeft")
perspective.setValue(CIVector(x: 1464, y: 897), forKey: "inputTopRight")
perspective.setValue(CIVector(x: 1458, y: 503), forKey: "inputBottomRight")
perspective.setValue(CIVector(x: 794, y: 533), forKey: "inputBottomLeft")

guard let projected = perspective.outputImage else {
    fputs("perspective transform failed\n", stderr)
    exit(4)
}

let result = projected.composited(over: hero).cropped(to: hero.extent)
fputs("hero=\(hero.extent) screen=\(screen.extent) projected=\(projected.extent) result=\(result.extent)\n", stderr)
let ciRepresentation = NSCIImageRep(ciImage: result)
let rendered = NSImage(size: hero.extent.size)
rendered.addRepresentation(ciRepresentation)
guard let tiff = rendered.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    fputs("could not encode PNG\n", stderr)
    exit(5)
}
do {
    try png.write(to: outputURL, options: .atomic)
} catch {
    fputs("write failed: \(error)\n", stderr)
    exit(6)
}
