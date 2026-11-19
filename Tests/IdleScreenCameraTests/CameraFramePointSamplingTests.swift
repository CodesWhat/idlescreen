import Foundation
import Testing

@testable import IdleScreenCamera

#if canImport(Darwin)
  import Darwin
#endif

/// A sparse in-memory mailbox region: only the header and one slot payload
/// exist, and every copy is recorded so tests can prove how much was read.
private final class SampledMailboxRegion: IdleScreenCameraMappedRegion {
  let byteCount: Int
  var unsafeBaseAddress: UnsafeRawPointer { UnsafeRawPointer(baseStorage) }
  private let baseStorage: UnsafeMutableRawPointer
  private let header: [UInt8]
  private let payloadOffset: Int
  var payload: [UInt8]
  var onPayloadCopy: ((Int) -> Void)?
  private(set) var copiedByteCount = 0
  private(set) var payloadCopyCount = 0

  init(header: [UInt8], payload: [UInt8], payloadOffset: Int, byteCount: Int) {
    self.header = header
    self.payload = payload
    self.payloadOffset = payloadOffset
    self.byteCount = byteCount
    baseStorage = .allocate(
      byteCount: MemoryLayout<UInt64>.size,
      alignment: MemoryLayout<UInt64>.alignment
    )
  }

  deinit { baseStorage.deallocate() }

  func copyBytes(
    at offset: Int,
    into destination: UnsafeMutableRawBufferPointer
  ) throws {
    copiedByteCount += destination.count
    let source: [UInt8]
    let base: Int
    if offset < header.count {
      source = header
      base = 0
    } else {
      source = payload
      base = payloadOffset
      payloadCopyCount += 1
      onPayloadCopy?(payloadCopyCount)
    }
    let start = offset - base
    guard start >= 0, start + destination.count <= source.count,
      let address = destination.baseAddress
    else {
      throw IdleScreenCameraFrameMappingError.invalidCopyRange(
        offset: offset,
        count: destination.count,
        mappedByteCount: byteCount
      )
    }
    _ = source.withUnsafeBytes {
      memcpy(address, $0.baseAddress!.advanced(by: start), destination.count)
    }
  }
}

private final class SampledMailboxFile: IdleScreenCameraFrameStorageFile {
  let metadata: IdleScreenCameraFrameFileMetadata
  let region: SampledMailboxRegion

  init(region: SampledMailboxRegion) throws {
    self.region = region
    metadata = IdleScreenCameraFrameFileMetadata(
      kind: .regularFile,
      ownerUserID: geteuid(),
      permissions: 0o600,
      byteCount: UInt64(try IdleScreenCameraFrameMailboxLayout.current.expectedFileByteCount())
    )
  }

  func mapReadOnly(byteCount: Int) throws -> any IdleScreenCameraMappedRegion { region }
}

private struct SampledMailboxStorage: IdleScreenCameraFrameStorage {
  let file: SampledMailboxFile

  func openReadOnlyNoFollow(at url: URL) throws -> any IdleScreenCameraFrameStorageFile { file }
}

private final class SampleScriptedGenerationLoader: IdleScreenCameraGenerationLoading {
  private let values: [UInt64]
  private(set) var callCount = 0

  init(_ values: [UInt64]) { self.values = values }

  func loadAcquireGeneration(
    from baseAddress: UnsafeRawPointer,
    byteOffset: Int
  ) throws -> UInt64 {
    defer { callCount += 1 }
    return values[min(callCount, values.count - 1)]
  }
}

private struct SamplingFixture {
  let descriptor: IdleScreenCameraFrameDescriptor
  let region: SampledMailboxRegion
  let mapping: IdleScreenCameraFrameMailboxMapping
  let pixels: [UInt8]

  init(
    width: UInt64,
    height: UInt64,
    paddingBytes: UInt64,
    generations: [UInt64] = [2, 2, 2, 2, 2, 2, 2, 2],
    attemptLimit: Int = 3
  ) throws {
    let bytesPerRow = width * 4 + paddingBytes
    descriptor = IdleScreenCameraFrameDescriptor(
      protocolVersion: IdleScreenCameraFrameDescriptor.currentProtocolVersion,
      streamEpoch: 9,
      sequence: 5,
      timestamp: 1,
      width: width,
      height: height,
      bytesPerRow: bytesPerRow,
      pixelFormat: .bgra8Unorm,
      slotIndex: 1,
      slotCount: 3
    )
    var state: UInt64 = width &* 31 &+ height &* 17 &+ paddingBytes
    pixels = (0..<Int(bytesPerRow * height)).map { _ in
      state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      return UInt8(truncatingIfNeeded: state >> 33)
    }
    let layout = IdleScreenCameraFrameMailboxLayout.current
    region = SampledMailboxRegion(
      header: Array(
        IdleScreenCameraFrameMailboxHeader(generation: 2, descriptor: descriptor).encoded()
      ),
      payload: pixels,
      payloadOffset: try layout.payloadOffset(forSlot: 1),
      byteCount: try layout.expectedFileByteCount()
    )
    mapping = try IdleScreenCameraFrameMailboxMapping(
      contentsOf: URL(fileURLWithPath: "/unused"),
      storage: SampledMailboxStorage(file: try SampledMailboxFile(region: region)),
      generationLoader: SampleScriptedGenerationLoader(generations),
      snapshotAttemptLimit: attemptLimit
    )
  }
}

/// Independent reference: the renderer's full-frame point coordinates.
private func referenceBGRA(
  pixels: [UInt8],
  width: Int,
  height: Int,
  bytesPerRow: Int,
  columns: Int,
  rows: Int
) -> [UInt8] {
  var out = [UInt8]()
  for row in 0..<rows {
    let y = row * (height / rows) + row * (height % rows) / rows
    for column in 0..<columns {
      let x = column * (width / columns) + column * (width % columns) / columns
      let offset = y * bytesPerRow + x * 4
      out.append(contentsOf: pixels[offset..<offset + 4])
    }
  }
  return out
}

@Suite("Camera frame compact point sampling")
struct CameraFramePointSamplingTests {
  @Test(
    "compact samples equal full-copy sampling for padded rows and varied dimensions",
    arguments: [
      (1, 1, 0, 160, 90),
      (5, 3, 8, 160, 90),
      (7, 11, 12, 4, 4),
      (160, 90, 0, 160, 90),
      (161, 91, 28, 160, 90),
      (640, 480, 64, 160, 90),
      (1280, 720, 32, 160, 90),
      (1920, 1000, 512, 160, 90),
      (100, 60, 4, 500, 500),
    ] as [(Int, Int, Int, Int, Int)]
  )
  func equalsFullCopy(
    width: Int, height: Int, padding: Int, columns: Int, rows: Int
  ) throws {
    let fixture = try SamplingFixture(
      width: UInt64(width), height: UInt64(height), paddingBytes: UInt64(padding)
    )
    let read = try fixture.mapping.withStablePointSamples(
      columns: columns,
      rows: rows,
      copyingSamplesWhen: { _ in true }
    ) { descriptor, samples in (descriptor, samples) }
    guard case .frame((let descriptor, let samples))? = read else {
      Issue.record("Expected stable samples")
      return
    }
    let effectiveColumns = min(columns, IdleScreenCameraBGRAPointSamples.maximumColumns)
    let effectiveRows = min(rows, IdleScreenCameraBGRAPointSamples.maximumRows)
    let expected = referenceBGRA(
      pixels: fixture.pixels,
      width: width,
      height: height,
      bytesPerRow: width * 4 + padding,
      columns: effectiveColumns,
      rows: effectiveRows
    )
    #expect(descriptor == fixture.descriptor)
    #expect(samples.columns == effectiveColumns)
    #expect(samples.rows == effectiveRows)
    #expect(samples.bytes == expected)

    let full = try fixture.pixels.withUnsafeBytes {
      try IdleScreenCameraBGRAPointSamples.sampling(
        descriptor: fixture.descriptor, pixels: $0, columns: columns, rows: rows
      )
    }
    #expect(full == samples)
    // Header plus only the sampled pixels; never the frame payload.
    #expect(fixture.region.copiedByteCount == 128 + samples.copiedByteCount)
    if width >= 640 { #expect(samples.copiedByteCount < fixture.pixels.count / 10) }
    #expect(samples.copiedByteCount == effectiveColumns * effectiveRows * 4)
  }

  @Test("a generation change during sampling discards the result and retries")
  func generationChangeDuringSampling() throws {
    let fixture = try SamplingFixture(
      width: 64, height: 48, paddingBytes: 16, generations: [2, 4, 2, 2]
    )
    var corrupt = fixture.pixels
    for index in corrupt.indices { corrupt[index] = ~corrupt[index] }
    let original = fixture.pixels
    fixture.region.payload = corrupt
    // The producer rewrites the slot between the first attempt's copy and its
    // generation-after load; the retry sees the settled payload.
    fixture.region.onPayloadCopy = { count in
      if count == 5 { fixture.region.payload = original }
    }
    var bodyCount = 0
    let read = try fixture.mapping.withStablePointSamples(
      columns: 16, rows: 9, copyingSamplesWhen: { _ in true }
    ) { _, samples in
      bodyCount += 1
      return samples.bytes
    }
    guard case .frame(let bytes)? = read else {
      Issue.record("Expected a retried stable result")
      return
    }
    #expect(bodyCount == 1)
    #expect(
      bytes
        == referenceBGRA(
          pixels: original, width: 64, height: 48, bytesPerRow: 272, columns: 16, rows: 9
        )
    )
  }

  @Test("retry exhaustion publishes nothing")
  func retryExhaustion() throws {
    let fixture = try SamplingFixture(
      width: 8, height: 8, paddingBytes: 0,
      generations: [2, 4, 4, 6, 6, 8], attemptLimit: 3
    )
    var bodyCount = 0
    let read = try fixture.mapping.withStablePointSamples(
      columns: 4, rows: 4, copyingSamplesWhen: { _ in true }
    ) { _, _ in bodyCount += 1 }
    #expect(read == nil)
    #expect(bodyCount == 0)
  }

  @Test("a rejected descriptor copies no samples")
  func rejectedDescriptorCopiesNoSamples() throws {
    let fixture = try SamplingFixture(width: 8, height: 8, paddingBytes: 0)
    let read = try fixture.mapping.withStablePointSamples(
      columns: 4, rows: 4, copyingSamplesWhen: { _ in false }
    ) { _, _ in () }
    guard case .descriptor(let descriptor)? = read else {
      Issue.record("Expected descriptor-only read")
      return
    }
    #expect(descriptor == fixture.descriptor)
    #expect(fixture.region.payloadCopyCount == 0)
    #expect(fixture.region.copiedByteCount == 128)
  }

  @Test("invalid grids and odd generations fail without publishing")
  func invalidGrid() throws {
    let fixture = try SamplingFixture(width: 8, height: 8, paddingBytes: 0)
    #expect(
      throws: IdleScreenCameraBGRAPointSamples.SamplingError.invalidGrid(columns: 0, rows: 4)
    ) {
      try fixture.mapping.withStablePointSamples(
        columns: 0, rows: 4, copyingSamplesWhen: { _ in true }
      ) { _, _ in () }
    }
    let odd = try SamplingFixture(
      width: 8, height: 8, paddingBytes: 0, generations: [3, 3, 3]
    )
    let read = try odd.mapping.withStablePointSamples(
      columns: 4, rows: 4, copyingSamplesWhen: { _ in true }
    ) { _, _ in () }
    #expect(read == nil)
  }
}
