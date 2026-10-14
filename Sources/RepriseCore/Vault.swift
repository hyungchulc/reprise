import CryptoKit
import Darwin
import Foundation
import Security

/// Library encryption keys. One random 256-bit master key lives in the login keychain; the
/// database, media files and MCP consent each use their own key derived from it.
public struct VaultKeys: @unchecked Sendable {
    let database: SymmetricKey
    let media: SymmetricKey
    let consent: SymmetricKey

    public init(master: SymmetricKey) {
        func derive(_ purpose: String) -> SymmetricKey {
            HKDF<SHA256>.deriveKey(inputKeyMaterial: master, salt: Data("Reprise vault".utf8), info: Data(purpose.utf8), outputByteCount: 32)
        }
        database = derive("database"); media = derive("media"); consent = derive("mcp consent")
    }

    /// A key that exists only in this process, for tests and throwaway libraries.
    public static func ephemeral() -> VaultKeys { VaultKeys(master: SymmetricKey(size: .bits256)) }

    public var cipher: VaultCipher { VaultCipher(key: media) }

    /// SQLCipher raw-key form, so opening the database runs no password derivation.
    var databaseKey: String {
        "x'" + database.withUnsafeBytes { $0.map { String(format: "%02x", $0) }.joined() } + "'"
    }

    func consentSignature(_ message: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: consent))
    }

    func isValidConsent(_ signature: Data, for message: String) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(signature, authenticating: Data(message.utf8), using: consent)
    }
}

/// Sealed library files: a 32-byte header, then the content in AES-GCM chunks. Every chunk is
/// authenticated with the header, its position and whether it is the last, so any byte range
/// decrypts on its own while truncated, reordered or altered files fail. Each file derives its
/// own key from a random salt, which keeps counter nonces unique.
public struct VaultCipher: @unchecked Sendable {
    static let magic = Array("RPV1".utf8)
    static let headerSize = 32
    static let tagSize = 16
    static let chunkSize = 1 << 20
    let key: SymmetricKey

    public enum Failure: LocalizedError {
        case damaged
        case tooLarge
        public var errorDescription: String? {
            switch self {
            case .damaged: return "A library file is damaged or was sealed with a different key."
            case .tooLarge: return "A library file is larger than expected."
            }
        }
    }

    public static func isSealed<D: DataProtocol>(_ prefix: D) -> Bool { prefix.prefix(4).elementsEqual(magic) }

    public static func isSealed(fileAt url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 4)).map { isSealed($0) } ?? false
    }

    public func seal(_ plaintext: Data) throws -> Data {
        let (header, fileKey) = newFile()
        let count = max(1, (plaintext.count + Self.chunkSize - 1) / Self.chunkSize)
        var output = header
        output.reserveCapacity(header.count + plaintext.count + count * Self.tagSize)
        for index in 0..<count {
            let start = plaintext.startIndex + index * Self.chunkSize
            let chunk = plaintext[start..<min(plaintext.endIndex, start + Self.chunkSize)]
            let box = try AES.GCM.seal(chunk, using: fileKey, nonce: Self.nonce(index, final: index == count - 1), authenticating: header)
            output.append(box.ciphertext); output.append(box.tag)
        }
        return output
    }

    public func open(_ sealed: Data) throws -> Data {
        let sealed = Data(sealed)
        let layout = try Layout(header: sealed.prefix(Self.headerSize), fileSize: Int64(sealed.count), cipher: self)
        var output = Data(capacity: Int(layout.length))
        for index in 0..<layout.chunks {
            let range = layout.fileRange(of: index)
            output.append(try layout.open(sealed.subdata(in: Int(range.lowerBound)..<Int(range.upperBound)), chunk: index))
        }
        return output
    }

    /// The content of a library file. Files written before encryption are returned as stored.
    public func contents(of url: URL, maxBytes: Int = 512 * 1024 * 1024) throws -> Data {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= maxBytes + Self.headerSize + Self.tagSize * (maxBytes / Self.chunkSize + 1) else { throw Failure.tooLarge }
        return Self.isSealed(data) ? try open(data) : data
    }

    /// Seals `data` beside `url`, then moves it into place, readable only by this account.
    public func write(_ data: Data, to url: URL) throws {
        let sealed = try seal(data)
        try Self.replace(url) { handle in try handle.write(contentsOf: sealed) }
    }

    /// Encrypts a file written before encryption in place. Returns false when it was already sealed.
    @discardableResult
    public func sealFile(at url: URL) throws -> Bool {
        let source = try FileHandle(forReadingFrom: url)
        defer { try? source.close() }
        guard let prefix = try source.read(upToCount: 4), !Self.isSealed(prefix) else { return false }
        try source.seek(toOffset: 0)
        try Self.replace(url) { handle in
            let writer = Writer(handle: handle, cipher: self)
            while let block = try source.read(upToCount: Self.chunkSize), !block.isEmpty { try writer.append(block) }
            try writer.finishSealing()
        }
        return true
    }

    /// Writes a sibling file with exclusive creation and mode 0600, syncs it, then renames it over
    /// `url` so readers see either the old or the new content.
    static func replace(_ url: URL, _ fill: (FileHandle) throws -> Void) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).sealing-\(UUID().uuidString)")
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try fill(handle)
            try handle.synchronize()
            try handle.close()
            guard Darwin.rename(temporary.path, url.path) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        } catch {
            try? handle.close()
            unlink(temporary.path)
            throw error
        }
    }

    fileprivate func newFile() -> (header: Data, key: SymmetricKey) {
        let salt = SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) }
        var header = Data(Self.magic)
        header.append(contentsOf: [1, 0, 0, 0])
        withUnsafeBytes(of: UInt32(Self.chunkSize).littleEndian) { header.append(contentsOf: $0) }
        header.append(contentsOf: [0, 0, 0, 0])
        header.append(salt)
        return (header, fileKey(salt: salt))
    }

    fileprivate func fileKey<D: DataProtocol>(salt: D) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: key, salt: Data(salt), info: Data("Reprise file".utf8), outputByteCount: 32)
    }

    fileprivate static func nonce(_ index: Int, final: Bool) -> AES.GCM.Nonce {
        var bytes = [UInt8](repeating: 0, count: 12)
        withUnsafeBytes(of: UInt64(index).bigEndian) { bytes.replaceSubrange(0..<8, with: $0) }
        bytes[11] = final ? 1 : 0
        return try! AES.GCM.Nonce(data: bytes)
    }

    /// Where each chunk of a sealed file lies, derived from the header and the file size.
    fileprivate struct Layout {
        let header: Data
        let key: SymmetricKey
        let chunkSize: Int
        let chunks: Int
        let length: Int64

        init<D: DataProtocol>(header bytes: D, fileSize: Int64, cipher: VaultCipher) throws {
            let header = Data(bytes)
            guard header.count == VaultCipher.headerSize, VaultCipher.isSealed(header), header[4] == 1 else { throw Failure.damaged }
            let size = header.withUnsafeBytes { Int($0.loadUnaligned(fromByteOffset: 8, as: UInt32.self).littleEndian) }
            guard size >= 4_096, size <= 1 << 26 else { throw Failure.damaged }
            let body = fileSize - Int64(VaultCipher.headerSize), stride = Int64(size + VaultCipher.tagSize)
            guard body >= Int64(VaultCipher.tagSize) else { throw Failure.damaged }
            let chunks = (body + stride - 1) / stride
            let last = body - (chunks - 1) * stride
            guard last >= Int64(VaultCipher.tagSize) else { throw Failure.damaged }
            self.header = header
            self.key = cipher.fileKey(salt: header[16..<32])
            self.chunkSize = size
            self.chunks = Int(chunks)
            self.length = (chunks - 1) * Int64(size) + last - Int64(VaultCipher.tagSize)
        }

        func fileRange(of index: Int) -> Range<Int64> {
            let start = Int64(VaultCipher.headerSize) + Int64(index) * Int64(chunkSize + VaultCipher.tagSize)
            let plain = min(Int64(chunkSize), length - Int64(index) * Int64(chunkSize))
            return start..<(start + plain + Int64(VaultCipher.tagSize))
        }

        func open(_ sealed: Data, chunk index: Int) throws -> Data {
            guard sealed.count >= VaultCipher.tagSize else { throw Failure.damaged }
            do {
                let box = try AES.GCM.SealedBox(nonce: VaultCipher.nonce(index, final: index == chunks - 1),
                                                ciphertext: sealed.prefix(sealed.count - VaultCipher.tagSize),
                                                tag: sealed.suffix(VaultCipher.tagSize))
                return try AES.GCM.open(box, using: key, authenticating: header)
            } catch { throw Failure.damaged }
        }
    }

    /// Seals a stream into a file as it arrives, such as an encoder's output segments.
    public final class Writer {
        private let handle: FileHandle
        private let path: String?
        private let header: Data
        private let key: SymmetricKey
        private var pending = Data()
        private var index = 0
        private var closed = false

        /// Creates `url` exclusively with mode 0600; `cancel()` removes it again.
        public init(creating url: URL, cipher: VaultCipher) throws {
            let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            path = url.path
            (header, key) = cipher.newFile()
            do { try handle.write(contentsOf: header) } catch { cancel(); throw error }
        }

        fileprivate init(handle: FileHandle, cipher: VaultCipher) {
            self.handle = handle
            path = nil
            (header, key) = cipher.newFile()
            try? handle.write(contentsOf: header)
        }

        public func append(_ data: Data) throws {
            pending.append(data)
            while pending.count > VaultCipher.chunkSize {
                try seal(pending.prefix(VaultCipher.chunkSize), final: false)
                pending = Data(pending.dropFirst(VaultCipher.chunkSize))
            }
        }

        /// Seals the last chunk and closes the file.
        public func finish() throws {
            try finishSealing()
            try handle.synchronize()
            try handle.close()
            closed = true
        }

        fileprivate func finishSealing() throws {
            try seal(pending, final: true)
            pending = Data()
        }

        public func cancel() {
            guard !closed else { return }
            closed = true
            try? handle.close()
            if let path { unlink(path) }
        }

        private func seal(_ chunk: Data, final: Bool) throws {
            let box = try AES.GCM.seal(chunk, using: key, nonce: VaultCipher.nonce(index, final: final), authenticating: header)
            try handle.write(contentsOf: box.ciphertext + box.tag)
            index += 1
        }
    }

    /// Random access to the plaintext of a sealed file, for decoders that read byte ranges.
    public final class Reader: @unchecked Sendable {
        public let length: Int64
        private let layout: Layout
        private let handle: FileHandle
        private let lock = NSLock()
        private var recent: [(index: Int, data: Data)] = []

        public init(url: URL, cipher: VaultCipher) throws {
            handle = try FileHandle(forReadingFrom: url)
            let header = try handle.read(upToCount: VaultCipher.headerSize) ?? Data()
            layout = try Layout(header: header, fileSize: Int64(try handle.seekToEnd()), cipher: cipher)
            length = layout.length
            // The final chunk proves the length: a file cut at a chunk boundary fails here.
            _ = try chunk(layout.chunks - 1)
        }

        deinit { try? handle.close() }

        public func read(offset: Int64, count: Int) throws -> Data {
            guard offset >= 0, count > 0, offset < length else { return Data() }
            let end = min(length, offset + Int64(count))
            var result = Data(capacity: Int(end - offset))
            var position = offset
            while position < end {
                let index = Int(position / Int64(layout.chunkSize))
                let plain = try chunk(index)
                let start = Int(position - Int64(index) * Int64(layout.chunkSize))
                let take = min(plain.count - start, Int(end - position))
                guard take > 0 else { throw Failure.damaged }
                result.append(plain[start..<(start + take)])
                position += Int64(take)
            }
            return result
        }

        private func chunk(_ index: Int) throws -> Data {
            lock.lock(); defer { lock.unlock() }
            if let hit = recent.firstIndex(where: { $0.index == index }) {
                let entry = recent.remove(at: hit); recent.append(entry); return entry.data
            }
            let range = layout.fileRange(of: index)
            try handle.seek(toOffset: UInt64(range.lowerBound))
            guard let sealed = try handle.read(upToCount: Int(range.count)), sealed.count == range.count else { throw Failure.damaged }
            let plain = try layout.open(sealed, chunk: index)
            recent.append((index, plain))
            if recent.count > 4 { recent.removeFirst() }
            return plain
        }
    }
}

/// The master key in the login keychain. Reprise and its MCP helper read it without asking;
/// for any other program macOS asks the person first.
public enum VaultKeychain {
    static let service = "local.aria.reprise.vault"
    static let label = "Reprise Vault Key"

    /// The usual library has one well-known item. A library elsewhere, such as a test copy, gets
    /// its own key, so it never shares or replaces the everyday one.
    static func account(for root: URL) -> String {
        func canonical(_ url: URL) -> String {
            let path = url.standardizedFileURL.path
            guard let resolved = realpath(path, nil) else { return path }
            defer { free(resolved) }
            return String(cString: resolved)
        }
        let path = canonical(root)
        return path == canonical(ReprisePaths.defaultRoot) ? "master" : "library:" + path
    }

    public enum Failure: LocalizedError {
        case keychain(OSStatus)
        case missing
        public var errorDescription: String? {
            switch self {
            case .missing:
                return "This library is encrypted, but its key is not in this Mac's login keychain (“\(VaultKeychain.label)”). Restore the keychain item or the Mac's keychain from a backup."
            case .keychain(let status):
                let reason = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
                return "The library key could not be read from the login keychain: \(reason)"
            }
        }
    }

    /// The library's master key, or nil when this Mac has none yet.
    public static func load(root: URL) throws -> SymmetricKey? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account(for: root),
                                          kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne] as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, data.count == 32 else { throw Failure.keychain(status) }
        return SymmetricKey(data: data)
    }

    /// Creates the library's master key. `programs` read it without a prompt; nil stands for this program.
    public static func create(root: URL, trusting programs: [URL?]) throws -> SymmetricKey {
        let key = SymmetricKey(size: .bits256)
        let status = try add(key, root: root, trusting: programs)
        if status == errSecDuplicateItem, let existing = try load(root: root) { return existing }
        guard status == errSecSuccess else { throw Failure.keychain(status) }
        return key
    }

    /// Puts a key from a recovery key back into the keychain, with the same access as a new one.
    /// An existing item is never replaced: it may belong to a different copy of the library.
    public static func restore(_ key: SymmetricKey, root: URL, trusting programs: [URL?]) throws {
        let status = try add(key, root: root, trusting: programs)
        guard status == errSecSuccess else { throw Failure.keychain(status) }
    }

    private static func add(_ key: SymmetricKey, root: URL, trusting programs: [URL?]) throws -> OSStatus {
        var applications: [SecTrustedApplication] = []
        for program in programs {
            var application: SecTrustedApplication?
            let status = SecTrustedApplicationCreateFromPath(program?.path, &application)
            guard status == errSecSuccess, let application else { throw Failure.keychain(status) }
            applications.append(application)
        }
        var created: SecAccess?
        let status = SecAccessCreate(label as CFString, applications as CFArray, &created)
        guard status == errSecSuccess, let access = created else { throw Failure.keychain(status) }
        return SecItemAdd([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account(for: root),
                           kSecAttrLabel: label, kSecAttrDescription: "Reprise library encryption key",
                           kSecValueData: key.withUnsafeBytes { Data($0) }, kSecAttrAccess: access] as CFDictionary, nil)
    }
}

/// Seals media files written before encryption, a bounded batch per call.
public enum VaultMigration {
    static let folders = ["captures", "archive", "meetings", "imports"]

    public struct Progress: Sendable {
        public var sealed = 0
        /// More plaintext files wait for the next batch.
        public var remaining = false
        public var failure: String?
    }

    /// Seals the files memories point at, and files nothing points at once they are old enough
    /// that no recording can still be writing them. `inUse` paths are left for a later pass.
    public static func sealLegacyFiles(root: URL, cipher: VaultCipher, referenced: Set<String>, inUse: Set<String> = [],
                                       limit: Int = 300, abandonedAfter: TimeInterval = 6 * 3_600) -> Progress {
        var progress = Progress()
        let cutoff = Date().addingTimeInterval(-abandonedAfter)
        for folder in folders {
            let base = root.appendingPathComponent(folder, isDirectory: true)
            guard let names = FileManager.default.enumerator(atPath: base.path) else { continue }
            while let name = names.nextObject() as? String {
                let relative = "\(folder)/\(name)"
                let url = base.appendingPathComponent(name)
                // Hidden names are work files: partial movies and temporary transcription chunks.
                guard !name.split(separator: "/").contains(where: { $0.hasPrefix(".") }), !inUse.contains(relative),
                      let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                      attributes[.type] as? FileAttributeType == .typeRegular,
                      referenced.contains(relative) || (attributes[.modificationDate] as? Date ?? Date()) < cutoff,
                      !VaultCipher.isSealed(fileAt: url) else { continue }
                if progress.sealed >= limit { progress.remaining = true; return progress }
                do { if try cipher.sealFile(at: url) { progress.sealed += 1 } }
                catch { progress.failure = "\(relative): \(error.localizedDescription)" }
            }
        }
        return progress
    }
}
