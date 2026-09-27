import CoreVideo
import Vision
import XCTest

final class VisionOpticalFlowContractTests: XCTestCase {
    private let width = 640
    private let height = 480

    func testVisionFlowDirectionMatchesHandlerImageToTargetImage() throws {
        let previous = try image(shiftX: 0)
        let current = try image(shiftX: 8)
        let request = VNGenerateOpticalFlowRequest(targetedCVPixelBuffer: current, options: [:])
        request.computationAccuracy = .high
        request.outputPixelFormat = kCVPixelFormatType_TwoComponent32Float
        let handler = VNImageRequestHandler(cvPixelBuffer: previous, options: [:])
        try handler.perform([request])
        let flow = try XCTUnwrap(request.results?.first?.pixelBuffer)
        CVPixelBufferLockBaseAddress(flow, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(flow, .readOnly)
        }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(flow))
            .assumingMemoryBound(to: SIMD2<Float>.self)
        let rowStride = CVPixelBufferGetBytesPerRow(flow) / MemoryLayout<SIMD2<Float>>.stride
        var horizontal: [Double] = []
        var vertical: [Double] = []
        for y in stride(from: 80, through: 400, by: 40) {
            for x in stride(from: 100, through: 540, by: 40) {
                let vector = base[y * rowStride + x]
                horizontal.append(Double(vector.x))
                vertical.append(Double(vector.y))
            }
        }
        let horizontalInInputPixels = median(horizontal) * Double(width) / Double(CVPixelBufferGetWidth(flow))
        let verticalInInputPixels = median(vertical) * Double(height) / Double(CVPixelBufferGetHeight(flow))
        XCTAssertGreaterThan(horizontalInInputPixels, 1)
        XCTAssertLessThan(horizontalInInputPixels, 16)
        XCTAssertEqual(verticalInInputPixels, 0, accuracy: 1.2)
    }

    private func image(shiftX: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ] as CFDictionary
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                         kCVPixelFormatType_32BGRA, attributes, &buffer)
        XCTAssertEqual(status, kCVReturnSuccess)
        let result = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(result, [])
        defer {
            CVPixelBufferUnlockBaseAddress(result, [])
        }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(result))
            .assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(result)
        for y in 0..<height {
            for x in 0..<width {
                let sourceX = x - shiftX
                var value: UInt8 = 0
                if sourceX >= 0, sourceX < width {
                    var tile = 0
                    if ((sourceX / 8) + (y / 8)).isMultiple(of: 2) {
                        tile = 70
                    }
                    let mixed = (sourceX * 3 + y * 5 + tile) & 255
                    value = UInt8(mixed)
                }
                let offset = y * bytesPerRow + x * 4
                base[offset] = value
                base[offset + 1] = value
                base[offset + 2] = value
                base[offset + 3] = 255
            }
        }
        return result
    }

    private func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}
