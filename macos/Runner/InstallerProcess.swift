import Foundation
import Darwin

struct InstallerProcessResult {
  let status: Int32
  let stdout: String
  let stderr: String
  let timedOut: Bool
  let truncated: Bool
}

/// Runs on the installation worker queue. Both pipes are drained even when an
/// output limit is reached, so noisy tools cannot deadlock the installer.
enum InstallerProcess {
  static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval? = nil,
                  outputLimit: Int = 8 * 1024 * 1024,
                  onLine: ((String) -> Void)? = nil) throws -> InstallerProcessResult {
    let process = Process()
    if getuid() == 0 && geteuid() != 0 {
      // A privileged worker temporarily reads files as the original user. Its
      // parser subprocesses must also drop real/saved IDs, not just effective ID.
      process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
      process.arguments = ["user-tool", String(geteuid()), executable] + arguments
    } else {
      process.executableURL = URL(fileURLWithPath: executable)
      process.arguments = arguments
    }
    var environment = ProcessInfo.processInfo.environment
    environment["LC_ALL"] = "C"
    process.environment = environment
    let output = Pipe(), errors = Pipe()
    process.standardOutput = output
    process.standardError = errors
    try process.run()
    defer {
      try? output.fileHandleForReading.close()
      try? errors.fileHandleForReading.close()
    }
    let descriptors = [output.fileHandleForReading.fileDescriptor, errors.fileHandleForReading.fileDescriptor]
    for fd in descriptors { _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) }
    var polls = descriptors.map { pollfd(fd: $0, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0) }
    let expires = timeout.map { ProcessInfo.processInfo.systemUptime + $0 }
    var terminatedAt: TimeInterval?, exitedAt: TimeInterval?
    var data = Data(), error = Data(), pending = Data()
    var truncated = false, timedOut = false
    var buffer = [UInt8](repeating: 0, count: 8192)
    while true {
      let now = ProcessInfo.processInfo.systemUptime
      if process.isRunning {
        if let expires, now >= expires, terminatedAt == nil {
          timedOut = true; terminatedAt = now; process.terminate()
        }
        if let terminatedAt, now - terminatedAt >= 2 { kill(process.processIdentifier, SIGKILL) }
      } else {
        if exitedAt == nil { exitedAt = now }
        // A tool may leave a daemon holding inherited pipes. Drain buffered
        // output, then return instead of waiting indefinitely for that daemon.
        if polls.allSatisfy({ $0.fd < 0 }) || now - exitedAt! > 0.25 { break }
      }
      _ = poll(&polls, 2, 100)
      for index in polls.indices where polls[index].fd >= 0 && polls[index].revents != 0 {
        for _ in 0..<32 {
          let count = Darwin.read(polls[index].fd, &buffer, buffer.count)
          if count == 0 { polls[index].fd = -1; break }
          if count < 0 {
            if errno != EAGAIN && errno != EINTR { polls[index].fd = -1 }
            break
          }
          let chunk = Data(buffer.prefix(count))
          if index == 1 {
            error.append(chunk)
            if error.count > 16 * 1024 { error = error.suffix(16 * 1024) }
          } else {
            let remaining = max(0, outputLimit - data.count)
            data.append(chunk.prefix(remaining))
            if chunk.count > remaining { truncated = true }
            if let onLine {
              pending.append(chunk)
              while let separator = pending.firstIndex(where: { $0 == 10 || $0 == 13 }) {
                let line = String(decoding: pending[..<separator], as: UTF8.self)
                pending.removeSubrange(...separator)
                if !line.isEmpty { onLine(line) }
              }
              if pending.count > outputLimit { pending.removeAll() }
            }
          }
        }
      }
    }
    process.waitUntilExit()
    if let onLine, !pending.isEmpty { onLine(String(decoding: pending, as: UTF8.self)) }
    return InstallerProcessResult(status: process.terminationStatus,
      stdout: String(decoding: data, as: UTF8.self), stderr: String(decoding: error, as: UTF8.self),
      timedOut: timedOut, truncated: truncated)
  }
}
