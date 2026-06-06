import CHIDReader
import Darwin
import Foundation

private enum ExitCode: Int32 {
    case success = 0
    case failure = 1
    case usage = 64
}

private struct Options {
    var dieOnly = false
    var json = false
    var watchInterval: TimeInterval?
    var noColor = false
    var help = false
}

private enum ArgumentError: Error, CustomStringConvertible {
    case unknown(String)
    case missingValue(String)
    case invalidInterval(String)

    var description: String {
        switch self {
        case .unknown(let value):
            return "Unknown argument: \(value)"
        case .missingValue(let flag):
            return "Missing value for \(flag)"
        case .invalidInterval(let value):
            return "Invalid watch interval: \(value)"
        }
    }
}

private struct SensorReading: Codable {
    let product: String
    let name: String
    let celsius: Double
    let category: SensorCategory
}

private enum SensorCategory: String, Codable, CaseIterable {
    case die
    case device
    case surface

    var title: String {
        switch self {
        case .die:
            return "Die Temperatures"
        case .device:
            return "Device Temperatures"
        case .surface:
            return "Surface Temperatures"
        }
    }
}

private struct MemoryStats: Codable {
    let freeBytes: UInt64
    let totalBytes: UInt64
}

private struct TemperatureGroups: Codable {
    var die: [SensorReading]
    var device: [SensorReading]
    var surface: [SensorReading]

    init(readings: [SensorReading]) {
        die = readings.filter { $0.category == .die }
        device = readings.filter { $0.category == .device }
        surface = readings.filter { $0.category == .surface }
    }

    subscript(category: SensorCategory) -> [SensorReading] {
        switch category {
        case .die:
            return die
        case .device:
            return device
        case .surface:
            return surface
        }
    }
}

private struct SystemStats: Codable {
    let uptimeSeconds: TimeInterval
    let uptime: String
    let loadAverage: [Double]
    let memory: MemoryStats
}

private struct Snapshot: Codable {
    let timestamp: Date
    let temperatures: TemperatureGroups
    let thermalState: [String]
    let system: SystemStats
}

private struct TerminalStyle {
    let enabled: Bool

    var reset: String { enabled ? "\u{001B}[0m" : "" }
    var bold: String { enabled ? "\u{001B}[1m" : "" }
    var dim: String { enabled ? "\u{001B}[2m" : "" }
    var cyan: String { enabled ? "\u{001B}[36m" : "" }
    var green: String { enabled ? "\u{001B}[32m" : "" }
    var yellow: String { enabled ? "\u{001B}[33m" : "" }
    var red: String { enabled ? "\u{001B}[31m" : "" }
}

private let celsiusUnit = "\u{00B0}C"

private func parseOptions(_ arguments: [String]) throws -> Options {
    var options = Options()
    var index = 0

    while index < arguments.count {
        let argument = arguments[index]

        switch argument {
        case "--die":
            options.dieOnly = true
        case "--json":
            options.json = true
        case "--no-color":
            options.noColor = true
        case "--help", "-h":
            options.help = true
        case "--watch":
            if index + 1 < arguments.count {
                let rawValue = arguments[index + 1]
                if let interval = parseInterval(rawValue) {
                    options.watchInterval = interval
                    index += 1
                } else if rawValue.hasPrefix("-") {
                    options.watchInterval = 2
                } else {
                    throw ArgumentError.invalidInterval(rawValue)
                }
            } else {
                options.watchInterval = 2
            }
        case let value where value.hasPrefix("--watch="):
            let rawValue = String(value.dropFirst("--watch=".count))
            guard let interval = parseInterval(rawValue) else {
                throw ArgumentError.invalidInterval(rawValue)
            }
            options.watchInterval = interval
        case "-w":
            guard index + 1 < arguments.count else {
                throw ArgumentError.missingValue("-w")
            }
            let rawValue = arguments[index + 1]
            guard let interval = parseInterval(rawValue) else {
                throw ArgumentError.invalidInterval(rawValue)
            }
            options.watchInterval = interval
            index += 1
        case let value where value.hasPrefix("-w") && value.count > 2:
            let rawValue = String(value.dropFirst(2))
            guard let interval = parseInterval(rawValue) else {
                throw ArgumentError.invalidInterval(rawValue)
            }
            options.watchInterval = interval
        default:
            throw ArgumentError.unknown(argument)
        }

        index += 1
    }

    return options
}

private func parseInterval(_ value: String) -> TimeInterval? {
    guard let interval = TimeInterval(value), interval > 0 else {
        return nil
    }
    return interval
}

private func makeSnapshot(dieOnly: Bool, probeTimeout: TimeInterval, waitFullDuration: Bool = false) -> Snapshot? {
    let deadline = Date().addingTimeInterval(probeTimeout)
    var readings = collectReadings(dieOnly: dieOnly)

    while (readings.isEmpty || waitFullDuration) && Date() < deadline {
        Thread.sleep(forTimeInterval: 0.2)
        let latestReadings = collectReadings(dieOnly: dieOnly)
        if !latestReadings.isEmpty {
            readings = latestReadings
        }
    }

    guard !readings.isEmpty else {
        return nil
    }

    return Snapshot(
        timestamp: Date(),
        temperatures: TemperatureGroups(readings: readings),
        thermalState: readThermalState(),
        system: readSystemStats()
    )
}

private func collectReadings(dieOnly: Bool) -> [SensorReading] {
    let rawReadings = readAppleSiliconTemperatures()
    var readings: [SensorReading] = []

    for (product, value) in rawReadings {
        guard product.hasPrefix("PMU") else {
            continue
        }

        let name = normalizeSensorName(product)
        guard name != "tcal", let category = categorizeSensor(name) else {
            continue
        }

        if dieOnly && category != .die {
            continue
        }

        readings.append(
            SensorReading(
                product: product,
                name: name,
                celsius: value.doubleValue,
                category: category
            )
        )
    }

    return readings.sorted(by: compareReadings)
}

private func normalizeSensorName(_ product: String) -> String {
    let prefix = "PMU "
    if product.hasPrefix(prefix) {
        return String(product.dropFirst(prefix.count))
    }
    return product
}

private func categorizeSensor(_ name: String) -> SensorCategory? {
    if name.hasPrefix("tdie") {
        return .die
    }

    if name.hasPrefix("tdev") {
        return .device
    }

    if name.hasPrefix("TP") {
        return .surface
    }

    return nil
}

private func compareReadings(_ lhs: SensorReading, _ rhs: SensorReading) -> Bool {
    if lhs.category != rhs.category {
        return SensorCategory.allCases.firstIndex(of: lhs.category)! < SensorCategory.allCases.firstIndex(of: rhs.category)!
    }

    return compareSortKeys(naturalSortKey(lhs.name), naturalSortKey(rhs.name))
}

private func compareSortKeys(_ lhs: [String], _ rhs: [String]) -> Bool {
    for (left, right) in zip(lhs, rhs) {
        if left == right {
            continue
        }
        return left < right
    }

    return lhs.count < rhs.count
}

private func naturalSortKey(_ value: String) -> [String] {
    var parts: [String] = []
    var current = ""
    var currentIsNumber: Bool?

    for character in value {
        let isNumber = character.isNumber
        if let previous = currentIsNumber, previous != isNumber {
            parts.append(normalizeSortPart(current, isNumber: previous))
            current = ""
        }
        current.append(character)
        currentIsNumber = isNumber
    }

    if let isNumber = currentIsNumber {
        parts.append(normalizeSortPart(current, isNumber: isNumber))
    }

    return parts
}

private func normalizeSortPart(_ value: String, isNumber: Bool) -> String {
    if isNumber, let number = Int(value) {
        return String(format: "%012d", number)
    }
    return value
}

private func readThermalState() -> [String] {
    let result = runCommand("/usr/bin/pmset", arguments: ["-g", "therm"])
    let text = result.output.trimmingCharacters(in: .whitespacesAndNewlines)

    if !text.isEmpty {
        return text.components(separatedBy: .newlines)
    }

    if !result.error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return result.error.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines)
    }

    return ["pmset -g therm returned no output"]
}

private func readSystemStats() -> SystemStats {
    let uptimeSeconds = ProcessInfo.processInfo.systemUptime
    return SystemStats(
        uptimeSeconds: uptimeSeconds,
        uptime: formatUptime(uptimeSeconds),
        loadAverage: readLoadAverage(),
        memory: readMemoryStats()
    )
}

private func readLoadAverage() -> [Double] {
    var loads = [Double](repeating: 0, count: 3)
    let count = getloadavg(&loads, Int32(loads.count))
    if count <= 0 {
        return []
    }
    return Array(loads.prefix(Int(count)))
}

private func readMemoryStats() -> MemoryStats {
    var stats = vm_statistics64()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)

    let result = withUnsafeMutablePointer(to: &stats) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
            host_statistics64(mach_host_self(), HOST_VM_INFO64, reboundPointer, &count)
        }
    }

    let pageSize = UInt64(vm_kernel_page_size)
    let total = ProcessInfo.processInfo.physicalMemory

    guard result == KERN_SUCCESS else {
        return MemoryStats(freeBytes: 0, totalBytes: total)
    }

    let availablePages = UInt64(stats.free_count + stats.inactive_count + stats.speculative_count)
    return MemoryStats(freeBytes: availablePages * pageSize, totalBytes: total)
}

private func runCommand(_ executable: String, arguments: [String]) -> (output: String, error: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments

    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = errorPipe

    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        return ("", "\(error)")
    }

    let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

    return (
        String(data: outputData, encoding: .utf8) ?? "",
        String(data: errorData, encoding: .utf8) ?? ""
    )
}

private func printText(_ snapshot: Snapshot, options: Options, style: TerminalStyle) {
    print("\(style.bold)\(style.cyan)temppromax - Temperature Monitor\(style.reset)")
    print("\(style.dim)-----------------------------\(style.reset)")

    for category in SensorCategory.allCases {
        if options.dieOnly && category != .die {
            continue
        }

        let readings = snapshot.temperatures[category]
        guard !readings.isEmpty else {
            continue
        }

        print("\n\(style.bold)\(category.title):\(style.reset)")
        let nameWidth = max(6, readings.map(\.name.count).max() ?? 6)

        for reading in readings {
            let color = temperatureColor(reading.celsius, style: style)
            let paddedName = reading.name.padding(toLength: nameWidth, withPad: " ", startingAt: 0)
            print("  \(paddedName)  \(color)\(String(format: "%5.1f", reading.celsius))\(celsiusUnit)\(style.reset)")
        }
    }

    print("\n\(style.bold)Thermal State:\(style.reset)")
    for line in snapshot.thermalState {
        print("  \(line)")
    }

    let load = snapshot.system.loadAverage.map { String(format: "%.2f", $0) }.joined(separator: " ")
    print("\n\(style.bold)System:\(style.reset)")
    print("  up \(snapshot.system.uptime), load: \(load)")
    print("  \(formatBytes(snapshot.system.memory.freeBytes)) free / \(formatBytes(snapshot.system.memory.totalBytes))")
}

private func temperatureColor(_ celsius: Double, style: TerminalStyle) -> String {
    guard style.enabled else {
        return ""
    }

    if celsius >= 90 {
        return style.red
    }

    if celsius >= 70 {
        return style.yellow
    }

    return style.green
}

private func printJSON(_ snapshot: Snapshot) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(snapshot)
    if let text = String(data: data, encoding: .utf8) {
        print(text)
    }
}

private func formatUptime(_ seconds: TimeInterval) -> String {
    let totalMinutes = Int(seconds / 60)
    let days = totalMinutes / (24 * 60)
    let hours = (totalMinutes / 60) % 24
    let minutes = totalMinutes % 60

    var parts: [String] = []
    if days > 0 {
        parts.append("\(days) \(days == 1 ? "day" : "days")")
    }

    parts.append(String(format: "%d:%02d", hours, minutes))
    return parts.joined(separator: ", ")
}

private func formatBytes(_ bytes: UInt64) -> String {
    let gibibyte = 1024.0 * 1024.0 * 1024.0
    let value = Double(bytes) / gibibyte

    if value >= 10 {
        return "\(Int(value.rounded())) GB"
    }

    return String(format: "%.1f GB", value)
}

private func terminalSupportsColor(noColor: Bool) -> Bool {
    if noColor {
        return false
    }

    if ProcessInfo.processInfo.environment["NO_COLOR"] != nil {
        return false
    }

    guard isatty(STDOUT_FILENO) == 1 else {
        return false
    }

    let term = ProcessInfo.processInfo.environment["TERM"] ?? ""
    return !term.isEmpty && term != "dumb"
}

private func render(_ snapshot: Snapshot, options: Options, style: TerminalStyle) throws {
    if options.json {
        try printJSON(snapshot)
    } else {
        printText(snapshot, options: options, style: style)
    }
}

private func run(options: Options) throws -> ExitCode {
    if options.help {
        printUsage()
        return .success
    }

    let style = TerminalStyle(enabled: terminalSupportsColor(noColor: options.noColor || options.json))

    if let interval = options.watchInterval {
        while true {
            if isatty(STDOUT_FILENO) == 1 {
                print("\u{001B}[2J\u{001B}[H", terminator: "")
            }

            guard let snapshot = makeSnapshot(dieOnly: options.dieOnly, probeTimeout: min(2, interval)) else {
                fputs("Not an Apple Silicon Mac or sensors unavailable\n", stderr)
                return .failure
            }

            try render(snapshot, options: options, style: style)
            fflush(stdout)
            Thread.sleep(forTimeInterval: interval)
        }
    }

    guard let snapshot = makeSnapshot(dieOnly: options.dieOnly, probeTimeout: 2, waitFullDuration: true) else {
        fputs("Not an Apple Silicon Mac or sensors unavailable\n", stderr)
        return .failure
    }

    try render(snapshot, options: options, style: style)
    return .success
}

private func printUsage() {
    print(
        """
        Usage: temppromax [--die] [--json] [--watch[=N] | -w N] [--no-color]

        Options:
          --die          Only show die temperature sensors.
          --json         Print JSON instead of a table.
          --watch[=N]    Refresh in place every N seconds. Defaults to 2.
          -w N           Refresh in place every N seconds.
          --no-color     Disable ANSI color.
          -h, --help     Show this help.
        """
    )
}

do {
    let options = try parseOptions(Array(CommandLine.arguments.dropFirst()))
    exit(try run(options: options).rawValue)
} catch let error as ArgumentError {
    fputs("\(error)\n\n", stderr)
    printUsage()
    exit(ExitCode.usage.rawValue)
} catch {
    fputs("\(error)\n", stderr)
    exit(ExitCode.failure.rawValue)
}
