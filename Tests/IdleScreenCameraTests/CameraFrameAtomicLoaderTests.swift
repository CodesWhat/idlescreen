import Dispatch
import Foundation
import IdleScreenCameraAtomics
import Testing
@testable import IdleScreenCamera

private final class AtomicTestStorage: @unchecked Sendable {
    let baseAddress: UnsafeMutableRawPointer
    let byteCount: Int

    init(byteCount: Int = 16) {
        self.byteCount = byteCount
        baseAddress = .allocate(
            byteCount: byteCount,
            alignment: Int(idle_screen_camera_atomic_uint64_alignment())
        )
        baseAddress.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
    }

    deinit {
        baseAddress.deallocate()
    }
}

private final class LockedUInt64: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0

    func store(_ newValue: UInt64) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    func load() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

@Suite("Camera frame interprocess atomics")
struct CameraFrameAtomicLoaderTests {
    @Test("the C boundary rejects null and misaligned pointers")
    func cBoundaryPointerValidation() {
        let storage = AtomicTestStorage()
        var value: UInt64 = 0

        #expect(
            idle_screen_camera_atomic_load_uint64_acquire(nil, &value)
                == IdleScreenCameraAtomicStatusNullPointer
        )
        #expect(
            idle_screen_camera_atomic_load_uint64_acquire(storage.baseAddress, nil)
                == IdleScreenCameraAtomicStatusNullPointer
        )
        #expect(
            idle_screen_camera_atomic_load_uint64_acquire(
                storage.baseAddress.advanced(by: 1),
                &value
            ) == IdleScreenCameraAtomicStatusMisalignedPointer
        )
        #expect(
            idle_screen_camera_atomic_store_uint64_release(nil, 1)
                == IdleScreenCameraAtomicStatusNullPointer
        )
        #expect(
            idle_screen_camera_atomic_store_uint64_release(
                storage.baseAddress.advanced(by: 1),
                1
            ) == IdleScreenCameraAtomicStatusMisalignedPointer
        )
        #expect(
            idle_screen_camera_atomic_fetch_add_uint64_acq_rel(
                storage.baseAddress,
                1,
                nil
            ) == IdleScreenCameraAtomicStatusNullPointer
        )
    }

    @Test("release stores are visible to acquire loads")
    func releaseAcquireVisibility() {
        let storage = AtomicTestStorage()
        let generationAddress = storage.baseAddress
        let payloadAddress = storage.baseAddress.advanced(by: MemoryLayout<UInt64>.stride)
        let expectedPayload = UInt64(0xCAFE_BABE_DEAD_BEEF)
        let readerReady = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let queue = DispatchQueue(
            label: "com.idlescreen.tests.atomic-visibility",
            attributes: .concurrent
        )
        let observedPayload = LockedUInt64()

        #expect(
            idle_screen_camera_atomic_store_uint64_release(generationAddress, 0)
                == IdleScreenCameraAtomicStatusOK
        )

        queue.async {
            readerReady.signal()
            var generation: UInt64 = 0
            var attemptsRemaining = 1_000_000
            repeat {
                _ = idle_screen_camera_atomic_load_uint64_acquire(
                    storage.baseAddress,
                    &generation
                )
                attemptsRemaining -= 1
            } while generation != 2 && attemptsRemaining > 0
            if generation == 2 {
                observedPayload.store(
                    storage.baseAddress
                        .advanced(by: MemoryLayout<UInt64>.stride)
                        .load(as: UInt64.self)
                )
            }
            finished.signal()
        }

        readerReady.wait()
        payloadAddress.storeBytes(of: expectedPayload, as: UInt64.self)
        #expect(
            idle_screen_camera_atomic_store_uint64_release(generationAddress, 2)
                == IdleScreenCameraAtomicStatusOK
        )
        #expect(finished.wait(timeout: .now() + 2) == .success)
        #expect(observedPayload.load() == expectedPayload)
    }

    @Test("concurrent fetch-add advances generation without lost updates")
    func concurrentGenerationAdvancement() {
        let storage = AtomicTestStorage(byteCount: 8)
        let workers = 8
        let incrementsPerWorker = 2_000
        let group = DispatchGroup()
        let queue = DispatchQueue(
            label: "com.idlescreen.tests.atomic-fetch-add",
            attributes: .concurrent
        )

        #expect(
            idle_screen_camera_atomic_store_uint64_release(storage.baseAddress, 0)
                == IdleScreenCameraAtomicStatusOK
        )
        for _ in 0..<workers {
            group.enter()
            queue.async {
                for _ in 0..<incrementsPerWorker {
                    var previous: UInt64 = 0
                    _ = idle_screen_camera_atomic_fetch_add_uint64_acq_rel(
                        storage.baseAddress,
                        1,
                        &previous
                    )
                }
                group.leave()
            }
        }

        #expect(group.wait(timeout: .now() + 5) == .success)
        var generation: UInt64 = 0
        #expect(
            idle_screen_camera_atomic_load_uint64_acquire(
                storage.baseAddress,
                &generation
            ) == IdleScreenCameraAtomicStatusOK
        )
        #expect(generation == UInt64(workers * incrementsPerWorker))
    }

    @Test("the Swift loader reads only aligned in-range generation fields")
    func loaderBoundsAndAlignment() throws {
        let storage = AtomicTestStorage(byteCount: 24)
        let loader = try IdleScreenCameraAtomicGenerationLoader(mappedByteCount: 24)

        #expect(
            idle_screen_camera_atomic_store_uint64_release(
                storage.baseAddress.advanced(by: 16),
                42
            ) == IdleScreenCameraAtomicStatusOK
        )
        #expect(
            try loader.loadAcquireGeneration(
                from: UnsafeRawPointer(storage.baseAddress),
                byteOffset: 16
            ) == 42
        )
        #expect(throws: IdleScreenCameraAtomicGenerationLoaderError.negativeByteOffset(-1)) {
            try loader.loadAcquireGeneration(
                from: UnsafeRawPointer(storage.baseAddress),
                byteOffset: -1
            )
        }
        #expect(
            throws: IdleScreenCameraAtomicGenerationLoaderError.unalignedByteOffset(
                byteOffset: 1,
                requiredAlignment: 8
            )
        ) {
            try loader.loadAcquireGeneration(
                from: UnsafeRawPointer(storage.baseAddress),
                byteOffset: 1
            )
        }
        #expect(
            throws: IdleScreenCameraAtomicGenerationLoaderError.outOfBounds(
                byteOffset: 24,
                valueByteCount: 8,
                mappedByteCount: 24
            )
        ) {
            try loader.loadAcquireGeneration(
                from: UnsafeRawPointer(storage.baseAddress),
                byteOffset: 24
            )
        }
        #expect(
            throws: IdleScreenCameraAtomicGenerationLoaderError.byteRangeOverflow(
                byteOffset: Int.max,
                valueByteCount: 8
            )
        ) {
            try loader.loadAcquireGeneration(
                from: UnsafeRawPointer(storage.baseAddress),
                byteOffset: Int.max
            )
        }
    }

    @Test("the Swift loader rejects an unaligned mapped base")
    func loaderRejectsUnalignedBase() throws {
        let storage = AtomicTestStorage(byteCount: 16)
        let loader = try IdleScreenCameraAtomicGenerationLoader(mappedByteCount: 8)

        #expect(
            throws: IdleScreenCameraAtomicGenerationLoaderError.unalignedAddress(
                requiredAlignment: 8
            )
        ) {
            try loader.loadAcquireGeneration(
                from: UnsafeRawPointer(storage.baseAddress.advanced(by: 1)),
                byteOffset: 0
            )
        }
    }

    @Test("the Swift loader rejects a negative mapped byte count")
    func loaderRejectsNegativeMappedByteCount() {
        #expect(
            throws: IdleScreenCameraAtomicGenerationLoaderError.invalidMappedByteCount(-1)
        ) {
            try IdleScreenCameraAtomicGenerationLoader(mappedByteCount: -1)
        }
    }
}
