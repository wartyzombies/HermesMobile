import Foundation

#if canImport(os)
import os
#endif

/// Simple cross-platform logger.
///
/// On Apple platforms, uses OSLog with subsystem and category.
/// On Linux, prints to stdout with prefix.
public struct HermesLogger {
    public let subsystem: String
    public let category: String

    #if canImport(os)
    private let logger: Logger
    #endif

    public init(subsystem: String, category: String) {
        self.subsystem = subsystem
        self.category = category
        #if canImport(os)
        self.logger = Logger(subsystem: subsystem, category: category)
        #endif
    }

    public func error(_ message: String) {
        #if canImport(os)
        logger.error("\(message)")
        #else
        print("[ERROR][\(subsystem):\(category)] \(message)")
        #endif
    }

    public func notice(_ message: String) {
        #if canImport(os)
        logger.notice("\(message)")
        #else
        print("[NOTICE][\(subsystem):\(category)] \(message)")
        #endif
    }
}
