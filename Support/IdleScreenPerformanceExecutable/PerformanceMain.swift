import Darwin
import Foundation
import IdleScreenPerformance

@main
struct IdleScreenPerformanceMain {
    @MainActor
    static func main() {
        do {
            let arguments = try Arguments(CommandLine.arguments)
            if arguments.showsHelp {
                print(Arguments.usage)
                return
            }
            if arguments.printsBudgets {
                try write(
                    JSONEncoder.idleScreenPerformance.encode(
                        IdleScreenPerformanceBudgets.m4ProSingleDisplay
                    ),
                    to: arguments.outputURL
                )
                return
            }
            let workload = try requiredWorkload(arguments.workload)
            FileHandle.standardError.write(
                Data(
                    "idlescreen-perf pid=\(getpid()) workload=\(workload.rawValue)\n"
                        .utf8
                )
            )
            let result: IdleScreenPerformanceWorkloadResult
            switch workload {
            case .rendererStartupCold, .rendererStartupWarm:
                result = try IdleScreenPerformanceHarness
                    .measureRendererStartup(
                        workload: workload,
                        iterations: arguments.iterations,
                        logicalWidth: arguments.logicalWidth,
                        logicalHeight: arguments.logicalHeight,
                        drawableWidth: try requiredDrawableDimension(
                            arguments.drawableWidth,
                            option: "--drawable-width"
                        ),
                        drawableHeight: try requiredDrawableDimension(
                            arguments.drawableHeight,
                            option: "--drawable-height"
                        )
                    )
            case .generative, .cameraSynthetic, .pixelMaterialsSand,
                 .pixelMaterialsWater, .pixelMaterialsMixed:
                result = try IdleScreenPerformanceHarness.measureRenderer(
                    workload: workload,
                    durationSeconds: arguments.durationSeconds,
                    logicalWidth: arguments.logicalWidth,
                    logicalHeight: arguments.logicalHeight,
                    drawableWidth: try requiredDrawableDimension(
                        arguments.drawableWidth,
                        option: "--drawable-width"
                    ),
                    drawableHeight: try requiredDrawableDimension(
                        arguments.drawableHeight,
                        option: "--drawable-height"
                    )
                )
            case .mailboxTransport:
                result = try IdleScreenPerformanceHarness
                    .measureMailboxTransport(
                        durationSeconds: arguments.durationSeconds
                    )
            case .agentSignalPolling:
                result = try IdleScreenPerformanceHarness
                    .measureAgentSignalPolling(
                        durationSeconds: arguments.durationSeconds
                    )
            case .zeroConsumer:
                result = try IdleScreenPerformanceHarness.measureZeroConsumer(
                    durationSeconds: arguments.durationSeconds
                )
            case .helperIdle:
                guard let processIdentifier = arguments.processIdentifier else {
                    throw CommandError.missingProcessIdentifier
                }
                result = try IdleScreenPerformanceHarness
                    .measureExternalProcess(
                        workload: .helperIdle,
                        processIdentifier: processIdentifier,
                        durationSeconds: arguments.durationSeconds
                    )
            }
            let encoded = try JSONEncoder.idleScreenPerformance.encode(result)
            try write(encoded, to: arguments.outputURL)
        } catch {
            FileHandle.standardError.write(
                Data("idlescreen-perf: \(error)\n\(Arguments.usage)\n".utf8)
            )
            Darwin.exit(2)
        }
    }

    private static func write(_ data: Data, to outputURL: URL?) throws {
        if let outputURL {
            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: outputURL, options: .atomic)
        } else {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([0x0A]))
        }
    }

    private static func requiredWorkload(
        _ rawValue: String?
    ) throws -> IdleScreenPerformanceWorkload {
        guard let rawValue,
              let workload = IdleScreenPerformanceWorkload(rawValue: rawValue)
        else {
            throw CommandError.invalidWorkload(rawValue)
        }
        return workload
    }

    private static func requiredDrawableDimension(
        _ value: Int?,
        option: String
    ) throws -> Int {
        guard let value else { throw CommandError.missingValue(option) }
        return value
    }
}

private enum CommandError: Error, Equatable {
    case missingValue(String)
    case invalidNumber(String)
    case unknownArgument(String)
    case invalidWorkload(String?)
    case missingProcessIdentifier
}

private struct Arguments {
    static let usage = """
    usage: idlescreen-perf --workload WORKLOAD [--duration SECONDS]
           [--iterations COUNT] [--pid PID] [--width POINTS]
           [--height POINTS] [--drawable-width PIXELS]
           [--drawable-height PIXELS] [--output PATH]
           idlescreen-perf --budgets [--output PATH]

    workloads: \(IdleScreenPerformanceWorkload.allCases.map(\.rawValue).joined(separator: ", "))
    helperIdle is sampled by scripts/run-performance-r1.sh against the existing
    demand-started helper; this executable never launches or registers it.
    """

    var workload: String?
    var durationSeconds: TimeInterval = 15 * 60
    var iterations = 5
    var outputURL: URL?
    var showsHelp = false
    var printsBudgets = false
    var processIdentifier: pid_t?
    var logicalWidth = 1_728
    var logicalHeight = 1_117
    var drawableWidth: Int?
    var drawableHeight: Int?

    init(_ arguments: [String]) throws {
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--help", "-h":
                showsHelp = true
                index += 1
            case "--budgets":
                printsBudgets = true
                index += 1
            case "--workload":
                workload = try Self.value(
                    after: argument,
                    at: &index,
                    in: arguments
                )
            case "--duration":
                let raw = try Self.value(
                    after: argument,
                    at: &index,
                    in: arguments
                )
                guard let parsed = TimeInterval(raw), parsed > 0 else {
                    throw CommandError.invalidNumber(raw)
                }
                durationSeconds = parsed
            case "--iterations":
                let raw = try Self.value(
                    after: argument,
                    at: &index,
                    in: arguments
                )
                guard let parsed = Int(raw), parsed > 0 else {
                    throw CommandError.invalidNumber(raw)
                }
                iterations = parsed
            case "--output":
                let raw = try Self.value(
                    after: argument,
                    at: &index,
                    in: arguments
                )
                outputURL = URL(filePath: raw)
            case "--pid":
                let raw = try Self.value(
                    after: argument,
                    at: &index,
                    in: arguments
                )
                guard let parsed = pid_t(raw), parsed > 0 else {
                    throw CommandError.invalidNumber(raw)
                }
                processIdentifier = parsed
            case "--width":
                let raw = try Self.value(
                    after: argument,
                    at: &index,
                    in: arguments
                )
                guard let parsed = Int(raw), parsed > 0 else {
                    throw CommandError.invalidNumber(raw)
                }
                logicalWidth = parsed
            case "--height":
                let raw = try Self.value(
                    after: argument,
                    at: &index,
                    in: arguments
                )
                guard let parsed = Int(raw), parsed > 0 else {
                    throw CommandError.invalidNumber(raw)
                }
                logicalHeight = parsed
            case "--drawable-width":
                let raw = try Self.value(
                    after: argument,
                    at: &index,
                    in: arguments
                )
                guard let parsed = Int(raw), parsed > 0 else {
                    throw CommandError.invalidNumber(raw)
                }
                drawableWidth = parsed
            case "--drawable-height":
                let raw = try Self.value(
                    after: argument,
                    at: &index,
                    in: arguments
                )
                guard let parsed = Int(raw), parsed > 0 else {
                    throw CommandError.invalidNumber(raw)
                }
                drawableHeight = parsed
            default:
                throw CommandError.unknownArgument(argument)
            }
        }
    }

    private static func value(
        after option: String,
        at index: inout Int,
        in arguments: [String]
    ) throws -> String {
        let valueIndex = index + 1
        guard valueIndex < arguments.count else {
            throw CommandError.missingValue(option)
        }
        index += 2
        return arguments[valueIndex]
    }
}
