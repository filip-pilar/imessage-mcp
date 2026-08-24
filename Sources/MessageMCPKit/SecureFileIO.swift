import Darwin
import Foundation

struct SecureFileIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
}

struct SecureFileMetadata: Equatable, Sendable {
    let identity: SecureFileIdentity
    let byteCount: Int
}

final class SecureFileDescriptor {
    let rawValue: Int32

    init(_ rawValue: Int32) {
        self.rawValue = rawValue
    }

    deinit {
        Darwin.close(rawValue)
    }
}

enum SecureFileIOError: LocalizedError {
    case invalidPath
    case openFailed(String, Int32)
    case notRegular
    case tooLarge
    case cancelled
    case readFailed
    case writeFailed
    case cleanupFailed

    var errorDescription: String? {
        switch self {
        case .invalidPath: return "The file path is outside the allowed directory."
        case .openFailed: return "The file could not be opened without following symbolic links."
        case .notRegular: return "The file is not a regular file."
        case .tooLarge: return "The file exceeds the configured size limit."
        case .cancelled: return "The attachment copy was cancelled."
        case .readFailed: return "The file could not be read."
        case .writeFailed: return "The private attachment copy could not be created."
        case .cleanupFailed: return "The private attachment copy could not be removed."
        }
    }
}

enum SecureFileIO {
    static func canonicalExistingURL(_ url: URL) throws -> URL {
        guard let resolved = url.path.withCString({ Darwin.realpath($0, nil) }) else {
            throw SecureFileIOError.openFailed(url.lastPathComponent, errno)
        }
        defer { Darwin.free(resolved) }
        return URL(
            fileURLWithPath: String(cString: resolved),
            isDirectory: url.hasDirectoryPath
        )
    }

    static func openFile(at url: URL, beneath root: URL) throws -> SecureFileDescriptor {
        let fileComponents = normalizedComponents(for: url)
        let rootComponents = normalizedComponents(for: root)
        guard fileComponents.count > rootComponents.count,
            Array(fileComponents.prefix(rootComponents.count)) == rootComponents
        else {
            throw SecureFileIOError.invalidPath
        }

        var directoryFD = try openDirectory(components: rootComponents)
        defer { Darwin.close(directoryFD) }

        let relativeComponents = fileComponents.dropFirst(rootComponents.count)
        for component in relativeComponents.dropLast() {
            let next = Darwin.openat(
                directoryFD,
                component,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            guard next >= 0 else { throw SecureFileIOError.openFailed(component, errno) }
            Darwin.close(directoryFD)
            directoryFD = next
        }

        guard let filename = relativeComponents.last else {
            throw SecureFileIOError.invalidPath
        }
        let fileFD = Darwin.openat(
            directoryFD,
            filename,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard fileFD >= 0 else { throw SecureFileIOError.openFailed(filename, errno) }
        return SecureFileDescriptor(fileFD)
    }

    static func openAbsoluteFile(at url: URL) throws -> SecureFileDescriptor {
        let components = normalizedComponents(for: url)
        guard let filename = components.last else { throw SecureFileIOError.invalidPath }
        let directoryFD = try openDirectory(components: Array(components.dropLast()))
        defer { Darwin.close(directoryFD) }
        let fileFD = Darwin.openat(
            directoryFD,
            filename,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard fileFD >= 0 else { throw SecureFileIOError.openFailed(filename, errno) }
        return SecureFileDescriptor(fileFD)
    }

    static func createFile(
        named filename: String,
        in directory: URL
    ) throws -> SecureFileDescriptor {
        guard !filename.isEmpty, !filename.contains("/") else {
            throw SecureFileIOError.invalidPath
        }
        let directoryFD = try openDirectory(components: normalizedComponents(for: directory))
        defer { Darwin.close(directoryFD) }
        let fileFD = Darwin.openat(
            directoryFD,
            filename,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o400)
        )
        guard fileFD >= 0 else { throw SecureFileIOError.writeFailed }
        return SecureFileDescriptor(fileFD)
    }

    static func createDirectory(
        named name: String,
        in directory: URL
    ) throws -> URL {
        guard !name.isEmpty, !name.contains("/") else {
            throw SecureFileIOError.invalidPath
        }
        let directoryFD = try openDirectory(components: normalizedComponents(for: directory))
        defer { Darwin.close(directoryFD) }
        guard Darwin.mkdirat(directoryFD, name, mode_t(0o700)) == 0 else {
            throw SecureFileIOError.writeFailed
        }
        return directory.appendingPathComponent(name, isDirectory: true)
    }

    static func regularFileMetadata(
        for descriptor: SecureFileDescriptor,
        maximumBytes: Int
    ) throws -> SecureFileMetadata {
        var info = stat()
        guard Darwin.fstat(descriptor.rawValue, &info) == 0 else {
            throw SecureFileIOError.openFailed("fstat", errno)
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw SecureFileIOError.notRegular
        }
        guard info.st_size >= 0,
            info.st_size <= off_t(maximumBytes),
            let byteCount = Int(exactly: info.st_size)
        else {
            throw SecureFileIOError.tooLarge
        }
        return SecureFileMetadata(
            identity: SecureFileIdentity(
                device: UInt64(info.st_dev),
                inode: UInt64(info.st_ino)
            ),
            byteCount: byteCount
        )
    }

    static func read(
        from descriptor: SecureFileDescriptor,
        maximumBytes: Int
    ) throws -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let remaining = maximumBytes - result.count
            let requested = min(buffer.count, max(1, remaining + 1))
            let count = Darwin.read(descriptor.rawValue, &buffer, requested)
            if count == 0 { return result }
            if count < 0 {
                if errno == EINTR { continue }
                throw SecureFileIOError.readFailed
            }
            guard result.count + count <= maximumBytes else {
                throw SecureFileIOError.tooLarge
            }
            result.append(buffer, count: count)
        }
    }

    static func copy(
        from source: SecureFileDescriptor,
        to destination: SecureFileDescriptor,
        maximumBytes: Int,
        cancellation: ToolCallCancellation? = nil,
        didCopyChunk: (() -> Void)? = nil
    ) throws -> Int {
        var total = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            guard cancellation?.isCancelled != true else {
                throw SecureFileIOError.cancelled
            }
            let count = Darwin.read(source.rawValue, &buffer, buffer.count)
            if count == 0 { return total }
            if count < 0 {
                if errno == EINTR { continue }
                throw SecureFileIOError.readFailed
            }
            guard total + count <= maximumBytes else {
                throw SecureFileIOError.tooLarge
            }
            var written = 0
            while written < count {
                guard cancellation?.isCancelled != true else {
                    throw SecureFileIOError.cancelled
                }
                let output = buffer.withUnsafeBytes { bytes in
                    Darwin.write(
                        destination.rawValue,
                        bytes.baseAddress!.advanced(by: written),
                        count - written
                    )
                }
                if output < 0 {
                    if errno == EINTR { continue }
                    throw SecureFileIOError.writeFailed
                }
                guard output > 0 else { throw SecureFileIOError.writeFailed }
                written += output
            }
            total += count
            didCopyChunk?()
        }
    }

    static func sweepStagingDirectory(
        at root: URL,
        excludingDirectoryNames: Set<String> = []
    ) throws -> Int {
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let rootFD = try openDirectory(components: normalizedComponents(for: root))
        defer { Darwin.close(rootFD) }
        guard Darwin.fchmod(rootFD, mode_t(0o700)) == 0 else {
            throw SecureFileIOError.cleanupFailed
        }

        var removed = 0
        for name in try directoryEntryNames(in: rootFD) {
            guard UUID(uuidString: name) != nil,
                !excludingDirectoryNames.contains(name)
            else { continue }
            try removeStagingDirectory(named: name, beneath: rootFD)
            removed += 1
        }
        return removed
    }

    static func removeStagedFile(
        _ file: URL,
        directory: URL,
        beneath root: URL
    ) throws {
        let standardizedRoot = standardizedDirectoryURL(root)
        let standardizedDirectory = standardizedDirectoryURL(directory)
        guard standardizedDirectory.deletingLastPathComponent() == standardizedRoot,
            UUID(uuidString: standardizedDirectory.lastPathComponent) != nil,
            file.standardizedFileURL.deletingLastPathComponent() == standardizedDirectory,
            !file.lastPathComponent.isEmpty,
            !file.lastPathComponent.contains("/")
        else {
            throw SecureFileIOError.invalidPath
        }

        let rootFD = try openDirectory(components: normalizedComponents(for: standardizedRoot))
        defer { Darwin.close(rootFD) }
        let directoryName = standardizedDirectory.lastPathComponent
        let directoryFD = Darwin.openat(
            rootFD,
            directoryName,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        if directoryFD < 0 {
            if errno == ENOENT { return }
            throw SecureFileIOError.cleanupFailed
        }
        defer { Darwin.close(directoryFD) }

        if Darwin.unlinkat(directoryFD, file.lastPathComponent, 0) != 0,
            errno != ENOENT
        {
            throw SecureFileIOError.cleanupFailed
        }
        if Darwin.unlinkat(rootFD, directoryName, AT_REMOVEDIR) != 0,
            errno != ENOENT
        {
            throw SecureFileIOError.cleanupFailed
        }
    }

    private static func normalizedComponents(for url: URL) -> [String] {
        let path = url.path
        let canonicalPath =
            (path == "/var" || path.hasPrefix("/var/"))
            ? "/private" + path
            : path
        return URL(fileURLWithPath: canonicalPath).pathComponents.filter { $0 != "/" }
    }

    private static func standardizedDirectoryURL(_ url: URL) -> URL {
        URL(
            fileURLWithPath: NSString(string: url.path).standardizingPath,
            isDirectory: true
        )
    }

    private static func directoryEntryNames(in fileDescriptor: Int32) throws -> [String] {
        let duplicate = Darwin.dup(fileDescriptor)
        guard duplicate >= 0 else { throw SecureFileIOError.cleanupFailed }
        guard let directory = Darwin.fdopendir(duplicate) else {
            Darwin.close(duplicate)
            throw SecureFileIOError.cleanupFailed
        }
        defer { Darwin.closedir(directory) }

        var result: [String] = []
        errno = 0
        while let entry = Darwin.readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(
                    to: CChar.self,
                    capacity: Int(MAXNAMLEN) + 1
                ) { String(cString: $0) }
            }
            if name != "." && name != ".." {
                result.append(name)
            }
            errno = 0
        }
        guard errno == 0 else { throw SecureFileIOError.cleanupFailed }
        return result
    }

    private static func removeStagingDirectory(
        named name: String,
        beneath rootFD: Int32
    ) throws {
        let directoryFD = Darwin.openat(
            rootFD,
            name,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        if directoryFD < 0 {
            if errno == ENOENT { return }
            if Darwin.unlinkat(rootFD, name, 0) == 0 || errno == ENOENT { return }
            throw SecureFileIOError.cleanupFailed
        }
        defer { Darwin.close(directoryFD) }

        for entry in try directoryEntryNames(in: directoryFD) {
            if Darwin.unlinkat(directoryFD, entry, 0) != 0,
                errno != ENOENT
            {
                throw SecureFileIOError.cleanupFailed
            }
        }
        if Darwin.unlinkat(rootFD, name, AT_REMOVEDIR) != 0,
            errno != ENOENT
        {
            throw SecureFileIOError.cleanupFailed
        }
    }

    private static func openDirectory(components: [String]) throws -> Int32 {
        var directoryFD = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directoryFD >= 0 else { throw SecureFileIOError.openFailed("/", errno) }
        do {
            for component in components {
                let next = Darwin.openat(
                    directoryFD,
                    component,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
                guard next >= 0 else { throw SecureFileIOError.openFailed(component, errno) }
                Darwin.close(directoryFD)
                directoryFD = next
            }
            return directoryFD
        } catch {
            Darwin.close(directoryFD)
            throw error
        }
    }
}

final class AttachmentStagingManager: @unchecked Sendable {
    let root: URL
    private let lock = NSLock()
    private var activeDirectoryNames: Set<String> = []
    private var needsSweep = true

    init(root: URL) {
        self.root = URL(
            fileURLWithPath: NSString(string: root.path).standardizingPath,
            isDirectory: true
        )
    }

    var cleanupPending: Bool {
        lock.withLock { needsSweep }
    }

    func prepare() throws {
        try lock.withLock { try sweepLocked() }
    }

    func makePrivateDirectory() throws -> URL {
        try lock.withLock {
            if needsSweep { try sweepLocked() }
            let name = UUID().uuidString
            let directory = try SecureFileIO.createDirectory(named: name, in: root)
            activeDirectoryNames.insert(name)
            return directory
        }
    }

    func finish(file: URL, directory: URL) -> Bool {
        lock.withLock {
            let name = directory.lastPathComponent
            defer { activeDirectoryNames.remove(name) }
            do {
                try SecureFileIO.removeStagedFile(file, directory: directory, beneath: root)
                return true
            } catch {
                needsSweep = true
                return false
            }
        }
    }

    private func sweepLocked() throws {
        do {
            _ = try SecureFileIO.sweepStagingDirectory(
                at: root,
                excludingDirectoryNames: activeDirectoryNames
            )
            needsSweep = false
        } catch {
            needsSweep = true
            throw error
        }
    }
}
