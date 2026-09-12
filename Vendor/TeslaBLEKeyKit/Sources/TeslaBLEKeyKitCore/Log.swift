import Foundation
import os

public enum LogLevel: Int, Sendable {
    case debug = 0
    case info = 1
    case error = 2
    case fault = 3
}

public extension Notification.Name {
    static let teslaBLEKeyLog = Notification.Name("com.teslakey.ble.log")
}

public enum Log {
    private static let subsystem = "com.teslakey.ble"
    private static let logger = Logger(subsystem: subsystem, category: "TeslaBLEKeyKit")
    private static let queue = DispatchQueue(label: "com.teslakey.ble.log", qos: .background, target: .global(qos: .background))

    // MARK: - Public API

    public static func debug(_ items: Any..., file: String = #file, line: Int = #line, function: String = #function) {
        log(items, level: .debug, file: file, line: line, function: function)
    }

    public static func info(_ items: Any..., file: String = #file, line: Int = #line, function: String = #function) {
        log(items, level: .info, file: file, line: line, function: function)
    }

    public static func error(_ items: Any..., file: String = #file, line: Int = #line, function: String = #function) {
        log(items, level: .error, file: file, line: line, function: function)
    }

    public static func fault(_ items: Any..., file: String = #file, line: Int = #line, function: String = #function) {
        log(items, level: .fault, file: file, line: line, function: function)
    }

    public static func dataSummary(_ data: Data, maxBytes: Int = 16) -> String {
        guard !data.isEmpty else { return "0B" }
        let prefix = data.prefix(max(0, maxBytes))
            .map { String(format: "%02x", $0) }
            .joined()
        let suffix = data.count > maxBytes ? "..." : ""
        return "\(data.count)B[0x\(prefix)\(suffix)]"
    }

    public static func errorSummary(_ error: Error) -> String {
        let nsError = error as NSError
        return "\(type(of: error))(domain=\(nsError.domain), code=\(nsError.code), message=\(error.localizedDescription))"
    }

    // MARK: - Internal

    private static func log(_ items: [Any], level: LogLevel, file: String, line: Int, function: String) {
        let message = items.map { "\($0)" }.joined(separator: " ")
        let fileName = (file as NSString).lastPathComponent

        queue.async {
            let formatted = "\(currentTime()) \(fileName)[\(line)] \(function): \(message)"
#if DEBUG
            let osLevel: OSLogType
            switch level {
            case .debug: osLevel = .debug
            case .info:  osLevel = .info
            case .error: osLevel = .error
            case .fault: osLevel = .fault
            }
            logger.log(level: osLevel, "\(formatted, privacy: .public)")
#endif
            if level.rawValue >= LogLevel.error.rawValue {
                NotificationCenter.default.post(
                    name: .teslaBLEKeyLog,
                    object: nil,
                    userInfo: ["level": level.rawValue, "message": formatted]
                )
            }
        }
    }

    private static func currentTime() -> String {
        var tv = timeval()
        gettimeofday(&tv, nil)

        var sec = tv.tv_sec
        var tmInfo = tm()
        localtime_r(&sec, &tmInfo)

        var buffer = [CChar](repeating: 0, count: 64)
        strftime(&buffer, buffer.count, "%Y-%m-%d %H:%M:%S", &tmInfo)

        var tzBuffer = [CChar](repeating: 0, count: 8)
        strftime(&tzBuffer, tzBuffer.count, "%z", &tmInfo)

        let microseconds = Int(tv.tv_usec)
        let time = String(decoding: buffer.prefix(while: { $0 != 0 }).map(UInt8.init), as: UTF8.self)
        let tz = String(decoding: tzBuffer.prefix(while: { $0 != 0 }).map(UInt8.init), as: UTF8.self)
        return String(format: "%@.%06d%@", time, microseconds, tz)
    }
}
