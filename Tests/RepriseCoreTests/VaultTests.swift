import AVFoundation
import ImageIO
import Security
import XCTest
@testable import RepriseCore

final class VaultTests: XCTestCase {
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("reprise-vault-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testSealedFilesRoundTripAndReadAnyRange() throws {
        let cipher = testKeys.cipher, chunk = VaultCipher.chunkSize
        for size in [0, 1, chunk - 1, chunk, chunk + 1, chunk * 2 + chunk / 2] {
            let plain = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ size) })
            let sealed = try cipher.seal(plain)
            XCTAssertTrue(VaultCipher.isSealed(sealed))
            XCTAssertEqual(try cipher.open(sealed), plain, "size \(size)")
            let url = try temporaryRoot().appendingPathComponent("file")
            try sealed.write(to: url)
            let reader = try VaultCipher.Reader(url: url, cipher: cipher)
            XCTAssertEqual(reader.length, Int64(size))
            for (offset, count) in [(0, 10), (chunk - 3, 7), (size / 2, chunk + 5), (size - 1, 4)] where offset >= 0 && offset < size {
                XCTAssertEqual(try reader.read(offset: Int64(offset), count: count), plain[offset..<min(size, offset + count)], "size \(size) range \(offset)")
            }
            // A stream sealed piece by piece reads back the same.
            let streamed = url.deletingLastPathComponent().appendingPathComponent("streamed")
            let writer = try VaultCipher.Writer(creating: streamed, cipher: cipher)
            for start in stride(from: 0, to: size, by: 300_001) { try writer.append(plain[start..<min(size, start + 300_001)]) }
            try writer.finish()
            XCTAssertEqual(try cipher.contents(of: streamed), plain)
        }
    }

    func testDamagedTruncatedOrForeignFilesFail() throws {
        let cipher = testKeys.cipher, chunk = VaultCipher.chunkSize
        let plain = Data(repeating: 7, count: chunk * 2 + 10)
        let sealed = try cipher.seal(plain)
        var flipped = sealed
        flipped[flipped.count / 2] ^= 1
        XCTAssertThrowsError(try cipher.open(flipped))
        // Cut exactly after the first chunk: every remaining chunk still authenticates on its own.
        let cut = sealed.prefix(VaultCipher.headerSize + chunk + VaultCipher.tagSize)
        XCTAssertThrowsError(try cipher.open(cut))
        let url = try temporaryRoot().appendingPathComponent("cut")
        try cut.write(to: url)
        XCTAssertThrowsError(try VaultCipher.Reader(url: url, cipher: cipher))
        XCTAssertThrowsError(try VaultKeys.ephemeral().cipher.open(sealed))
    }

    func testFilesFromBeforeEncryptionSealInPlace() throws {
        let root = try temporaryRoot()
        let captures = root.appendingPathComponent("captures")
        try FileManager.default.createDirectory(at: captures, withIntermediateDirectories: true)
        let plain = Data("plain screen pixels".utf8)
        for name in ["kept.heic", "orphan.heic", "fresh.heic", ".partial-1.mp4"] { try plain.write(to: captures.appendingPathComponent(name)) }
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-86_400)], ofItemAtPath: captures.appendingPathComponent("orphan.heic").path)
        XCTAssertEqual(try testKeys.cipher.contents(of: captures.appendingPathComponent("kept.heic")), plain, "Unsealed files still read")
        let first = VaultMigration.sealLegacyFiles(root: root, cipher: testKeys.cipher, referenced: ["captures/kept.heic"], limit: 1)
        XCTAssertEqual(first.sealed, 1)
        XCTAssertTrue(first.remaining)
        let rest = VaultMigration.sealLegacyFiles(root: root, cipher: testKeys.cipher, referenced: ["captures/kept.heic"])
        XCTAssertEqual(rest.sealed, 1)
        XCTAssertFalse(rest.remaining)
        for name in ["kept.heic", "orphan.heic"] {
            let url = captures.appendingPathComponent(name)
            XCTAssertTrue(VaultCipher.isSealed(fileAt: url), name)
            XCTAssertEqual(try testKeys.cipher.contents(of: url), plain)
        }
        // A fresh file nothing points at may still be a recording in progress; work files are skipped.
        XCTAssertFalse(VaultCipher.isSealed(fileAt: captures.appendingPathComponent("fresh.heic")))
        XCTAssertFalse(VaultCipher.isSealed(fileAt: captures.appendingPathComponent(".partial-1.mp4")))
        var mode = stat()
        XCTAssertEqual(lstat(captures.appendingPathComponent("kept.heic").path, &mode), 0)
        XCTAssertEqual(mode.st_mode & 0o777, 0o600)
    }

    func testSealedRecordingDecodesWithoutAPlaintextCopy() async throws {
        let url = try temporaryRoot().appendingPathComponent("meeting.m4a")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        do {
            let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1])
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96_000))
            buffer.frameLength = 96_000
            for frame in 0..<96_000 { buffer.floatChannelData?[0][frame] = Float(sin(Double(frame) * 0.05) * 0.3) }
            try file.write(from: buffer)
        }
        XCTAssertTrue(try testKeys.cipher.sealFile(at: url))
        let media = try VaultAsset(url: url, cipher: testKeys.cipher)
        let duration = try await media.asset.load(.duration).seconds
        XCTAssertEqual(duration, 2, accuracy: 0.05)
        let tracks = try await media.asset.loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: media.asset)
        let speech = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: speech.settings)
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var frames = 0
        while let sample = output.copyNextSampleBuffer() { frames += CMSampleBufferGetNumSamples(sample) }
        XCTAssertEqual(reader.status, .completed)
        XCTAssertEqual(Double(frames), 32_000, accuracy: 2_000)
    }

    func testLibraryNeedsItsKeyAndKeepsNoPlaintext() async throws {
        let root = try temporaryRoot()
        let store = try MomentStore(root: root, keys: testKeys)
        try await store.insert(Moment(id: "secret", appName: "Notes", windowTitle: "Quarterly plan", text: "launch codename bluebird"))
        let found = try await store.search(MomentQuery(text: "bluebird"))
        XCTAssertEqual(found.map(\.id), ["secret"])
        let database = root.appendingPathComponent("library.sqlite").path
        XCTAssertFalse(MomentStore.isPlaintextDatabase(database))
        XCTAssertTrue(MomentStore.isEncryptedLibrary(root: root))
        for suffix in ["", "-wal"] {
            guard let bytes = FileManager.default.contents(atPath: database + suffix) else { continue }
            XCTAssertNil(bytes.range(of: Data("bluebird".utf8)), "plaintext in library.sqlite\(suffix)")
        }
        XCTAssertThrowsError(try MomentStore(root: root, readOnly: true, keys: VaultKeys.ephemeral()))
        let reader = try MomentStore(root: root, readOnly: true, keys: testKeys)
        let read = try await reader.moment(id: "secret")
        XCTAssertEqual(read?.text, "launch codename bluebird")
    }
}

final class VaultSampleTests: XCTestCase {
    /// Encrypts a copy of a real library folder (database made with sqlite3 .backup) and proves
    /// every kind of media still opens. The source folder is only read.
    func testCopiedVaultEncryptsWhenRequested() async throws {
        guard let source = ProcessInfo.processInfo.environment["REPRISE_VAULT_COPY"] else {
            throw XCTSkip("Set REPRISE_VAULT_COPY to a copied library folder to check encryption on real media.")
        }
        let root = URL(fileURLWithPath: source)
        let started = Date()
        let store = try MomentStore(root: root, keys: testKeys)
        let converted = Date().timeIntervalSince(started)
        let referenced = try await store.referencedMedia()
        var sealed = 0, passes = 0
        let sealing = Date()
        while true {
            let progress = VaultMigration.sealLegacyFiles(root: root, cipher: testKeys.cipher, referenced: referenced)
            XCTAssertNil(progress.failure)
            sealed += progress.sealed; passes += 1
            if !progress.remaining { break }
        }
        let sealSeconds = Date().timeIntervalSince(sealing)
        var stills = 0, frames = 0, audio = 0
        var frameTimes: [Double] = []
        var meetings = MomentQuery(limit: 20); meetings.kind = "meeting"
        for moment in try await store.query(MomentQuery(limit: 1_000)) + store.query(meetings) {
            if let frame = moment.archivedFrame, frames < 12 {
                let begin = Date()
                _ = try await FrameReader(movie: try await store.mediaURL(frame.path), cipher: store.cipher, maxPixels: 1024).image(at: frame.offset)
                frameTimes.append(Date().timeIntervalSince(begin) * 1000); frames += 1
            } else if !moment.imagePath.isEmpty, stills < 12 {
                let data = try store.cipher.contents(of: root.appendingPathComponent(moment.imagePath))
                XCTAssertNotNil(CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
                stills += 1
            } else if moment.kind == "meeting", let path = moment.videoPath {
                let media = try VaultAsset(url: try await store.mediaURL(path), cipher: store.cipher)
                let seconds = try await media.asset.load(.duration).seconds
                XCTAssertGreaterThan(seconds, 0)
                audio += 1
            }
        }
        let plaintext = FileManager.default.enumerator(atPath: root.path)?.compactMap { $0 as? String }
            .filter { ["captures/", "archive/", "meetings/"].contains(where: $0.hasPrefix) && !$0.split(separator: "/").contains(where: { $0.hasPrefix(".") }) }
            .filter { name in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path, isDirectory: &isDirectory) && !isDirectory.boolValue
                    && !VaultCipher.isSealed(fileAt: root.appendingPathComponent(name))
            } ?? []
        print(String(format: "VAULT database %.2f s, sealed %d files in %d passes %.1f s, checked stills %d frames %d (ms %@) meetings %d, plaintext left %d %@",
                     converted, sealed, passes, sealSeconds, stills, frames, frameTimes.map { String(format: "%.0f", $0) }.joined(separator: "/"),
                     audio, plaintext.count, plaintext.prefix(5).joined(separator: ",")))
        // Files newer than the copied database are unreferenced and wait until they are old.
        XCTAssertTrue(plaintext.filter(referenced.contains).isEmpty)
    }
}

final class VaultKeychainTests: XCTestCase {
    func testLibrariesOutsideTheUsualFolderGetTheirOwnKey() throws {
        XCTAssertEqual(VaultKeychain.account(for: ReprisePaths.defaultRoot), "master")
        XCTAssertEqual(VaultKeychain.account(for: ReprisePaths.defaultRoot.appendingPathComponent("../Reprise")), "master")
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("reprise-copy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: copy) }
        let account = VaultKeychain.account(for: copy)
        XCTAssertTrue(account.hasPrefix("library:/"))
        // The app and the MCP helper may spell the same folder differently.
        XCTAssertEqual(VaultKeychain.account(for: URL(fileURLWithPath: copy.path + "/sub/..")), account)
        XCTAssertEqual(VaultKeychain.account(for: URL(fileURLWithPath: (copy.path as NSString).resolvingSymlinksInPath)), account)
    }

    /// Writes a real login-keychain item for a throwaway library, reads it back as its creator and
    /// removes it. Only the creating program is involved, so no approval prompt appears.
    func testKeyIsCreatedAndLimitedToListedProgramsWhenRequested() throws {
        guard ProcessInfo.processInfo.environment["REPRISE_TEST_KEYCHAIN"] == "1" else {
            throw XCTSkip("Set REPRISE_TEST_KEYCHAIN=1 to write and remove a throwaway login-keychain item.")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("reprise-keychain-\(UUID().uuidString)")
        let query = [kSecClass: kSecClassGenericPassword, kSecAttrService: VaultKeychain.service, kSecAttrAccount: VaultKeychain.account(for: root)] as CFDictionary
        defer { SecItemDelete(query) }
        XCTAssertNil(try VaultKeychain.load(root: root))
        let created = try VaultKeychain.create(root: root, trusting: [nil])
        let loaded = try XCTUnwrap(try VaultKeychain.load(root: root))
        XCTAssertEqual(created.withUnsafeBytes { Data($0) }, loaded.withUnsafeBytes { Data($0) })
        XCTAssertEqual(try VaultKeychain.create(root: root, trusting: [nil]).withUnsafeBytes { Data($0) }, loaded.withUnsafeBytes { Data($0) })
        // Only the listed program reads without asking; macOS asks the person for any other.
        var reference: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching([kSecClass: kSecClassGenericPassword, kSecAttrService: VaultKeychain.service,
                                            kSecAttrAccount: VaultKeychain.account(for: root), kSecReturnRef: true] as CFDictionary, &reference), errSecSuccess)
        var access: SecAccess?
        XCTAssertEqual(SecKeychainItemCopyAccess(reference as! SecKeychainItem, &access), errSecSuccess)
        let acls = try XCTUnwrap(SecAccessCopyMatchingACLList(try XCTUnwrap(access), kSecACLAuthorizationDecrypt) as? [SecACL])
        XCTAssertFalse(acls.isEmpty)
        for acl in acls {
            var list: CFArray?, description: CFString?, selector = SecKeychainPromptSelector()
            XCTAssertEqual(SecACLCopyContents(acl, &list, &description, &selector), errSecSuccess)
            XCTAssertEqual((list as? [SecTrustedApplication])?.count, 1)
        }
    }
}
