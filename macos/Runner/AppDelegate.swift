import Cocoa
import Darwin
import CryptoKit
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}

final class InstallerChannel {
  private let channel: FlutterMethodChannel
  private let queue = DispatchQueue(label: "win.huarun.installer", qos: .userInitiated)
  private var working = false
  private let adminHelper = AdminHelper()

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "win.huarun/installer", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in self?.handle(call, result: result) }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    if call.method == "installSelfUpdate" {
      guard let path = args["path"] as? String, let digest = args["expectedSha256"] as? String,
            let version = args["version"] as? String, let channel = args["channel"] as? String,
            ["release", "debug"].contains(channel), !working else {
        result(FlutterError(code: "update_busy", message: "更新参数无效或另一个安装正在进行。", details: nil)); return
      }
      working = true
      queue.async {
        var response: Any = true
        do { response = ["job": try self.scheduleSelfUpdate(path: path, digest: digest, version: version, channel: channel)] }
        catch let error as NSError {
          response = FlutterError(code: "self_update", message: error.localizedDescription, details: nil)
        }
        DispatchQueue.main.async { self.working = false; result(response) }
      }
      return
    }
    if call.method == "installedApplications" {
      queue.async {
        let response: Any
        do {
          response = try InstalledApplicationReader.scan()
        } catch {
          response = FlutterError(code: "installed_apps", message: "无法读取本机应用信息。", details: nil)
        }
        DispatchQueue.main.async { result(response) }
      }
      return
    }
    if call.method == "openApplicationSettings" {
      let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AppBundles")!
      if NSWorkspace.shared.open(url) {
        result(nil)
      } else {
        result(FlutterError(code: "settings", message: "请从系统设置进入“隐私与安全性 → App 管理”，允许华润赢后重试卸载。", details: nil))
      }
      return
    }
    if call.method == "uninstallApplication" {
      guard let path = args["path"] as? String,
            let identifier = args["bundleIdentifier"] as? String,
            let version = args["version"] as? String, !working else {
        result(FlutterError(code: "busy", message: "卸载参数无效或另一个安装操作正在进行。", details: nil)); return
      }
      working = true
      let authorizationTarget = args["authorizationTarget"] as? [String: String]
      queue.async {
        do {
          let target = try self.uninstallTarget(path: path, identifier: identifier, version: version)
          let snapshot = try self.uninstallSnapshot(target, identifier: identifier, version: version)
          if let authorizationTarget {
            guard authorizationTarget == snapshot else {
              throw self.failure("changed", "卸载目标已变化，请刷新后重新选择。")
            }
            try self.trashUsingAdmin(target, snapshot: snapshot, allowAuthorization: true)
            DispatchQueue.main.async { self.working = false; result(nil) }
            return
          }
          if self.adminHelper.status()["status"] == "enabled" {
            // The selected application was already confirmed in Flutter. Reuse
            // the approved service directly, avoiding Trash UI that could start
            // a second per-operation administrator authorization of its own.
            try self.trashUsingAdmin(target, snapshot: snapshot, allowAuthorization: false)
            DispatchQueue.main.async { self.working = false; result(nil) }
            return
          }
          DispatchQueue.main.async {
            let running = NSWorkspace.shared.runningApplications.contains {
              !$0.isTerminated && $0.bundleURL?.resolvingSymlinksInPath().standardizedFileURL == target
            }
            guard !running else {
              self.working = false
              result(FlutterError(code: "running", message: "请先保存内容并退出所选应用，再重试卸载。", details: nil)); return
            }
            // Try the ordinary-user Trash API first. Permission failures return
            // a bound snapshot for a separate, explicitly confirmed retry.
            NSWorkspace.shared.recycle([target]) { _, error in
              DispatchQueue.main.async {
                if let error {
                  if self.requiresTrashAuthorization(error as NSError) {
                    self.queue.async {
                      let response: Any?
                      if self.adminHelper.status()["status"] == "enabled" {
                        do { try self.trashUsingAdmin(target, snapshot: snapshot, allowAuthorization: false); response = nil }
                        catch let failure as NSError {
                          response = FlutterError(code: failure.userInfo["installerCode"] as? String ?? "uninstall", message: failure.localizedDescription, details: failure.userInfo["installerDetails"])
                        }
                      } else {
                        response = FlutterError(code: "permission_required", message: "需要系统管理员授权，授权后可持续复用。", details: snapshot)
                      }
                      DispatchQueue.main.async { self.working = false; result(response) }
                    }
                    return
                  } else {
                    self.working = false
                    NSWorkspace.shared.activateFileViewerSelecting([target])
                    result(FlutterError(code: "trash", message: "未能移到废纸篓。已在 Finder 中定位应用，请重试或手动处理。\n" + error.localizedDescription, details: nil))
                  }
                } else {
                  self.working = false
                  result(nil)
                }
              }
            }
          }
        } catch let error as NSError {
          DispatchQueue.main.async {
            self.working = false
            let code = error.userInfo["installerCode"] as? String ?? "uninstall"
            if authorizationTarget != nil && !["cancelled", "changed", "running", "caller", "app_management_permission"].contains(code) {
              NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
            result(FlutterError(code: code, message: error.localizedDescription, details: error.userInfo["installerDetails"]))
          }
        }
      }
      return
    }
    if call.method == "architecture" {
      var arm64: Int32 = 0
      var size = MemoryLayout<Int32>.size
      let status = sysctlbyname("hw.optional.arm64", &arm64, &size, nil, 0)
      result(status == 0 && arm64 == 1 ? "arm64" : "x64"); return
    }
    if call.method == "reveal", let path = args["path"] as? String {
      NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
      result(nil); return
    }
    if call.method == "openApp", let path = args["path"] as? String {
      let url = URL(fileURLWithPath: path).standardizedFileURL
      let roots = [
        URL(fileURLWithPath: "/Applications", isDirectory: true),
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
      ].map { $0.standardizedFileURL.path }
      let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      guard roots.contains(url.deletingLastPathComponent().path), url.pathExtension == "app",
            values?.isDirectory == true, values?.isSymbolicLink != true else {
        result(FlutterError(code: "path", message: "应用路径无效。", details: nil)); return
      }
      NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
        DispatchQueue.main.async { result(error.map { FlutterError(code: "launch", message: $0.localizedDescription, details: nil) }) }
      }
      return
    }
    if call.method == "openPackage", let path = args["path"] as? String {
      let url = URL(fileURLWithPath: path).standardizedFileURL
      let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      guard ["dmg", "zip", "pkg"].contains(url.pathExtension.lowercased()),
            values?.isRegularFile == true, values?.isSymbolicLink != true,
            FileManager.default.isReadableFile(atPath: url.path) else {
        result(FlutterError(code: "open_package", message: "安装包不存在或格式不受支持。", details: nil)); return
      }
      result(NSWorkspace.shared.open(url)); return
    }
    guard call.method == "install", let package = args["package"] as? String,
          let quarantine = args["removeQuarantine"] as? Bool else { result(FlutterMethodNotImplemented); return }
    guard !working else { result(FlutterError(code: "busy", message: "另一个安装任务正在进行。", details: nil)); return }
    working = true
    let authorize = args["authorize"] as? Bool ?? false
    let quitApplication = args["quitApplication"] as? [String: String]
    let signerApproval = args["signerApproval"] as? [String: String]
    queue.async {
      var staging: URL?
      let response: Any?
      do {
        func progress(_ event: [String: String]) {
          var payload = event
          payload["package"] = package
          DispatchQueue.main.async { self.channel.invokeMethod("installProgress", arguments: payload) }
        }
        progress(["stage": "preparing"])
        let prepared = try self.invoke(["prepare", package, "--progress"], progress: progress)
        guard let source = prepared["path"] else { throw self.failure("package", "无法准备应用。") }
        staging = URL(fileURLWithPath: source).deletingLastPathComponent()
        progress(prepared.filter { ["signature", "teamIdentifier", "assessment", "notarization"].contains($0.key) }.merging(["stage": "signature"]) { _, new in new })
        var arguments = ["commit", source, quarantine ? "true" : "false"]
        if let signerApproval {
          let data = try JSONSerialization.data(withJSONObject: signerApproval)
          arguments.append(String(decoding: data, as: UTF8.self))
        }
        arguments.append("--progress")
        func commit() throws -> [String: String] {
          if authorize {
            progress(["stage": "authorizing"])
            try self.adminHelper.ensureEnabled(allowAuthorization: true)
            return try self.adminHelper.request { $0.install(source: source, quarantine: quarantine, approval: signerApproval ?? [:], reply: $1) }
          }
          do { return try self.invoke(arguments, progress: progress) }
          catch let error as NSError {
            guard error.userInfo["installerCode"] as? String == "permission_required",
                  self.adminHelper.status()["status"] == "enabled" else { throw error }
            progress(["stage": "privileged"])
            try self.adminHelper.ensureEnabled(allowAuthorization: false)
            return try self.adminHelper.request { $0.install(source: source, quarantine: quarantine, approval: signerApproval ?? [:], reply: $1) }
          }
        }
        let installed: [String: String]
        do {
          installed = try commit()
        } catch let error as NSError {
          guard error.userInfo["installerCode"] as? String == "running",
                let target = error.userInfo["installerDetails"] as? [String: String],
                let path = target["path"], let bundleID = target["bundleIdentifier"],
                quitApplication == target else { throw error }
          progress(["stage": "quitting"])
          try RunningApplicationQuitter.quit(path: path, bundleIdentifier: bundleID)
          // Recheck the destination and identity after quitting, including in the helper.
          installed = try commit()
        }
        response = installed["path"]
      } catch let error as NSError {
        response = FlutterError(code: error.userInfo["installerCode"] as? String ?? "installation", message: error.localizedDescription, details: error.userInfo["installerDetails"])
      }
      if let staging, staging.lastPathComponent.hasPrefix("huarun-install-") { try? FileManager.default.removeItem(at: staging) }
      DispatchQueue.main.async { self.working = false; result(response) }
    }
  }

  private var helper: String { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/HuarunInstaller").path }
  private func trashUsingAdmin(_ target: URL, snapshot: [String: String], allowAuthorization: Bool) throws {
    do { try adminHelper.ensureEnabled(allowAuthorization: allowAuthorization) }
    catch let error as NSError {
      if error.userInfo["installerCode"] as? String == "permission_required" {
        throw failure("permission_required", error.localizedDescription, details: snapshot)
      }
      throw error
    }
    let checked = try uninstallTarget(path: target.path, identifier: snapshot["bundleIdentifier"]!, version: snapshot["version"]!)
    guard try uninstallSnapshot(checked, identifier: snapshot["bundleIdentifier"]!, version: snapshot["version"]!) == snapshot else {
      throw failure("changed", "卸载目标已变化，请刷新后重新选择。")
    }
    guard !NSWorkspace.shared.runningApplications.contains(where: {
      !$0.isTerminated && $0.bundleURL?.resolvingSymlinksInPath().standardizedFileURL == checked
    }) else { throw failure("running", "请先保存内容并退出所选应用，再重试卸载。") }
    // The ordinary user resolves/creates their own Trash before the root service
    // checks it independently; the XPC service obtains UID/PID from the connection.
    let trash = try FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: checked, create: true)
    _ = try adminHelper.request { $0.trash(approval: snapshot.merging(["trash": trash.path]) { _, new in new }, reply: $1) }
  }
  private func uninstallTarget(path: String, identifier: String, version: String) throws -> URL {
    let target = URL(fileURLWithPath: path).standardizedFileURL
    let roots = [
      URL(fileURLWithPath: "/Applications", isDirectory: true),
      FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
    ].map { $0.standardizedFileURL.path }
    let values = try? target.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard geteuid() != 0,
          roots.contains(target.deletingLastPathComponent().path),
          target.pathExtension.lowercased() == "app",
          target == target.resolvingSymlinksInPath().standardizedFileURL,
          values?.isDirectory == true, values?.isSymbolicLink != true,
          !identifier.isEmpty, !identifier.lowercased().hasPrefix("com.apple."),
          identifier != Bundle.main.bundleIdentifier,
          target.appendingPathComponent("Contents/Info.plist").resolvingSymlinksInPath().path.hasPrefix(target.path + "/"),
          let info = NSDictionary(contentsOf: target.appendingPathComponent("Contents/Info.plist")),
          info["CFBundleIdentifier"] as? String == identifier,
          info["CFBundleShortVersionString"] as? String == version else {
      throw failure("changed", "应用路径或身份已变化，或属于受保护的应用，请刷新后重新选择。")
    }
    return target
  }
  private func uninstallSnapshot(_ target: URL, identifier: String, version: String) throws -> [String: String] {
    var attributes = stat()
    guard lstat(target.path, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFDIR,
          attributes.st_flags & UInt32(SF_RESTRICTED) == 0 else {
      throw failure("changed", "应用路径已变化或属于受保护的应用，请刷新后重新选择。")
    }
    return ["path": target.path, "bundleIdentifier": identifier, "version": version,
            "device": String(attributes.st_dev), "inode": String(attributes.st_ino)]
  }
  private func requiresTrashAuthorization(_ error: NSError, depth: Int = 0) -> Bool {
    guard depth < 8 else { return false }
    if error.domain == NSCocoaErrorDomain && [NSFileWriteNoPermissionError, NSFileReadNoPermissionError].contains(error.code) { return true }
    if error.domain == NSPOSIXErrorDomain && [Int(EACCES), Int(EPERM)].contains(error.code) { return true }
    // File Manager / AFP permission errors may be surfaced by the Trash API.
    if error.domain == NSOSStatusErrorDomain && [-54, -5000].contains(error.code) { return true }
    if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
      return requiresTrashAuthorization(underlying, depth: depth + 1)
    }
    return false
  }
  private func scheduleSelfUpdate(path: String, digest: String, version: String, channel: String) throws -> String {
    let package = URL(fileURLWithPath: path).standardizedFileURL
    let values = try package.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    guard values.isRegularFile == true, values.isSymbolicLink != true else {
      throw failure("update_path", "更新包不存在或路径无效。")
    }
    let snapshotDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("huarun-update-package-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: snapshotDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: snapshotDirectory) }
    let snapshot = snapshotDirectory.appendingPathComponent("update." + package.pathExtension)
    try FileManager.default.copyItem(at: package, to: snapshot)
    let input = try FileHandle(forReadingFrom: snapshot)
    defer { try? input.close() }
    var hash = SHA256()
    while let data = try input.read(upToCount: 1024 * 1024), !data.isEmpty { hash.update(data: data) }
    guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == digest else {
      throw failure("checksum", "更新包 SHA-256 已变化，请重新下载。")
    }
    let prepared = try invoke(["prepare", snapshot.path], progress: { _ in })
    guard let source = prepared["path"] else { throw failure("update_package", "无法准备客户端更新。") }
    let stage = URL(fileURLWithPath: source).deletingLastPathComponent()
    var scheduled = false
    defer { if !scheduled { try? FileManager.default.removeItem(at: stage) } }
    let updater = stage.appendingPathComponent("HuarunUpdater")
    try FileManager.default.copyItem(atPath: helper, toPath: updater.path)
    let destination = Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL
    let arguments = ["self-update", source, destination.path, String(getpid()), version, stage.path, String(getuid()), channel]
    let log = stage.appendingPathComponent("updater.log")
    FileManager.default.createFile(atPath: log.path, contents: nil)
    if (destination.deletingLastPathComponent().path == "/Applications" && adminHelper.status()["status"] == "enabled") || !FileManager.default.isWritableFile(atPath: destination.deletingLastPathComponent().path) {
      try adminHelper.ensureEnabled(allowAuthorization: true)
      _ = try adminHelper.request { $0.update(source: source, version: version, channel: channel, reply: $1) }
    } else {
      let process = Process()
      process.executableURL = updater
      process.arguments = arguments
      process.currentDirectoryURL = stage
      let output = try FileHandle(forWritingTo: log)
      process.standardOutput = output; process.standardError = output
      process.standardInput = FileHandle.nullDevice
      try process.run()
      try? output.close()
    }
    let deadline = ProcessInfo.processInfo.systemUptime + 180
    while ProcessInfo.processInfo.systemUptime < deadline {
      let error = stage.appendingPathComponent("error.txt")
      if FileManager.default.fileExists(atPath: error.path) {
        throw failure("self_update", (try? String(contentsOf: error, encoding: .utf8)) ?? "更新准备失败。")
      }
      if FileManager.default.fileExists(atPath: stage.appendingPathComponent("ready").path) {
        scheduled = true; return stage.path
      }
      Thread.sleep(forTimeInterval: 0.1)
    }
    try? "cancel".write(to: stage.appendingPathComponent("cancel"), atomically: true, encoding: .utf8)
    throw failure("update_timeout", "更新准备超时，当前客户端保持运行，安装包已保留。")
  }
  private func failure(_ code: String, _ message: String, details: [String: String] = [:]) -> NSError {
    NSError(domain: "win.huarun.installer", code: 1, userInfo: [NSLocalizedDescriptionKey: message, "installerCode": code, "installerDetails": details])
  }
  private func failure(_ json: [String: String]) -> NSError {
    failure(json["code"] ?? "installation", json["message"] ?? "安装未完成。", details: json.filter {
      ["path", "bundleIdentifier", "oldIdentity", "newIdentity"].contains($0.key)
    })
  }
  private func jsonLines(_ text: String) -> [[String: String]] {
    text.components(separatedBy: .newlines).compactMap { line in
      guard let first = line.firstIndex(of: "{"), let last = line.lastIndex(of: "}"), first <= last,
            let data = String(line[first...last]).data(using: .utf8) else { return nil }
      return (try? JSONSerialization.jsonObject(with: data)) as? [String: String]
    }
  }
  private func response(_ result: InstallerProcessResult) throws -> [String: String] {
    let messages = jsonLines(result.stdout) + jsonLines(result.stderr)
    if let error = messages.last(where: { $0["code"] != nil }) { throw failure(error) }
    if result.status == 0, let value = messages.last(where: { $0["path"] != nil && $0["event"] == nil }) { return value }
    throw failure("installation", "助手未返回有效结果，请重试或手动安装。" + (result.stderr.isEmpty ? "" : "\n" + String(result.stderr.suffix(1500))))
  }
  private func invoke(_ args: [String], progress: @escaping ([String: String]) -> Void) throws -> [String: String] {
    let result = try InstallerProcess.run(helper, args, onLine: { line in
      if let event = self.jsonLines(line).first, event["event"] == "progress" { progress(event) }
    })
    return try response(result)
  }
}
