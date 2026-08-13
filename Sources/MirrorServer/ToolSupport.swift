import Foundation
import MCP
import MirrorCore

/// Typed access to a tool call's arguments with LLM-friendly errors.
/// Numeric accessors accept both int and double encodings — models send
/// `200` and `200.5` interchangeably for number-typed parameters.
public struct ToolArgs: Sendable {
    let raw: [String: Value]

    public init(_ raw: [String: Value]) { self.raw = raw }

    public func string(_ key: String) throws -> String {
        guard let value = try optionalString(key) else { throw missing(key, "string") }
        return value
    }

    public func optionalString(_ key: String) throws -> String? {
        guard let value = raw[key], !value.isNull else { return nil }
        guard let string = value.stringValue else { throw wrongType(key, "string") }
        return string
    }

    public func double(_ key: String) throws -> Double {
        guard let value = try optionalDouble(key) else { throw missing(key, "number") }
        return value
    }

    public func optionalDouble(_ key: String) throws -> Double? {
        guard let value = raw[key], !value.isNull else { return nil }
        if let double = value.doubleValue { return double }
        if let int = value.intValue { return Double(int) }
        throw wrongType(key, "number")
    }

    public func int(_ key: String) throws -> Int {
        guard let value = try optionalDouble(key) else {
            throw missing(key, "number")
        }
        return try safeInt(value, key: key)
    }

    public func int(_ key: String, default defaultValue: Int) throws -> Int {
        guard let value = try optionalDouble(key) else { return defaultValue }
        return try safeInt(value, key: key)
    }

    public func optionalInt(_ key: String) throws -> Int? {
        guard let value = try optionalDouble(key) else { return nil }
        return try safeInt(value, key: key)
    }

    /// `Int(_: Double)` TRAPS on non-finite or out-of-range values — and one
    /// trap kills the whole stdio server. Reject instead of crashing.
    private func safeInt(_ value: Double, key: String) throws -> Int {
        guard value.isFinite, value >= -9_007_199_254_740_991, value <= 9_007_199_254_740_991 else {
            throw MirrorError("Parameter \"\(key)\" is out of integer range.")
        }
        return Int(value)
    }

    public func bool(_ key: String, default defaultValue: Bool) throws -> Bool {
        guard let value = raw[key], !value.isNull else { return defaultValue }
        guard let bool = value.boolValue else { throw wrongType(key, "boolean") }
        return bool
    }

    public func objectArray(_ key: String) throws -> [[String: Value]] {
        guard let value = raw[key], !value.isNull else { return [] }
        guard let array = value.arrayValue else { throw wrongType(key, "array of objects") }
        return try array.map {
            guard let object = $0.objectValue else { throw wrongType(key, "array of objects") }
            return object
        }
    }

    public func stringArray(_ key: String) throws -> [String] {
        guard let value = raw[key], !value.isNull else { return [] }
        guard let array = value.arrayValue else { throw wrongType(key, "array of strings") }
        return try array.map {
            guard let string = $0.stringValue else { throw wrongType(key, "array of strings") }
            return string
        }
    }

    private func missing(_ key: String, _ type: String) -> MirrorError {
        MirrorError("Missing required \(type) parameter \"\(key)\".")
    }

    private func wrongType(_ key: String, _ type: String) -> MirrorError {
        MirrorError("Parameter \"\(key)\" must be a \(type).")
    }
}

extension Value {
    var isNull: Bool {
        if case .null = self { return true }
        return false
    }
}

/// One tool: its MCP definition plus its handler.
public struct RegisteredTool: Sendable {
    public let tool: Tool
    public let handler: @Sendable (ToolArgs) async throws -> CallTool.Result

    public init(
        name: String,
        description: String,
        schema: Value,
        handler: @escaping @Sendable (ToolArgs) async throws -> CallTool.Result
    ) {
        self.tool = Tool(name: name, description: description, inputSchema: schema)
        self.handler = handler
    }
}

// MARK: - Result helpers

public func textResult(_ text: String) -> CallTool.Result {
    CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)])
}

public func imageResult(pngData: Data, caption: String) -> CallTool.Result {
    CallTool.Result(content: [
        .text(text: caption, annotations: nil, _meta: nil),
        .image(data: pngData.base64EncodedString(), mimeType: "image/png", annotations: nil, _meta: nil),
    ])
}

public func errorResult(_ error: Error) -> CallTool.Result {
    let message: String
    if let mirrorError = error as? MirrorError {
        message = mirrorError.description
    } else {
        message = "\(error)"
    }
    return CallTool.Result(
        content: [.text(text: message, annotations: nil, _meta: nil)],
        isError: true
    )
}

/// Formats OCR elements as one line each: text, confidence, box, center.
/// Centers are directly usable as tap coordinates.
public func describeElements(_ elements: [OCRElement]) -> String {
    guard !elements.isEmpty else { return "No text recognized on screen." }
    let lines = elements.map { element in
        let box = element.box
        return "\"\(element.text)\" — center=(\(Int(element.center.x)), \(Int(element.center.y))) box=(\(Int(box.minX)),\(Int(box.minY)),\(Int(box.width))x\(Int(box.height))) conf=\(String(format: "%.2f", element.confidence))"
    }
    return lines.joined(separator: "\n")
}
