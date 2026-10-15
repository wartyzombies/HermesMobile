import Foundation

#if canImport(OSLog)
import OSLog
#endif

/// Simple cross-platform logger.
///
/// On Apple platforms, uses OSLog with subsystem and category.
/// On Linux, prints to stdout with prefix.
public struct HermesLogger {
    public let subsystem: String
    public let category: String

    #if canImport(OSLog)
    private let logger: OSLog.Logger
    #endif

    public init(subsystem: String, category: String) {
        self.subsystem = subsystem
        self.category = category
        #if canImport(OSLog)
        self.logger = OSLog.Logger(subsystem: subsystem, category: category)
        #endif
    }

    public func error(_ message: String) {
        #if canImport(OSLog)
        logger.error("\(message)")
        #else
        print("[ERROR][\(subsystem):\(category)] \(message)")
        #endif
    }

    public func notice(_ message: String) {
        #if canImport(OSLog)
        logger.notice("\(message)")
        #else
        print("[NOTICE][\(subsystem):\(category)] \(message)")
        #endif
    }
}