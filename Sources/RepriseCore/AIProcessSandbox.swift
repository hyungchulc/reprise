import Foundation
import Darwin

enum AIProcessSandbox {
    static let executable = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
    static var isAvailable: Bool { FileManager.default.isExecutableFile(atPath: executable.path) }

    static func profile(root: URL, executable: URL? = nil) -> String {
        let root = canonicalPath(root)
        let sockets = ["/var/run/docker.sock", "/run/docker.sock", "/var/run/podman/podman.sock",
            "/run/containerd/containerd.sock", "/var/run/containerd/containerd.sock"]
        let denied = Set(sockets + sockets.map { canonicalPath(URL(fileURLWithPath: $0)) })
        let socketRules = denied.sorted().map {
            "(deny network-outbound (remote unix-socket (literal \(AICommand.tomlString($0)))))"
        }.joined(separator: "\n")
        // Grok's native profile rejects symlinked Docker sockets. Apply the kernel policy before exec instead.
        return """
        (version 1)
        (allow default)
        (deny file-write* (require-not (subpath \(AICommand.tomlString(root)))))
        (deny process-fork)
        \(executable.map { "(deny process-exec (require-not (literal \(AICommand.tomlString(canonicalPath($0))))))" } ?? "")
        \(socketRules)
        """
    }

    static func canonicalPath(_ url: URL) -> String {
        // Foundation can abbreviate /private/var back to /var; Seatbelt requires the real vnode path.
        guard let path = url.withUnsafeFileSystemRepresentation({ realpath($0, nil) }) else { return url.path }
        defer { free(path) }
        return String(cString: path)
    }
}
