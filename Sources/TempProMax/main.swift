import CHIDReader
import Darwin
import Foundation

private enum ExitCode: Int32 {
    case success = 0
    case failure = 1
    case usage = 64
}

private enum Aggregate: String {
    case average
    case high
    case low

    var flag: String { "--\(rawValue)" }

    func reduce(_ values: [Double]) -> Double {
        switch self {
        case .average:
            return values.reduce(0, +) / Double(values.count)
        case .high:
            return values.max() ?? 0
        case .low:
            return values.min() ?? 0
        }
    }
}

private struct Options {
    var dieOnly = false
    var json = false
    var simple = false
    var aggregate: Aggregate?
    var watchInterval: TimeInterval?
    var noColor = false
    var help = false
}

private enum ArgumentError: Error, CustomStringConvertible {
    case unknown(String)
    case missingValue(String)
    case invalidInterval(String)
    case conflictingAggregate(String, String)

    var description: String {
        switch self {
        case .unknown(let value):
            return "Unknown argument: \(value)"
        case .missingValue(let flag):
            return "Missing value for \(flag)"
        case .invalidInterval(let value):
            return "Invalid watch interval: \(value)"
        case .conflictingAggregate(let first, let second):
            return "\(first) and \(second) are mutually exclusive"
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

private struct Snapshot: Codable {
    let timestamp: Date
    let temperatures: TemperatureGroups
    let thermalState: [String]
}

private struct TerminalStyle {
    let enabled: Bool
    let truecolor: Bool

    init(enabled: Bool, truecolor: Bool = false) {
        self.enabled = enabled
        self.truecolor = enabled && truecolor
    }

    var reset: String { enabled ? "\u{001B}[0m" : "" }
    var bold: String { enabled ? "\u{001B}[1m" : "" }
    var dim: String { enabled ? "\u{001B}[2m" : "" }
    var cyan: String { enabled ? "\u{001B}[36m" : "" }
    var green: String { enabled ? "\u{001B}[32m" : "" }
    var yellow: String { enabled ? "\u{001B}[33m" : "" }
    var red: String { enabled ? "\u{001B}[31m" : "" }

    func rgb(_ red: Int, _ green: Int, _ blue: Int) -> String {
        guard enabled else {
            return ""
        }
        return "\u{001B}[38;2;\(red);\(green);\(blue)m"
    }
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
        case "--simple":
            options.simple = true
        case "--average", "--high", "--low":
            let aggregate = Aggregate(rawValue: String(argument.dropFirst(2)))!
            if let existing = options.aggregate, existing != aggregate {
                throw ArgumentError.conflictingAggregate(existing.flag, aggregate.flag)
            }
            options.aggregate = aggregate
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
        thermalState: readThermalState()
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
}

private func temperatureColor(_ celsius: Double, style: TerminalStyle) -> String {
    guard style.enabled else {
        return ""
    }

    if style.truecolor {
        let (red, green, blue) = temperatureSpectrum(celsius)
        return style.rgb(red, green, blue)
    }

    if celsius >= 90 {
        return style.red
    }

    if celsius >= 70 {
        return style.yellow
    }

    return style.green
}

// Interpolates green -> yellow -> red across gradientFloor...gradientCeiling,
// clamped at both ends, for truecolor terminals.
private let gradientFloor = 30.0
private let gradientCeiling = 95.0

private func temperatureSpectrum(_ celsius: Double) -> (Int, Int, Int) {
    let span = gradientCeiling - gradientFloor
    let fraction = min(max((celsius - gradientFloor) / span, 0), 1)

    // 0.0 -> green (63, 185, 80), 0.5 -> yellow (255, 209, 71), 1.0 -> red (255, 64, 53)
    let green = (red: 63.0, green: 185.0, blue: 80.0)
    let yellow = (red: 255.0, green: 209.0, blue: 71.0)
    let red = (red: 255.0, green: 64.0, blue: 53.0)

    let stop: (red: Double, green: Double, blue: Double)
    let next: (red: Double, green: Double, blue: Double)
    let localFraction: Double

    if fraction < 0.5 {
        stop = green
        next = yellow
        localFraction = fraction / 0.5
    } else {
        stop = yellow
        next = red
        localFraction = (fraction - 0.5) / 0.5
    }

    func lerp(_ from: Double, _ to: Double) -> Int {
        Int((from + (to - from) * localFraction).rounded())
    }

    return (lerp(stop.red, next.red), lerp(stop.green, next.green), lerp(stop.blue, next.blue))
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

private func terminalSupportsTrueColor() -> Bool {
    let colorTerm = ProcessInfo.processInfo.environment["COLORTERM"]?.lowercased() ?? ""
    return colorTerm == "truecolor" || colorTerm == "24bit"
}

private func shownReadings(_ snapshot: Snapshot, options: Options) -> [SensorReading] {
    var readings: [SensorReading] = []
    for category in SensorCategory.allCases {
        if options.dieOnly && category != .die {
            continue
        }
        readings.append(contentsOf: snapshot.temperatures[category])
    }
    return readings
}

private func printSimple(_ snapshot: Snapshot, options: Options, style: TerminalStyle) {
    let readings = shownReadings(snapshot, options: options)
    let nameWidth = max(6, readings.map(\.name.count).max() ?? 6)

    for reading in readings {
        let color = temperatureColor(reading.celsius, style: style)
        let paddedName = reading.name.padding(toLength: nameWidth, withPad: " ", startingAt: 0)
        print("\(paddedName)  \(color)\(String(format: "%5.1f", reading.celsius))\(celsiusUnit)\(style.reset)")
    }
}

private func printAggregate(_ snapshot: Snapshot, aggregate: Aggregate, options: Options, style: TerminalStyle) {
    let values = shownReadings(snapshot, options: options).map(\.celsius)
    guard !values.isEmpty else {
        return
    }
    let result = aggregate.reduce(values)
    let color = temperatureColor(result, style: style)
    print("\(color)\(String(format: "%.1f", result))\(celsiusUnit)\(style.reset)")
}

private func render(_ snapshot: Snapshot, options: Options, style: TerminalStyle) throws {
    if options.json {
        try printJSON(snapshot)
    } else if let aggregate = options.aggregate {
        printAggregate(snapshot, aggregate: aggregate, options: options, style: style)
    } else if options.simple {
        printSimple(snapshot, options: options, style: style)
    } else {
        printText(snapshot, options: options, style: style)
    }
}

private func run(options: Options) throws -> ExitCode {
    if options.help {
        printUsage()
        return .success
    }

    let style = TerminalStyle(
        enabled: terminalSupportsColor(noColor: options.noColor || options.json),
        truecolor: terminalSupportsTrueColor()
    )

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
        Usage: temppromax [--die] [--simple] [--average | --high | --low]
                          [--json] [--watch[=N] | -w N] [--no-color]

        Options:
          --die          Only show die temperature sensors.
          --simple       Print one sensor per line, no headers or system info.
          --average      Print a single average of the shown sensors.
          --high         Print the single highest of the shown sensors.
          --low          Print the single lowest of the shown sensors.
          --json         Print JSON instead of a table.
          --watch[=N]    Refresh in place every N seconds. Defaults to 2.
          -w N           Refresh in place every N seconds.
          --no-color     Disable ANSI color.
          -h, --help     Show this help.

        --average, --high, and --low are mutually exclusive. temppromax reads
        CPU/die temperatures only; GPU temps are not available (see README).
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
