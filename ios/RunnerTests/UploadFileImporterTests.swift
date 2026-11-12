import XCTest
import ImageIO
import CoreGraphics
@testable import UploadValidationHost

final class UploadFileImporterTests: XCTestCase {
  private var directory: URL!
  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }
  override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

  private func sink(limit: Int64 = 1_000, cancelled: @escaping () -> Bool = { false }, space: Bool = true) throws -> UploadImportSink {
    try UploadImportSink(destination: directory.appendingPathComponent("original.gif"), relativePath: "imports/test/original.gif",
        displayName: "原名.gif", remainingBytes: limit, cancelled: cancelled, hasSpace: { _ in space })
  }

  func testStreamPreservesOriginalBytesAndReturnsRelativePath() throws {
    let writer = try sink()
    writer.append(Data([71, 73, 70, 56, 57, 97]))
    writer.append(Data([0, 1, 2, 255]))
    let result = try writer.finish(error: nil, mime: "image/gif").get()
    XCTAssertEqual(result["relativePath"] as? String, "imports/test/original.gif")
    XCTAssertEqual(result["displayName"] as? String, "原名.gif")
    XCTAssertEqual(result["size"] as? Int64, 10)
    XCTAssertEqual(try Data(contentsOf: writer.destination), Data([71, 73, 70, 56, 57, 97, 0, 1, 2, 255]))
    XCTAssertFalse(FileManager.default.fileExists(atPath: writer.partial.path))
  }

  func testOverLimitDoesNotLeavePartialOrFinalFile() throws {
    let writer = try sink(limit: 3)
    writer.append(Data([1, 2, 3, 4]))
    XCTAssertThrowsError(try writer.finish(error: nil, mime: "image/gif").get())
    XCTAssertFalse(FileManager.default.fileExists(atPath: writer.partial.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: writer.destination.path))
  }

  func testCancellationClosesSinkAndLateChunksCannotRestoreFile() throws {
    let writer = try sink()
    writer.append(Data([1, 2]))
    writer.cancel()
    writer.append(Data([3, 4]))
    XCTAssertThrowsError(try writer.finish(error: nil, mime: "image/gif").get())
    XCTAssertFalse(FileManager.default.fileExists(atPath: writer.partial.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: writer.destination.path))
  }

  func testDiskSpaceFailureIsNotReportedAsSuccessfulImport() throws {
    let writer = try sink(space: false)
    writer.append(Data([1]))
    XCTAssertThrowsError(try writer.finish(error: nil, mime: "image/gif").get())
    XCTAssertFalse(FileManager.default.fileExists(atPath: writer.destination.path))
  }

  private func tiff(frames: Int = 1, orientation: Int = 1) throws -> URL {
    let folder = directory.appendingPathComponent("imports/source", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent("source.tiff")
    let context = try XCTUnwrap(CGContext(data: nil, width: 128, height: 192, bitsPerComponent: 8,
      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 128, height: 192))
    let image = try XCTUnwrap(context.makeImage())
    let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.tiff" as CFString, frames, nil))
    for _ in 0..<frames { CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary) }
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return url
  }

  func testExplicitConversionPreservesDimensionsAndOriginalCopy() throws {
    let source = try tiff()
    let original = try Data(contentsOf: source)
    let result = try UploadImageConversion(root: directory).convert("imports/source/source.tiff")
    let relative = try XCTUnwrap(result["relativePath"] as? String)
    let converted = try XCTUnwrap(CGImageSourceCreateWithURL(directory.appendingPathComponent(relative) as CFURL, nil))
    let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(converted, 0, nil))
    XCTAssertEqual(image.width, 128); XCTAssertEqual(image.height, 192)
    XCTAssertEqual(CGImageSourceGetCount(converted), 1)
    XCTAssertEqual(CGImageSourceGetType(converted) as String?, "public.png")
    XCTAssertEqual(try Data(contentsOf: source), original)
  }

  func testExplicitConversionAppliesOrientationWithoutResizing() throws {
    _ = try tiff(orientation: 6)
    let result = try UploadImageConversion(root: directory).convert("imports/source/source.tiff")
    let relative = try XCTUnwrap(result["relativePath"] as? String)
    let converted = try XCTUnwrap(CGImageSourceCreateWithURL(directory.appendingPathComponent(relative) as CFURL, nil))
    let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(converted, 0, nil))
    XCTAssertEqual(image.width, 192); XCTAssertEqual(image.height, 128)
  }

  func testExplicitConversionRejectsMultipleFramesWithoutDeletingSource() throws {
    let source = try tiff(frames: 2)
    let original = try Data(contentsOf: source)
    XCTAssertThrowsError(try UploadImageConversion(root: directory).convert("imports/source/source.tiff")) { error in
      XCTAssertEqual((error as? UploadTransferFailure)?.code, "unsupported_conversion")
    }
    XCTAssertEqual(try Data(contentsOf: source), original)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("imports").path), ["source"])
  }

  func testExplicitConversionRejectsSymlinkRootAndTraversal() throws {
    _ = try tiff()
    let alias = directory.appendingPathComponent("root-alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)
    XCTAssertThrowsError(try UploadImageConversion(root: alias).convert("imports/source/source.tiff")) { error in
      XCTAssertEqual((error as? UploadTransferFailure)?.code, "unsafe_path")
    }
    XCTAssertThrowsError(try UploadImageConversion(root: directory).convert("imports/../source.tiff"))
  }
}
