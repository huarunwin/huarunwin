import AppKit

/// Called on the install queue, using the ordinary user's permissions.
enum RunningApplicationQuitter {
  static func quit(path: String, bundleIdentifier: String, timeout: TimeInterval = 20) throws {
    func failure(_ code: String, _ message: String) -> NSError {
      NSError(domain: "win.huarun.installer", code: 1, userInfo: [
        NSLocalizedDescriptionKey: message,
        "installerCode": code,
      ])
    }
    let target = URL(fileURLWithPath: path).standardizedFileURL
    guard geteuid() != 0,
          target.deletingLastPathComponent().path == "/Applications",
          target.pathExtension == "app",
          target == target.resolvingSymlinksInPath().standardizedFileURL,
          !bundleIdentifier.isEmpty,
          !bundleIdentifier.hasPrefix("com.apple."),
          let info = NSDictionary(contentsOf: target.appendingPathComponent("Contents/Info.plist")),
          info["CFBundleIdentifier"] as? String == bundleIdentifier else {
      throw failure("changed", "安装目标已变化，请重新安装；现有应用未被修改。")
    }
    let applications: [NSRunningApplication] = DispatchQueue.main.sync {
      NSWorkspace.shared.runningApplications.filter {
        !$0.isTerminated && $0.bundleURL?.resolvingSymlinksInPath().standardizedFileURL == target
      }
    }
    // Match both the validated destination and identity. Never terminate this client.
    guard applications.allSatisfy({
      $0.bundleIdentifier == bundleIdentifier && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
    }) else {
      throw failure("changed", "无法确认正在运行的应用身份，请手动退出后重试。")
    }
    let accepted = DispatchQueue.main.sync {
      applications.map { $0.isTerminated || $0.terminate() }.allSatisfy { $0 }
    }
    guard accepted else {
      throw failure("quit_failed", "应用尚未退出，请处理保存提示或手动退出后重试。")
    }
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    repeat {
      if DispatchQueue.main.sync(execute: { applications.allSatisfy(\.isTerminated) }) { return }
      // Keep the UI/main run loop free for save prompts and termination events.
      Thread.sleep(forTimeInterval: 0.1)
    } while ProcessInfo.processInfo.systemUptime < deadline
    throw failure("quit_failed", "应用尚未退出，请处理保存提示或手动退出后重试。")
  }
}
