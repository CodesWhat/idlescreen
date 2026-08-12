import Darwin
import Foundation
import MachO

public enum IdleScreenPerformanceProcessSamplerError: Error, Equatable,
    Sendable
{
    case resourceUsage(Int32)
    case processResourceUsage(processIdentifier: pid_t, code: Int32)
    case virtualMemory(kern_return_t)
    case power(kern_return_t)
}

public enum IdleScreenPerformanceProcessSampler {
    public static func snapshot(
        processIdentifier: pid_t
    ) throws -> IdleScreenPerformanceResourceSnapshot {
        var usage = rusage_info_v4()
        let result = withUnsafeMutableBytes(of: &usage) { bytes in
            proc_pid_rusage(
                processIdentifier,
                RUSAGE_INFO_V4,
                bytes.baseAddress!.assumingMemoryBound(to: rusage_info_t?.self)
            )
        }
        guard result == 0 else {
            throw IdleScreenPerformanceProcessSamplerError
                .processResourceUsage(
                    processIdentifier: processIdentifier,
                    code: errno
                )
        }
        return .init(
            capturedAt: ProcessInfo.processInfo.systemUptime,
            userCPUSeconds: Double(usage.ri_user_time) / 1_000_000_000,
            systemCPUSeconds: Double(usage.ri_system_time) / 1_000_000_000,
            residentMemoryBytes: usage.ri_phys_footprint,
            peakResidentMemoryBytes: max(
                usage.ri_phys_footprint,
                usage.ri_lifetime_max_phys_footprint
            ),
            interruptWakeups: usage.ri_interrupt_wkups,
            platformIdleWakeups: usage.ri_pkg_idle_wkups,
            timerWakeups: 0
        )
    }

    public static func snapshot() throws -> IdleScreenPerformanceResourceSnapshot {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else {
            throw IdleScreenPerformanceProcessSamplerError.resourceUsage(errno)
        }

        var virtualMemory = task_vm_info_data_t()
        var virtualMemoryCount = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size
                / MemoryLayout<natural_t>.size
        )
        let virtualMemoryStatus = withUnsafeMutablePointer(to: &virtualMemory) {
            pointer in
            pointer.withMemoryRebound(
                to: integer_t.self,
                capacity: Int(virtualMemoryCount)
            ) { rebound in
                task_info(
                    mach_task_self_,
                    task_flavor_t(TASK_VM_INFO),
                    rebound,
                    &virtualMemoryCount
                )
            }
        }
        guard virtualMemoryStatus == KERN_SUCCESS else {
            throw IdleScreenPerformanceProcessSamplerError.virtualMemory(
                virtualMemoryStatus
            )
        }

        var power = task_power_info_data_t()
        var powerCount = mach_msg_type_number_t(
            MemoryLayout<task_power_info_data_t>.size
                / MemoryLayout<natural_t>.size
        )
        let powerStatus = withUnsafeMutablePointer(to: &power) { pointer in
            pointer.withMemoryRebound(
                to: integer_t.self,
                capacity: Int(powerCount)
            ) { rebound in
                task_info(
                    mach_task_self_,
                    task_flavor_t(TASK_POWER_INFO),
                    rebound,
                    &powerCount
                )
            }
        }
        guard powerStatus == KERN_SUCCESS else {
            throw IdleScreenPerformanceProcessSamplerError.power(powerStatus)
        }

        return .init(
            capturedAt: ProcessInfo.processInfo.systemUptime,
            userCPUSeconds: seconds(usage.ru_utime),
            systemCPUSeconds: seconds(usage.ru_stime),
            residentMemoryBytes: max(
                UInt64(virtualMemory.resident_size),
                UInt64(virtualMemory.phys_footprint)
            ),
            peakResidentMemoryBytes: max(
                UInt64(virtualMemory.resident_size_peak),
                virtualMemory.ledger_phys_footprint_peak > 0
                    ? UInt64(virtualMemory.ledger_phys_footprint_peak)
                    : UInt64(virtualMemory.phys_footprint)
            ),
            interruptWakeups: power.task_interrupt_wakeups,
            platformIdleWakeups: power.task_platform_idle_wakeups,
            timerWakeups: power.task_timer_wakeups_bin_1
                + power.task_timer_wakeups_bin_2
        )
    }

    private static func seconds(_ value: timeval) -> Double {
        Double(value.tv_sec) + Double(value.tv_usec) / 1_000_000
    }
}
