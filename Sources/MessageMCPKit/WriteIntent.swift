import Darwin
import Foundation

enum MessageTarget: Equatable, Sendable {
    case chat(Int64)
    case address(String)

    var canonicalDescription: String {
        switch self {
        case .chat(let chatID):
            return "chat_id: \(chatID)"
        case .address(let address):
            return address
        }
    }
}

enum MessageDeliveryService: String, Sendable {
    case auto
    case imessage
    case sms
}

struct CanonicalAttachment: Equatable, Sendable {
    let sourceURL: URL
    let stagedURL: URL
    let stagingDirectoryURL: URL
    let byteCount: Int
    let typeIdentifier: String
    let identity: SecureFileIdentity
}

struct SendMessageIntent: Equatable, Sendable {
    let target: MessageTarget
    let text: String?
    let attachment: CanonicalAttachment?
    let service: MessageDeliveryService
    let preventsSMSFallback: Bool
}

struct ReactionIntent: Equatable, Sendable {
    let chatID: Int64
    let reaction: String
    let expectedMessageGUID: String
}

extension ToolService {
    func normalizeSendIntent(
        _ args: [String: Any],
        maximumAttachmentBytes: Int,
        cancellation: ToolCallCancellation? = nil
    ) throws -> SendMessageIntent {
        try rejectUnknownKeys(
            args,
            allowed: ["chat_id", "to", "text", "file", "service", "no_sms_fallback"]
        )

        let chatID = try strictOptionalInt64(args, "chat_id", minimum: 1)
        let rawRecipient = try strictOptionalString(args, "to")
        guard (chatID == nil) != (rawRecipient == nil) else {
            throw ToolServiceError.invalid("Provide exactly one of chat_id or to.")
        }

        let target: MessageTarget
        if let chatID {
            target = .chat(chatID)
        } else {
            target = .address(try canonicalMessageAddress(rawRecipient ?? ""))
        }

        let text = try strictOptionalString(args, "text", allowEmpty: true)
        let file = try strictOptionalString(args, "file")
        guard text != nil || file != nil else {
            throw ToolServiceError.invalid("Provide text, file, or both.")
        }

        let rawService = try strictOptionalString(args, "service") ?? "auto"
        guard let service = MessageDeliveryService(rawValue: rawService) else {
            throw ToolServiceError.invalid("service must be one of: auto, imessage, sms.")
        }
        let preventsSMSFallback = try strictBoolean(
            args,
            "no_sms_fallback",
            default: false
        )
        guard service != .sms || !preventsSMSFallback else {
            throw ToolServiceError.invalid(
                "no_sms_fallback cannot be true when service is sms."
            )
        }

        let attachment = try file.map {
            try canonicalOutboundAttachment(
                at: $0,
                maximumBytes: maximumAttachmentBytes,
                cancellation: cancellation
            )
        }
        return SendMessageIntent(
            target: target,
            text: text,
            attachment: attachment,
            service: service,
            preventsSMSFallback: preventsSMSFallback
        )
    }

    func normalizeReactionIntent(_ args: [String: Any]) throws -> ReactionIntent {
        try rejectUnknownKeys(
            args,
            allowed: ["chat_id", "reaction", "expected_message_guid"]
        )
        let chatID = try strictInt64(args, "chat_id", minimum: 1)
        let reaction = try strictRequiredString(args, "reaction")
        guard ["love", "like", "dislike", "laugh", "emphasis", "question"]
            .contains(reaction)
        else {
            throw ToolServiceError.invalid(
                "reaction must be one of: love, like, dislike, laugh, emphasis, question."
            )
        }
        let expectedGUID = try strictRequiredString(args, "expected_message_guid")
        guard expectedGUID == expectedGUID.trimmingCharacters(in: .whitespacesAndNewlines),
            !expectedGUID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else {
            throw ToolServiceError.invalid(
                "expected_message_guid must be an exact message identifier."
            )
        }
        return ReactionIntent(
            chatID: chatID,
            reaction: reaction,
            expectedMessageGUID: expectedGUID
        )
    }

    func canonicalOutboundAttachment(
        at path: String,
        maximumBytes: Int,
        cancellation: ToolCallCancellation? = nil,
        beforeCopy: (() throws -> Void)? = nil,
        didCopyChunk: (() -> Void)? = nil
    ) throws -> CanonicalAttachment {
        guard cancellation?.isCancelled != true else {
            throw ToolServiceError.disabled("The request was cancelled by the MCP client.")
        }
        guard NSString(string: path).isAbsolutePath else {
            throw ToolServiceError.invalid("Attachment path must be absolute.")
        }
        let sourceURL: URL
        do {
            sourceURL = try SecureFileIO.canonicalExistingURL(
                URL(fileURLWithPath: path).standardizedFileURL
            )
        } catch {
            throw ToolServiceError.invalid("Attachment must be an existing regular file.")
        }
        let source: SecureFileDescriptor
        do {
            source = try SecureFileIO.openAbsoluteFile(at: sourceURL)
            _ = try SecureFileIO.regularFileMetadata(
                for: source,
                maximumBytes: maximumBytes
            )
        } catch SecureFileIOError.tooLarge {
            throw ToolServiceError.invalid("Attachment exceeds the configured size limit.")
        } catch {
            throw ToolServiceError.invalid("Attachment must be an existing regular file.")
        }

        guard cancellation?.isCancelled != true else {
            throw ToolServiceError.disabled("The request was cancelled by the MCP client.")
        }
        let privateDirectory: URL
        do {
            privateDirectory = try attachmentStaging.makePrivateDirectory()
        } catch {
            activity.append(kind: .error, succeeded: false)
            throw ToolServiceError.invalid("A private attachment copy could not be prepared.")
        }
        let filename = sourceURL.lastPathComponent
        let stagedURL = privateDirectory.appendingPathComponent(filename)
        let destination: SecureFileDescriptor
        do {
            destination = try SecureFileIO.createFile(
                named: filename,
                in: privateDirectory
            )
        } catch {
            if !attachmentStaging.finish(file: stagedURL, directory: privateDirectory) {
                activity.append(kind: .error, succeeded: false)
            }
            throw ToolServiceError.invalid("A private attachment copy could not be prepared.")
        }
        var shouldRemoveStagedFile = true
        defer {
            if shouldRemoveStagedFile {
                if !attachmentStaging.finish(file: stagedURL, directory: privateDirectory) {
                    activity.append(kind: .error, succeeded: false)
                }
            }
        }

        do {
            try beforeCopy?()
            let copiedBytes = try SecureFileIO.copy(
                from: source,
                to: destination,
                maximumBytes: maximumBytes,
                cancellation: cancellation,
                didCopyChunk: didCopyChunk
            )
            guard cancellation?.isCancelled != true else {
                throw SecureFileIOError.cancelled
            }
            guard Darwin.fchmod(destination.rawValue, mode_t(0o400)) == 0 else {
                throw SecureFileIOError.writeFailed
            }
            let stagedMetadata = try SecureFileIO.regularFileMetadata(
                for: destination,
                maximumBytes: maximumBytes
            )
            shouldRemoveStagedFile = false
            return CanonicalAttachment(
                sourceURL: sourceURL,
                stagedURL: stagedURL,
                stagingDirectoryURL: privateDirectory,
                byteCount: copiedBytes,
                typeIdentifier: contentTypeForFilename(sourceURL).identifier,
                identity: stagedMetadata.identity
            )
        } catch SecureFileIOError.tooLarge {
            throw ToolServiceError.invalid("Attachment exceeds the configured size limit.")
        } catch SecureFileIOError.cancelled {
            throw ToolServiceError.disabled("The request was cancelled by the MCP client.")
        } catch {
            throw ToolServiceError.invalid("A private attachment copy could not be prepared.")
        }
    }

    func revalidateAttachment(
        _ expected: CanonicalAttachment,
        maximumBytes: Int
    ) throws {
        let descriptor: SecureFileDescriptor
        let metadata: SecureFileMetadata
        do {
            descriptor = try SecureFileIO.openAbsoluteFile(at: expected.stagedURL)
            metadata = try SecureFileIO.regularFileMetadata(
                for: descriptor,
                maximumBytes: maximumBytes
            )
        } catch {
            throw ToolServiceError.invalid(
                "The private attachment copy changed after the write was prepared."
            )
        }
        guard metadata.identity == expected.identity,
            metadata.byteCount == expected.byteCount,
            contentTypeForFilename(expected.stagedURL).identifier == expected.typeIdentifier
        else {
            throw ToolServiceError.invalid(
                "The private attachment copy changed after the write was prepared."
            )
        }
    }
}

private func canonicalMessageAddress(_ value: String) throws -> String {
    guard value == value.trimmingCharacters(in: .whitespacesAndNewlines) else {
        throw ToolServiceError.invalid(
            "to must be a canonical E.164 phone number or email address."
        )
    }
    if isCanonicalE164(value) { return value }
    if let email = canonicalEmailAddress(value) { return email }
    throw ToolServiceError.invalid(
        "to must be a canonical E.164 phone number or email address; contact names and local phone numbers are not accepted."
    )
}

private func isCanonicalE164(_ value: String) -> Bool {
    let scalars = Array(value.unicodeScalars)
    guard (3...16).contains(scalars.count), scalars.first == "+" else { return false }
    let digits = scalars.dropFirst()
    guard digits.first != "0" else { return false }
    return digits.allSatisfy { (48...57).contains($0.value) }
}

private func canonicalEmailAddress(_ value: String) -> String? {
    let parts = value.split(separator: "@", omittingEmptySubsequences: false)
    guard parts.count == 2 else { return nil }
    let local = String(parts[0])
    let domain = String(parts[1])
    guard !local.isEmpty, local.utf8.count <= 64,
        !local.hasPrefix("."), !local.hasSuffix("."), !local.contains("..")
    else { return nil }

    let allowedLocal = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.!#$%&'*+-/=?^_`{|}~"
    )
    guard local.unicodeScalars.allSatisfy({
        $0.value < 128 && allowedLocal.contains($0)
    }) else { return nil }

    let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
    guard labels.count >= 2, domain.utf8.count <= 253 else { return nil }
    for label in labels {
        guard !label.isEmpty, label.utf8.count <= 63,
            label.first != "-", label.last != "-",
            label.unicodeScalars.allSatisfy({
                $0.value < 128
                    && ((48...57).contains($0.value)
                        || (65...90).contains($0.value)
                        || (97...122).contains($0.value)
                        || $0 == "-")
            })
        else { return nil }
    }
    return local + "@" + domain.lowercased()
}
