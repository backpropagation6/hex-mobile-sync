// Draws the app icon in the style of the Hex mark: concentric metallic
// hexagon rings on a dark gradient, with a shaded hexagonal "cube" in the
// centre. 1024x1024, no alpha.
//
//   swift tools/make-app-icon.swift App/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png
//
// The artwork is generated here so the repository holds no copied assets.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let output = CommandLine.arguments.dropFirst().first ?? "AppIcon.png"
let space = CGColorSpace(name: CGColorSpace.sRGB)!

guard let context = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
    space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
) else { fatalError("Could not create the bitmap context") }

let center = CGPoint(x: Double(size) / 2, y: Double(size) / 2)

func gray(_ value: Double, _ alpha: Double = 1) -> CGColor {
    CGColor(srgbRed: value, green: value, blue: value, alpha: alpha)
}

func vertex(_ index: Int, radius: Double) -> CGPoint {
    let angle = (Double(index) * 60 + 90) * .pi / 180  // pointy top (y grows upward)
    return CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
}

func hexagon(radius: Double) -> CGPath {
    let path = CGMutablePath()
    for index in 0..<6 {
        if index == 0 { path.move(to: vertex(index, radius: radius)) } else { path.addLine(to: vertex(index, radius: radius)) }
    }
    path.closeSubpath()
    return path
}

func linear(_ colors: [CGColor], from start: CGPoint, to end: CGPoint) {
    let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: nil)!
    context.drawLinearGradient(gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

// Background: soft vertical gradient, lighter at the top.
linear([gray(0.20), gray(0.03)], from: CGPoint(x: 0, y: Double(size)), to: CGPoint(x: 0, y: 0))

// Metallic ring: stroke turned into a clip, filled with a top-light gradient.
func ring(radius: Double, width: Double) {
    context.saveGState()
    context.addPath(hexagon(radius: radius))
    context.setLineWidth(width)
    context.setLineJoin(.round)
    context.replacePathWithStrokedPath()
    context.clip()
    linear([gray(0.97), gray(0.72), gray(0.88)],
           from: CGPoint(x: center.x, y: center.y + radius), to: CGPoint(x: center.x, y: center.y - radius))
    context.restoreGState()
}

// Soft glow behind the mark.
context.saveGState()
context.setShadow(offset: .zero, blur: 60, color: gray(1, 0.18))
context.addPath(hexagon(radius: 340))
context.setStrokeColor(gray(1, 0.01))
context.setLineWidth(30)
context.strokePath()
context.restoreGState()

ring(radius: 340, width: 34)
ring(radius: 236, width: 34)

// Centre cube: three faces of a hexagon meeting at the centre.
let cube = 118.0
let faces: [([Int], Double)] = [
    ([0, 1, -1, 5], 0.98),  // top face (lightest)
    ([1, 2, 3, -1], 0.78),  // left face
    ([-1, 3, 4, 5], 0.62),  // right face (darkest)
]
for (indices, shade) in faces {
    let path = CGMutablePath()
    for (position, index) in indices.enumerated() {
        let point = index < 0 ? center : vertex(index, radius: cube)
        if position == 0 { path.move(to: point) } else { path.addLine(to: point) }
    }
    path.closeSubpath()
    context.addPath(path)
    context.setFillColor(gray(shade))
    context.fillPath()
}

guard let image = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(
          URL(fileURLWithPath: output) as CFURL, UTType.png.identifier as CFString, 1, nil)
else { fatalError("Could not create the PNG destination") }
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("Could not write \(output)") }
print("Wrote \(output)")
