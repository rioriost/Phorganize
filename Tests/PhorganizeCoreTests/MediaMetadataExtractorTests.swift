import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import PhorganizeCore

final class MediaMetadataExtractorTests: XCTestCase {
    func testSupportedExtensionsAreCaseInsensitive() {
        let extractor = MediaMetadataExtractor()

        XCTAssertTrue(extractor.isSupported(URL(fileURLWithPath: "/tmp/photo.CR3")))
        XCTAssertTrue(extractor.isSupported(URL(fileURLWithPath: "/tmp/movie.Mp4")))
        XCTAssertFalse(extractor.isSupported(URL(fileURLWithPath: "/tmp/readme.txt")))
    }

    func testExtractsImageMetadataWithoutSubprocesses() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let imageURL = directory.appendingPathComponent("photo.jpg")
        try writeJPEG(
            to: imageURL,
            date: "2023:05:15 10:30:00",
            offset: "+09:00",
            cameraModel: " Canon EOS R6m2 ",
            lensModel: " RF24-70mm F2.8 L IS USM "
        )

        let metadata = await MediaMetadataExtractor().extractMetadata(
            from: imageURL,
            timeZone: TimeZone(identifier: "Asia/Tokyo")!
        )

        XCTAssertEqual(metadata?.cameraModel, "Canon EOS R6m2")
        XCTAssertEqual(metadata?.lensModel, "RF24-70mm F2.8 L IS USM")
        XCTAssertEqual(metadata?.source, .image)
        XCTAssertEqual(metadata?.creationDate, makeDate("2023-05-15T01:30:00Z"))
    }

    func testInvalidSupportedImageFallsBackToFileAttributes() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let imageURL = directory.appendingPathComponent("broken.jpg")
        FileManager.default.createFile(atPath: imageURL.path, contents: Data("not an image".utf8))

        let metadata = await MediaMetadataExtractor().extractMetadata(from: imageURL, timeZone: .current)

        XCTAssertNotNil(metadata?.creationDate)
        XCTAssertNil(metadata?.cameraModel)
        XCTAssertEqual(metadata?.source, .fileAttributes)
    }

    func testMissingFileHasNoMetadata() async {
        let metadata = await MediaMetadataExtractor().extractMetadata(
            from: URL(fileURLWithPath: "/tmp/phorganize-\(UUID().uuidString).jpg"),
            timeZone: .current
        )

        XCTAssertNil(metadata)
    }

    func testDigitizedAndTIFFDatesUseTheirOwnOffsets() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cases: [([String: Any], [String: Any])] = [
            ([
                kCGImagePropertyExifDateTimeDigitized as String: "2025:02:06 01:00:00",
                kCGImagePropertyExifOffsetTimeDigitized as String: "+09:00",
                kCGImagePropertyExifOffsetTimeOriginal as String: "-08:00"
            ], [:]),
            ([
                kCGImagePropertyExifOffsetTime as String: "+09:00",
                kCGImagePropertyExifOffsetTimeOriginal as String: "-08:00"
            ], [kCGImagePropertyTIFFDateTime as String: "2025:02:06 01:00:00"])
        ]
        for (index, properties) in cases.enumerated() {
            let image = root.appendingPathComponent(index == 0 ? "digitized.jpg" : "modified.tiff")
            try writeImage(to: image, exif: properties.0, tiff: properties.1, type: index == 0 ? .jpeg : .tiff)
            let result = await MediaMetadataExtractor().extractMetadata(from: image, timeZone: TimeZone(secondsFromGMT: 0)!)
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(image as CFURL, nil))
            let storedProperties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
            XCTAssertEqual(result?.creationDate, makeDate("2025-02-05T16:00:00Z"), "Case \(index): \(String(describing: storedProperties))")
            XCTAssertEqual(result?.source, .image)
            let plan = try TargetPlanner.makePlan(
                candidates: [MediaFileCandidate(sourceURL: image, metadata: XCTUnwrap(result))],
                destinationURL: root,
                options: OrganizationOptions(includeCameraFolder: false, timezoneIdentifier: "UTC")
            )
            XCTAssertTrue(plan[0].targetURL.path.hasSuffix("/2025/02/05/20250205-160000.\(image.pathExtension)"))
        }
    }

    func testInvalidOriginalDateFallsBackToDigitizedDate() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let image = root.appendingPathComponent("invalid-original.jpg")
        try writeImage(to: image, exif: [
            kCGImagePropertyExifDateTimeOriginal as String: "0000:00:00 00:00:00",
            kCGImagePropertyExifDateTimeDigitized as String: "2025:02:06 01:00:00",
            kCGImagePropertyExifOffsetTimeDigitized as String: "+09:00"
        ])
        let result = await MediaMetadataExtractor().extractMetadata(from: image, timeZone: TimeZone(secondsFromGMT: 0)!)
        XCTAssertEqual(result?.creationDate, makeDate("2025-02-05T16:00:00Z"))
    }

    func testMissingImageDatePreservesCameraAndLensWithAttributeDate() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let image = root.appendingPathComponent("no-date.jpg")
        try writeImage(
            to: image,
            exif: [kCGImagePropertyExifLensModel as String: "Review Lens"],
            tiff: [kCGImagePropertyTIFFModel as String: "Review Camera"]
        )
        let result = await MediaMetadataExtractor().extractMetadata(from: image, timeZone: .current)
        XCTAssertEqual(result?.source, .fileAttributes)
        XCTAssertEqual(result?.cameraModel, "Review Camera")
        XCTAssertEqual(result?.lensModel, "Review Lens")
        XCTAssertNotNil(result?.creationDate)
    }

    func testVideoDateAndPartialMetadataFallback() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for date in [nil, "2025-02-06T01:00:00+09:00"] as [String?] {
            let video = root.appendingPathComponent(date == nil ? "no-date.mov" : "dated.mov")
            try await writeVideo(to: video, date: date)
            let result = await MediaMetadataExtractor().extractMetadata(from: video, timeZone: TimeZone(secondsFromGMT: 0)!)
            XCTAssertEqual(result?.cameraModel, "Review Camera")
            XCTAssertEqual(result?.lensModel, "Review Lens")
            if date != nil {
                XCTAssertEqual(result?.source, .video)
                XCTAssertEqual(result?.creationDate, makeDate("2025-02-05T16:00:00Z"))
            } else {
                XCTAssertEqual(result?.source, .fileAttributes)
                XCTAssertNotNil(result?.creationDate)
            }
        }
    }

    private func writeJPEG(
        to url: URL,
        date: String,
        offset: String,
        cameraModel: String,
        lensModel: String
    ) throws {
        try writeImage(to: url, exif: [
            kCGImagePropertyExifDateTimeOriginal as String: date,
            kCGImagePropertyExifOffsetTimeOriginal as String: offset,
            kCGImagePropertyExifLensModel as String: lensModel
        ], tiff: [kCGImagePropertyTIFFModel as String: cameraModel])
    }

    private func writeImage(
        to url: URL, exif: [String: Any], tiff: [String: Any] = [:], type: UTType = .jpeg
    ) throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(
            CGContext(
                data: nil,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithURL(
                url as CFURL,
                type.identifier as CFString,
                1,
                nil
            )
        )
        let properties: [String: Any] = [
            kCGImagePropertyExifDictionary as String: exif,
            kCGImagePropertyTIFFDictionary as String: tiff
        ]

        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    private func writeVideo(to url: URL, date: String?) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        var values = [
            ("com.apple.quicktime.camera.lens_model", "Review Lens"),
            ("com.apple.quicktime.model", "Review Camera")
        ]
        if let date { values.append(("com.apple.quicktime.creationdate", date)) }
        writer.metadata = values.map { key, value in
            let item = AVMutableMetadataItem()
            item.keySpace = .quickTimeMetadata
            item.key = key as NSString
            item.value = value as NSString
            return item
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 16,
            AVVideoHeightKey: 16
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input)
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        var pixelBuffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(
            kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32ARGB, nil, &pixelBuffer
        ), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixelBuffer)
        CVPixelBufferLockBaseAddress(buffer, [])
        if let address = CVPixelBufferGetBaseAddress(buffer) {
            memset(address, 0, CVPixelBufferGetDataSize(buffer))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        XCTAssertTrue(adaptor.append(buffer, withPresentationTime: .zero))
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, writer.error?.localizedDescription ?? "Video fixture failed")
    }

    private func makeDate(_ value: String) -> Date? {
        ISO8601DateFormatter().date(from: value)
    }
}
