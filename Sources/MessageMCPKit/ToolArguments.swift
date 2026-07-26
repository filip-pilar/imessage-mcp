import Foundation

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

func optionalStringAllowEmpty(_ args: [String: Any], _ key: String) -> String? {
    args[key] as? String
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
