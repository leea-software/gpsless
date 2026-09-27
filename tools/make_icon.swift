import CoreGraphics
import Foundation
import ImageIO

let size = 1024
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
context.setFillColor(CGColor(red: 0.055, green: 0.085, blue: 0.105, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: size, height: size))
context.move(to: CGPoint(x: 100, y: -50))
context.addLine(to: CGPoint(x: 425, y: 435))
context.addCurve(to: CGPoint(x: 650, y: 650), control1: CGPoint(x: 470, y: 515), control2: CGPoint(x: 550, y: 650))
context.addLine(to: CGPoint(x: 1100, y: 650))
context.setLineWidth(90)
context.setLineCap(.round)
context.setStrokeColor(CGColor(red: 0.23, green: 0.32, blue: 0.35, alpha: 1))
context.strokePath()
context.setFillColor(CGColor(red: 0.69, green: 0.96, blue: 0.39, alpha: 1))
context.fillEllipse(in: CGRect(x: 285, y: 285, width: 450, height: 450))
context.setFillColor(CGColor(red: 0.06, green: 0.11, blue: 0.10, alpha: 1))
context.move(to: CGPoint(x: 510, y: 659))
context.addLine(to: CGPoint(x: 407, y: 389))
context.addLine(to: CGPoint(x: 510, y: 445))
context.addLine(to: CGPoint(x: 613, y: 389))
context.closePath()
context.fillPath()
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let directory = root.appendingPathComponent("GPSLess/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
let destination = CGImageDestinationCreateWithURL(directory.appendingPathComponent("AppIcon.png") as CFURL, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(destination, context.makeImage()!, nil)
guard CGImageDestinationFinalize(destination) else {
    fatalError("Could not write app icon")
}
