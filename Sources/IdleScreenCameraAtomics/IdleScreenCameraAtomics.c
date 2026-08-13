#include "IdleScreenCameraAtomics.h"

typedef _Atomic(uint64_t) IdleScreenCameraAtomicUInt64;

static IdleScreenCameraAtomicStatus idle_screen_camera_validate_atomic_address(
    const void *address
) {
    if (address == NULL) {
        return IdleScreenCameraAtomicStatusNullPointer;
    }
    if ((uintptr_t)address % _Alignof(IdleScreenCameraAtomicUInt64) != 0) {
        return IdleScreenCameraAtomicStatusMisalignedPointer;
    }
    return IdleScreenCameraAtomicStatusOK;
}

static IdleScreenCameraAtomicStatus idle_screen_camera_validate_output_address(
    const uint64_t *address
) {
    if (address == NULL) {
        return IdleScreenCameraAtomicStatusNullPointer;
    }
    if ((uintptr_t)address % _Alignof(uint64_t) != 0) {
        return IdleScreenCameraAtomicStatusMisalignedPointer;
    }
    return IdleScreenCameraAtomicStatusOK;
}

size_t idle_screen_camera_atomic_uint64_alignment(void) {
    return _Alignof(IdleScreenCameraAtomicUInt64);
}

IdleScreenCameraAtomicStatus idle_screen_camera_atomic_load_uint64_acquire(
    const void *address,
    uint64_t *value_out
) {
    IdleScreenCameraAtomicStatus status =
        idle_screen_camera_validate_atomic_address(address);
    if (status != IdleScreenCameraAtomicStatusOK) {
        return status;
    }
    status = idle_screen_camera_validate_output_address(value_out);
    if (status != IdleScreenCameraAtomicStatusOK) {
        return status;
    }

    const IdleScreenCameraAtomicUInt64 *atomic_address = address;
    *value_out = atomic_load_explicit(atomic_address, memory_order_acquire);
    return IdleScreenCameraAtomicStatusOK;
}

IdleScreenCameraAtomicStatus idle_screen_camera_atomic_store_uint64_release(
    void *address,
    uint64_t value
) {
    IdleScreenCameraAtomicStatus status =
        idle_screen_camera_validate_atomic_address(address);
    if (status != IdleScreenCameraAtomicStatusOK) {
        return status;
    }

    IdleScreenCameraAtomicUInt64 *atomic_address = address;
    atomic_store_explicit(atomic_address, value, memory_order_release);
    return IdleScreenCameraAtomicStatusOK;
}

IdleScreenCameraAtomicStatus idle_screen_camera_atomic_fetch_add_uint64_acq_rel(
    void *address,
    uint64_t operand,
    uint64_t *previous_value_out
) {
    IdleScreenCameraAtomicStatus status =
        idle_screen_camera_validate_atomic_address(address);
    if (status != IdleScreenCameraAtomicStatusOK) {
        return status;
    }
    status = idle_screen_camera_validate_output_address(previous_value_out);
    if (status != IdleScreenCameraAtomicStatusOK) {
        return status;
    }

    IdleScreenCameraAtomicUInt64 *atomic_address = address;
    *previous_value_out = atomic_fetch_add_explicit(
        atomic_address,
        operand,
        memory_order_acq_rel
    );
    return IdleScreenCameraAtomicStatusOK;
}
