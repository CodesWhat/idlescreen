#ifndef IDLE_SCREEN_CAMERA_ATOMICS_H
#define IDLE_SCREEN_CAMERA_ATOMICS_H

#include <limits.h>
#include <stddef.h>
#include <stdint.h>
#include <stdatomic.h>

#if defined(__STDC_NO_ATOMICS__)
#error "IdleScreenCameraAtomics requires C11 atomics"
#endif

#if UINT64_MAX == ULONG_MAX
#if ATOMIC_LONG_LOCK_FREE != 2
#error "IdleScreenCameraAtomics requires always-lock-free uint64 atomics"
#endif
#elif UINT64_MAX == ULLONG_MAX
#if ATOMIC_LLONG_LOCK_FREE != 2
#error "IdleScreenCameraAtomics requires always-lock-free uint64 atomics"
#endif
#else
#error "IdleScreenCameraAtomics cannot identify the uint64 atomic representation"
#endif

_Static_assert(sizeof(uint64_t) == 8, "uint64_t must contain exactly 64 bits");

typedef int32_t IdleScreenCameraAtomicStatus;

enum {
    IdleScreenCameraAtomicStatusOK = 0,
    IdleScreenCameraAtomicStatusNullPointer = 1,
    IdleScreenCameraAtomicStatusMisalignedPointer = 2,
};

size_t idle_screen_camera_atomic_uint64_alignment(void);

IdleScreenCameraAtomicStatus idle_screen_camera_atomic_load_uint64_acquire(
    const void *address,
    uint64_t *value_out
);

IdleScreenCameraAtomicStatus idle_screen_camera_atomic_store_uint64_release(
    void *address,
    uint64_t value
);

IdleScreenCameraAtomicStatus idle_screen_camera_atomic_fetch_add_uint64_acq_rel(
    void *address,
    uint64_t operand,
    uint64_t *previous_value_out
);

#endif
