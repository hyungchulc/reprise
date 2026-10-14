import Foundation
import Darwin

enum AIProcessSandbox {
    static let executable = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
    static var isAvailable: Bool { FileManager.default.isExecutableFile(atPath: executable.path) }

    /// A writable place outside the per-call directory that a CLI needs for its own state.
    enum Writable {
        case file(String), folder(String), pattern(String)
        var rule: String {
            switch self {
            case .file(let path): "(literal \(AICommand.tomlString(path)))"
            case .folder(let path): "(subpath \(AICommand.tomlString(path)))"
            case .pattern(let expression): "(regex #\"\(expression)\")"
            }
        }
    }

    /// Writes stay in `root` and the listed places. With `programs` nil the CLI may not start any
    /// other program; otherwise it may fork but only run the listed programs.
    static func profile(root: URL, executable: URL? = nil, writable: [Writable] = [], programs: [URL]? = nil) -> String {
        let root = canonicalPath(root)
        let sockets = ["/var/run/docker.sock", "/run/docker.sock", "/var/run/podman/podman.sock",
            "/run/containerd/containerd.sock", "/var/run/containerd/containerd.sock"]
        let denied = Set(sockets + sockets.map { canonicalPath(URL(fileURLWithPath: $0)) })
        let socketRules = denied.sorted().map {
            "(deny network-outbound (remote unix-socket (literal \(AICommand.tomlString($0)))))"
        }.joined(separator: "\n")
        let allowedWrites = (["(subpath \(AICommand.tomlString(root)))"] + writable.map(\.rule)).joined(separator: " ")
        let processRules: String
        if let programs {
            let allowed = programs.map { "(literal \(AICommand.tomlString(canonicalPath($0))))" }.joined(separator: " ")
            processRules = "(deny process-exec (require-not (require-any \(allowed))))"
        } else {
            processRules = "(deny process-fork)\n" + (executable.map { "(deny process-exec (require-not (literal \(AICommand.tomlString(canonicalPath($0))))))" } ?? "")
        }
        // Grok's native profile rejects symlinked Docker sockets. Apply the kernel policy before exec instead.
        return """
        (version 1)
        (allow default)
        (deny file-write* (require-not (require-any \(allowedWrites))))
        \(processRules)
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
