import Foundation
import Testing
@testable import MessageMCPKit

@Suite("Attachment read authority")
struct AttachmentReadAuthorityTests {
    @Test("only Messages attachments and imsg conversions are readable")
    func dedicatedRootsOnly() throws {
        let env = try TestEnvironment()
        let fakeHome = env.directory.appendingPathComponent("home", isDirectory: true)
        let roots = ToolService.attachmentReadRoots(
            homeDirectory: fakeHome
        )
        let service = env.service(runner: FakeRunner())

        let messagesImage = roots[0].appendingPathComponent("message.png")
        let convertedImage = roots[1].appendingPathComponent("converted.png")
        let appSupportImage = fakeHome.appendingPathComponent(
            "Library/Application Support/iMessage MCP/private.png"
        )
        let unrelatedCacheImage = fakeHome.appendingPathComponent(
            "Library/Caches/another-app/private.png"
        )

        for url in [messagesImage, convertedImage, appSupportImage, unrelatedCacheImage] {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data([0x89, 0x50, 0x4E, 0x47]).write(to: url)
        }

        #expect(try !service.readAttachment(
            ["path": messagesImage.path],
            allowedRoots: roots
        ).isError)
        #expect(try !service.readAttachment(
            ["path": convertedImage.path],
            allowedRoots: roots
        ).isError)
        #expect(throws: ToolServiceError.self) {
            try service.readAttachment(
                ["path": appSupportImage.path],
                allowedRoots: roots
            )
        }
        #expect(throws: ToolServiceError.self) {
            try service.readAttachment(
                ["path": unrelatedCacheImage.path],
                allowedRoots: roots
            )
        }
    }

    @Test("canonical path checks reject symlinks that leave an allowed root")
    func symlinkEscape() throws {
        let env = try TestEnvironment()
        let allowedRoot = env.directory.appendingPathComponent("allowed", isDirectory: true)
        let outsideFile = env.directory.appendingPathComponent("outside.png")
        let link = allowedRoot.appendingPathComponent("escape.png")
        try FileManager.default.createDirectory(
            at: allowedRoot,
            withIntermediateDirectories: true
        )
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: outsideFile)
        try FileManager.default.createSymbolicLink(
            atPath: link.path,
            withDestinationPath: outsideFile.path
        )

        let service = env.service(runner: FakeRunner())
        #expect(throws: ToolServiceError.self) {
            try service.readAttachment(["path": link.path], allowedRoots: [allowedRoot])
        }
    }

    @Test("converted attachment root cannot be replaced by a symlink")
    func convertedRootSymlinkRejected() throws {
        let env = try TestEnvironment()
        let fakeHome = env.directory.appendingPathComponent("home", isDirectory: true)
        let roots = ToolService.attachmentReadRoots(homeDirectory: fakeHome)
        let convertedRoot = roots[1]
        let outside = env.directory.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(
            at: convertedRoot.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let outsideImage = outside.appendingPathComponent("converted.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: outsideImage)
        try FileManager.default.createSymbolicLink(
            atPath: convertedRoot.path,
            withDestinationPath: outside.path
        )

        let service = env.service(runner: FakeRunner())
        #expect(throws: ToolServiceError.self) {
            try service.readAttachment(
                ["path": convertedRoot.appendingPathComponent("converted.png").path],
                allowedRoots: roots
            )
        }
    }

    @Test("attachment content comes from the descriptor that was validated")
    func descriptorPinsValidatedFile() throws {
        let env = try TestEnvironment()
        let root = env.directory.appendingPathComponent("attachments", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let image = root.appendingPathComponent("image.png")
        let original = Data([0x89, 0x50, 0x4E, 0x47])
        let replacement = Data([0x47, 0x49, 0x46, 0x38])
        try original.write(to: image)

        let result = try env.service(runner: FakeRunner()).readAttachment(
            ["path": image.path],
            allowedRoots: [root]
        ) {
            let moved = root.appendingPathComponent("original.png")
            try FileManager.default.moveItem(at: image, to: moved)
            try replacement.write(to: image)
        }

        let imageBlock = result.content.first?.value as? [String: Any]
        let encoded = imageBlock?["data"] as? String
        #expect(encoded.flatMap { Data(base64Encoded: $0) } == original)
    }

    @Test("attachment growth after stat is rejected by the bounded descriptor read")
    func descriptorReadRemainsBounded() throws {
        let env = try TestEnvironment()
        let root = env.directory.appendingPathComponent("attachments", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let image = root.appendingPathComponent("image.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: image)

        #expect(throws: ToolServiceError.self) {
            try env.service(runner: FakeRunner()).readAttachment(
                ["path": image.path],
                allowedRoots: [root]
            ) {
                let handle = try FileHandle(forWritingTo: image)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(repeating: 0x41, count: 20 * 1_024 * 1_024))
            }
        }
    }

    @Test("read activity does not retain addresses or attachment filenames")
    func redactedActivity() throws {
        let env = try TestEnvironment()
        let service = env.service(runner: FakeRunner())
        let address = "private-person@example.invalid"
        _ = service.call(name: "lookup_handle", arguments: ["address": address])

        let allowedRoot = env.directory.appendingPathComponent("attachments", isDirectory: true)
        let sensitiveFilename = "private-medical-scan.png"
        let image = allowedRoot.appendingPathComponent(sensitiveFilename)
        try FileManager.default.createDirectory(
            at: allowedRoot,
            withIntermediateDirectories: true
        )
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: image)
        _ = try service.readAttachment(["path": image.path], allowedRoots: [allowedRoot])

        let details = env.activity.recent.map(\.detail).joined(separator: "\n")
        #expect(!details.contains(address))
        #expect(!details.contains(sensitiveFilename))
        #expect(env.activity.recent.allSatisfy { $0.title == "Read operation" })
        #expect(details == "Request details redacted.\nRequest details redacted.")
    }

    @Test("conversion authority is the dedicated user-cache root")
    func conversionRootIsDeterministic() throws {
        let env = try TestEnvironment()
        let fakeHome = env.directory.appendingPathComponent("home", isDirectory: true)

        let roots = ToolService.attachmentReadRoots(homeDirectory: fakeHome)

        let expected = [
            fakeHome.appendingPathComponent(
                "Library/Messages/Attachments",
                isDirectory: true
            ),
            fakeHome.appendingPathComponent(
                "Library/Caches/imsg/converted-attachments",
                isDirectory: true
            ),
        ]
        #expect(roots.map(\.path) == expected.map(\.path))
    }
}
