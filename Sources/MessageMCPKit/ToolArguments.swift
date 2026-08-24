import Foundation
import CoreFoundation

func rejectUnknownKeys(_ args: [String: Any], allowed: Set<String>) throws {
    let unknown = Set(args.keys).subtracting(allowed).sorted()
    guard unknown.isEmpty else {
        throw ToolServiceError.invalid(
            "Unexpected argument\(unknown.count == 1 ? "" : "s"): \(unknown.joined(separator: ", "))."
        )
    }
}

func strictRequiredString(_ args: [String: Any], _ key: String) throws -> String {
    guard let raw = args[key] else {
        throw ToolServiceError.invalid("\(key) is required.")
    }
    guard let value = raw as? String else {
        throw ToolServiceError.invalid("\(key) must be a string.")
    }
    guard !value.isEmpty else {
        throw ToolServiceError.invalid("\(key) must not be empty.")
    }
    return value
}

func strictOptionalString(
    _ args: [String: Any],
    _ key: String,
    allowEmpty: Bool = false
) throws -> String? {
    guard let raw = args[key] else { return nil }
    guard let value = raw as? String else {
        throw ToolServiceError.invalid("\(key) must be a string.")
    }
    if !allowEmpty, value.isEmpty {
        throw ToolServiceError.invalid("\(key) must not be empty.")
    }
    return value
}

func strictBoolean(
    _ args: [String: Any],
    _ key: String,
    default defaultValue: Bool
) throws -> Bool {
    guard let raw = args[key] else { return defaultValue }
    guard let number = raw as? NSNumber,
        CFGetTypeID(number) == CFBooleanGetTypeID()
    else {
        throw ToolServiceError.invalid("\(key) must be a Boolean.")
    }
    return number.boolValue
}

func strictInt64(_ args: [String: Any], _ key: String, minimum: Int64) throws -> Int64 {
    guard let raw = args[key] else {
        throw ToolServiceError.invalid("\(key) is required.")
    }
    guard let number = raw as? NSNumber,
        CFGetTypeID(number) != CFBooleanGetTypeID(),
        isIntegerNumber(number),
        let value = Int64(number.stringValue),
        value >= minimum
    else {
        throw ToolServiceError.invalid("\(key) must be an integer of at least \(minimum).")
    }
    return value
}

func strictOptionalInt64(
    _ args: [String: Any],
    _ key: String,
    minimum: Int64
) throws -> Int64? {
    guard args[key] != nil else { return nil }
    return try strictInt64(args, key, minimum: minimum)
}

private func isIntegerNumber(_ number: NSNumber) -> Bool {
    switch String(cString: number.objCType) {
    case "c", "C", "s", "S", "i", "I", "l", "L", "q", "Q":
        return true
    default:
        return false
    }
}

func requiredString(_ args: [String: Any], _ key: String) throws -> String {
    guard let value = args[key] as? String,
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
        throw ToolServiceError.invalid("\(key) is required.")
    }
    return value
}

func optionalString(_ args: [String: Any], _ key: String) -> String? {
    guard let value = args[key] as? String else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : value
}

func bool(_ args: [String: Any], _ key: String, default defaultValue: Bool) -> Bool {
    args[key] as? Bool ?? defaultValue
}

func int(
    _ args: [String: Any],
    _ key: String,
    default defaultValue: Int,
    range: ClosedRange<Int>
) throws -> Int {
    guard let raw = args[key] else { return defaultValue }
    guard let value = (raw as? NSNumber)?.intValue, range.contains(value) else {
        throw ToolServiceError.invalid(
            "\(key) must be between \(range.lowerBound) and \(range.upperBound)."
        )
    }
    return value
}

func int64(_ args: [String: Any], _ key: String, minimum: Int64) throws -> Int64 {
    guard let value = optionalInt64(args, key), value >= minimum else {
        throw ToolServiceError.invalid("\(key) must be at least \(minimum).")
    }
    return value
}

func optionalInt64(_ args: [String: Any], _ key: String) -> Int64? {
    (args[key] as? NSNumber)?.int64Value
}

func enumValue(
    _ args: [String: Any],
    _ key: String,
    default defaultValue: String? = nil,
    allowed: [String]
) throws -> String {
    if args[key] == nil, let defaultValue { return defaultValue }
    guard let value = args[key] as? String, allowed.contains(value) else {
        throw ToolServiceError.invalid(
            "\(key) must be one of: \(allowed.joined(separator: ", "))."
        )
    }
    return value
}
