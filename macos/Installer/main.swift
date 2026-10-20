import Foundation
import Darwin
import AppKit

struct InstallerFailure: Error {
    let code: String
    let message: String
    let details: [String: String]
}

let files = FileManager.default
var reportsProgress = false
func fail(_ code: String, _ message: String, details: [String: String] = [:]) throws -> Never {
    throw InstallerFailure(code: code, message: message, details: details)
}
func output(_ payload: [String: String]) {
    if let data = try? JSONSerialization.data(withJSONObject: payload), let text = String(data: data, encoding: .utf8) {
        print(text)
        fflush(stdout)
    }
}

func progress(_ stage: String, _ details: [String: String] = [:]) {
    if reportsProgress { output(details.merging(["event": "progress", "stage": stage]) { _, new in new }) }
}

@discardableResult
func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 120) throws -> String {
    let result = try InstallerProcess.run(executable, arguments, timeout: timeout, outputLimit: 64 * 1024 * 1024)
    if result.timedOut { try fail("timeout", "处理安装包超时，请重试或手动安装。") }
    if result.truncated { try fail("package", "安装包目录过大，请使用官方安装方式。") }
    guard result.status == 0 else {
        try fail("package", "无法读取安装包，请确认文件完整且格式受支持。" + (result.stderr.isEmpty ? "" : "\n" + String(result.stderr.suffix(1500))))
    }
    return result.stdout
}

func requireSpace(at directory: URL, bytes: Int64) throws {
    let available = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
    let (required, overflow) = bytes.addingReportingOverflow(128 * 1024 * 1024)
    guard !overflow, bytes >= 0 else { try fail("space", "安装包展开后的大小无效，请手动安装。") }
    if let available, available < required {
        try fail("space", "磁盘剩余空间不足，请清理空间后重试。安装还需要约 \(ByteCountFormatter.string(fromByteCount: required, countStyle: .file)) 可用空间。")
    }
}

func bundleBytes(_ app: URL) throws -> Int64 {
    guard let entries = files.enumerator(at: app, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) else {
        try fail("package", "无法检查应用大小。")
    }
    var bytes: Int64 = 0
    for case let file as URL in entries {
        let info = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        if info.isRegularFile == true, info.isSymbolicLink != true, let size = info.fileSize {
            let (total, overflow) = bytes.addingReportingOverflow(Int64(size))
            guard !overflow else { try fail("space", "应用大小无效，请手动安装。") }
            bytes = total
        }
    }
    return bytes
}

func zipBytes(_ package: URL) throws -> Int64 {
    let summary = try run("/usr/bin/zipinfo", ["-t", package.path], timeout: 30)
    let pattern = try NSRegularExpression(pattern: "(?:^|\\s)([0-9]+) bytes uncompressed(?:,|\\s|$)")
    let range = NSRange(summary.startIndex..., in: summary)
    guard let match = pattern.firstMatch(in: summary, range: range), let number = Range(match.range(at: 1), in: summary),
          let size = Int64(summary[number]), size >= 0 else {
        try fail("package", "无法确认压缩包展开后的大小，请手动安装。")
    }
    let (required, overflow) = size.multipliedReportingOverflow(by: 2)
    guard !overflow else { try fail("space", "压缩包展开后的大小无效，请手动安装。") }
    return required
}

func signingInfo(_ app: URL, assess: Bool = true) -> [String: String] {
    var info = ["signature": "unknown", "teamIdentifier": "", "assessment": "unknown", "notarization": "unknown"]
    if let metadata = try? InstallerProcess.run("/usr/bin/codesign", ["--display", "--verbose=4", app.path], timeout: 30) {
        let text = metadata.stderr + metadata.stdout
        let rawTeam = text.components(separatedBy: .newlines).first(where: { $0.hasPrefix("TeamIdentifier=") })?.dropFirst("TeamIdentifier=".count) ?? ""
        let team = String(rawTeam)
        if team.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil { info["teamIdentifier"] = team }
        if !metadata.timedOut && text.contains("code object is not signed at all") {
            info["signature"] = "unsigned"
        } else if metadata.status == 0 && !metadata.timedOut,
                  let checked = try? InstallerProcess.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path], timeout: 90), !checked.timedOut {
            info["signature"] = checked.status == 0 ? (text.contains("Signature=adhoc") ? "adhoc" : "valid") : "invalid"
        }
    }
    if assess, let assessment = try? InstallerProcess.run("/usr/sbin/spctl", ["--assess", "--type", "execute", "--verbose=2", app.path], timeout: 30), !assessment.timedOut {
        info["assessment"] = assessment.status == 0 ? "accepted" : "rejected"
        if assessment.status == 0 && assessment.stderr.contains("source=Notarized Developer ID") { info["notarization"] = "notarized" }
    }
    return info
}

func signingIdentity(_ info: [String: String]) -> String {
    if info["signature"] == "valid", let team = info["teamIdentifier"], !team.isEmpty { return "Team ID " + team }
    switch info["signature"] {
    case "unsigned": return "未签名"
    case "adhoc": return "本地签名"
    case "invalid": return "签名校验未通过"
    default: return "签名状态未确认"
    }
}

func checkSigningChange(_ destination: URL, bundleID: String, incoming: [String: String], approval: [String: String]?) throws {
    guard files.fileExists(atPath: destination.path) else { return }
    let installed = signingInfo(destination, assess: false)
    guard installed["signature"] == "valid", !(installed["teamIdentifier"] ?? "").isEmpty,
          signingIdentity(installed) != signingIdentity(incoming) else { return }
    let change = ["path": destination.path, "bundleIdentifier": bundleID,
                  "oldIdentity": signingIdentity(installed), "newIdentity": signingIdentity(incoming)]
    if approval != change { try fail("signer_changed", "新版本与现有应用的开发者签名不同，请确认后继续。", details: change) }
}

@discardableResult
func validateBundle(_ app: URL, checkArchitecture: Bool = true) throws -> String {
    let root = app.resolvingSymlinksInPath().standardizedFileURL
    let values = try app.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
    guard values.isSymbolicLink != true, values.isDirectory == true, app.pathExtension == "app" else {
        try fail("package", "安装包中没有可安装的 Mac 应用。")
    }
    let infoURL = app.appendingPathComponent("Contents/Info.plist")
    guard let plist = NSDictionary(contentsOf: infoURL),
          let executable = plist["CFBundleExecutable"] as? String,
          let bundleID = plist["CFBundleIdentifier"] as? String,
          !executable.isEmpty, executable != ".", executable != "..", !executable.contains("/"),
          !bundleID.isEmpty, !bundleID.hasPrefix("com.apple.") else {
        try fail("package", "应用标识或可执行文件无效。")
    }
    guard let enumerator = files.enumerator(at: app, includingPropertiesForKeys: [.isSymbolicLinkKey]) else {
        try fail("package", "无法检查应用内容。")
    }
    for case let file as URL in enumerator {
        let resolved = file.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolved == root.path || resolved.hasPrefix(root.path + "/") else {
            try fail("package", "应用包含指向包外的符号链接，请使用官方安装方式。")
        }
    }
    let binary = app.appendingPathComponent("Contents/MacOS").appendingPathComponent(executable)
    guard files.isExecutableFile(atPath: binary.path) else {
        try fail("package", "应用缺少可执行文件。")
    }
    if checkArchitecture {
        let architectures = try run("/usr/bin/lipo", ["-archs", binary.path]).split(separator: " ").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let appleSilicon = (try? run("/usr/sbin/sysctl", ["-n", "hw.optional.arm64"]).trimmingCharacters(in: .whitespacesAndNewlines)) == "1"
        let expected = appleSilicon ? "arm64" : "x86_64"
        guard architectures.contains(expected) || (appleSilicon && architectures.contains("arm64e")) else {
            try fail("architecture", "这个安装包与当前 Mac 架构不匹配，请下载 \(appleSilicon ? "Apple Silicon / ARM64" : "Intel / x64") 版本。")
        }
    }
    return bundleID
}

func locateApps(_ directory: URL, depth: Int = 0) throws -> [URL] {
    guard depth < 3 else { return [] }
    var apps: [URL] = []
    for entry in try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) {
        let values = try entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        if values.isSymbolicLink == true || values.isDirectory != true { continue }
        if entry.pathExtension == "app" { apps.append(entry) }
        else { apps.append(contentsOf: try locateApps(entry, depth: depth + 1)) }
    }
    return apps
}

func prepare(_ package: URL) throws -> URL {
    guard geteuid() != 0 else { try fail("permission", "安装包必须由普通用户预处理。") }
    let ext = package.pathExtension.lowercased()
    guard ["dmg", "zip"].contains(ext), files.isReadableFile(atPath: package.path) else {
        try fail("package", "请选择可读取的 DMG 或 ZIP 安装包。")
    }
    let stage = files.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("huarun-install-" + UUID().uuidString)
    try files.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    var keepStage = false
    defer { if !keepStage { try? files.removeItem(at: stage) } }
    let unpacked = stage.appendingPathComponent("unpacked")
    try files.createDirectory(at: unpacked, withIntermediateDirectories: false)
    var mounted = false
    defer {
        if mounted { _ = try? run("/usr/bin/hdiutil", ["detach", unpacked.path], timeout: 20) }
    }
    if ext == "dmg" {
        progress("mounting")
        // Attempt cleanup even if attach times out after creating a mount.
        mounted = true
        try run("/usr/bin/hdiutil", ["attach", "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", unpacked.path, package.path])
    } else {
        try requireSpace(at: stage, bytes: zipBytes(package))
        progress("extracting")
        let entries = try run("/usr/bin/tar", ["-tf", package.path])
        for name in entries.split(separator: "\n") {
            if name.hasPrefix("/") || name.split(separator: "/").contains("..") {
                try fail("package", "压缩包包含无效路径。")
            }
        }
        // bsdtar's default extraction rejects traversal and writes through symlinks.
        try run("/usr/bin/tar", ["-xf", package.path, "--no-same-owner", "-C", unpacked.path], timeout: 600)
    }
    let candidates = try locateApps(unpacked)
    guard candidates.count == 1 else {
        try fail("package", candidates.isEmpty ? "未发现 Mac 应用，请使用官方安装方式。" : "安装包包含多个应用，请手动选择安装。")
    }
    let app = candidates[0]
    progress("validating")
    try validateBundle(app)
    try requireSpace(at: stage, bytes: bundleBytes(app))
    let payload = stage.appendingPathComponent(app.lastPathComponent)
    try files.copyItem(at: app, to: payload)
    try validateBundle(payload)
    keepStage = true
    return payload
}

func removeQuarantine(_ root: URL) throws {
    func clear(_ item: URL) throws {
        if removexattr(item.path, "com.apple.quarantine", XATTR_NOFOLLOW) != 0 && errno != ENOATTR {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }
    try clear(root)
    guard let enumerator = files.enumerator(at: root, includingPropertiesForKeys: []) else {
        try fail("package", "无法处理应用的隔离属性。")
    }
    for case let item as URL in enumerator { try clear(item) }
}

func replacementExists(at destination: URL, bundleID: String) throws -> Bool {
    var attributes = stat()
    guard lstat(destination.path, &attributes) == 0 else {
        if errno == ENOENT { return false }
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    let info = destination.appendingPathComponent("Contents/Info.plist")
    guard attributes.st_mode & S_IFMT == S_IFDIR,
          destination == destination.resolvingSymlinksInPath().standardizedFileURL,
          info.resolvingSymlinksInPath().path.hasPrefix(destination.path + "/"),
          let plist = NSDictionary(contentsOf: info),
          plist["CFBundleIdentifier"] as? String == bundleID else {
        try fail("app_mismatch", "“应用程序”中已有同名文件或其他应用，无法替换；现有内容未被修改。")
    }
    guard !NSWorkspace.shared.runningApplications.contains(where: {
        $0.bundleURL?.resolvingSymlinksInPath().standardizedFileURL == destination
    }) else {
        try fail("running", "\(destination.deletingPathExtension().lastPathComponent) 正在运行，退出后才能继续安装。", details: [
            "path": destination.path,
            "bundleIdentifier": bundleID,
        ])
    }
    return true
}

func commit(_ source: URL, quarantine: Bool, signerApproval: [String: String]? = nil) throws -> URL {
    let stage = source.deletingLastPathComponent()
    guard stage.lastPathComponent.hasPrefix("huarun-install-"),
          source == source.resolvingSymlinksInPath().standardizedFileURL else {
        try fail("package", "安装暂存路径无效。")
    }
    let stageAttrs = try files.attributesOfItem(atPath: stage.path)
    guard (stageAttrs[.posixPermissions] as? NSNumber)?.intValue == 0o700 else {
        try fail("package", "安装暂存目录的权限无效。")
    }
    progress("validating")
    let bundleID = try validateBundle(source)
    let destination = URL(fileURLWithPath: "/Applications", isDirectory: true).appendingPathComponent(source.lastPathComponent)
    _ = try replacementExists(at: destination, bundleID: bundleID)
    progress("signature")
    let signature = signingInfo(source, assess: false)
    try checkSigningChange(destination, bundleID: bundleID, incoming: signature, approval: signerApproval)
    try requireSpace(at: URL(fileURLWithPath: "/Applications"), bytes: bundleBytes(source))
    let temporary = URL(fileURLWithPath: "/Applications/.huarun-install-" + UUID().uuidString, isDirectory: true)
    do {
        try files.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    } catch {
        let error = error as NSError
        let underlying = (error.userInfo[NSUnderlyingErrorKey] as? NSError) ?? error
        if error.code == NSFileWriteOutOfSpaceError || (underlying.domain == NSPOSIXErrorDomain && underlying.code == ENOSPC) {
            try fail("space", "磁盘剩余空间不足，请清理空间后重试。")
        }
        if error.code == NSFileWriteNoPermissionError || (underlying.domain == NSPOSIXErrorDomain && [Int(EACCES), Int(EPERM)].contains(underlying.code)) {
            try fail("permission_required", "当前用户无权写入“应用程序”文件夹，需要管理员授权。")
        }
        throw error
    }
    defer { try? files.removeItem(at: temporary) }
    let prepared = temporary.appendingPathComponent(source.lastPathComponent)
    progress("copying")
    try files.copyItem(at: source, to: prepared)
    guard try validateBundle(prepared) == bundleID else {
        try fail("package", "安装包在复制过程中已变化，请重新选择安装包。")
    }
    let copiedSignature = signingInfo(prepared, assess: false)
    guard copiedSignature["signature"] == signature["signature"], copiedSignature["teamIdentifier"] == signature["teamIdentifier"] else {
        try fail("changed", "应用签名在复制过程中已变化，请重试；现有应用未被修改。")
    }
    if quarantine { progress("quarantine"); try removeQuarantine(prepared) }
    let replacing = try replacementExists(at: destination, bundleID: bundleID)
    try checkSigningChange(destination, bundleID: bundleID, incoming: copiedSignature, approval: signerApproval)
    progress("replacing")
    // Both paths are on the same volume. A failed swap leaves the old app in place;
    // on success it moves into our private temporary directory for cleanup.
    let flags = replacing ? RENAME_SWAP : RENAME_EXCL
    guard renamex_np(prepared.path, destination.path, UInt32(flags)) == 0 else {
        let code = errno
        if code == EACCES || code == EPERM {
            try fail("permission_required", "当前用户无权安装或替换应用，需要管理员授权。")
        }
        if code == EEXIST || code == ENOENT {
            try fail("changed", "安装目标已变化，请重试；现有应用未被修改。")
        }
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }
    return destination
}

func selfUpdate(_ source: URL, destination: URL, parentPID: pid_t, version: String, job: URL, user: uid_t, channel: String) throws {
    let identity = "win.huarun.huarunwin"
    guard source == source.resolvingSymlinksInPath().standardizedFileURL,
          destination == destination.resolvingSymlinksInPath().standardizedFileURL,
          try validateBundle(source) == identity, try validateBundle(destination) == identity,
          user > 0, parentPID > 1,
          let running = NSRunningApplication(processIdentifier: parentPID),
          running.bundleURL?.resolvingSymlinksInPath().standardizedFileURL == destination else {
        try fail("update_identity", "无法确认当前客户端与更新应用的身份。")
    }
    func check(_ incoming: URL) throws {
        guard try validateBundle(incoming) == identity,
              let info = NSDictionary(contentsOf: incoming.appendingPathComponent("Contents/Info.plist")),
              info["CFBundleShortVersionString"] as? String == version.components(separatedBy: "-")[0],
              let build = NSDictionary(contentsOf: incoming.appendingPathComponent("Contents/Resources/huarunwin-build.plist")),
              build["version"] as? String == version, build["channel"] as? String == channel else {
            try fail("update_identity", "更新应用的标识或版本不匹配。")
        }
        if let current = NSDictionary(contentsOf: destination.appendingPathComponent("Contents/Info.plist")),
           let oldVersion = current["CFBundleShortVersionString"] as? String,
           let newVersion = info["CFBundleShortVersionString"] as? String {
            let order = newVersion.compare(oldVersion, options: .numeric)
            if order == .orderedAscending || (order == .orderedSame &&
                (info["CFBundleVersion"] as? String ?? "0").compare(current["CFBundleVersion"] as? String ?? "0", options: .numeric) == .orderedAscending) {
                try fail("update_downgrade", "该更新包比当前安装的华润赢更旧。")
            }
        }
        let old = signingInfo(destination, assess: false), new = signingInfo(incoming, assess: false)
        guard ["valid", "adhoc"].contains(new["signature"] ?? ""),
              old["signature"] != "valid" ||
                (new["signature"] == "valid" && !(old["teamIdentifier"] ?? "").isEmpty && old["teamIdentifier"] == new["teamIdentifier"]) else {
            try fail("update_signature", "更新应用的签名无效或与当前开发者不兼容。")
        }
    }
    try check(source)
    let parent = destination.deletingLastPathComponent()
    try requireSpace(at: parent, bytes: bundleBytes(source))
    let stage = parent.appendingPathComponent(".huarun-update-" + UUID().uuidString)
    try files.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    var keepBackup = false
    defer { if !keepBackup { try? files.removeItem(at: stage) } }
    let prepared = stage.appendingPathComponent(destination.lastPathComponent)
    try files.copyItem(at: source, to: prepared)
    try check(prepared)
    try removeQuarantine(prepared)
    guard !files.fileExists(atPath: job.appendingPathComponent("cancel").path) else { return }
    try "ready".write(to: job.appendingPathComponent("ready"), atomically: true, encoding: .utf8)
    let deadline = ProcessInfo.processInfo.systemUptime + 120
    while kill(parentPID, 0) == 0 || errno == EPERM {
        guard !files.fileExists(atPath: job.appendingPathComponent("cancel").path),
              ProcessInfo.processInfo.systemUptime < deadline else {
            try fail("update_cancelled", "客户端尚未退出，更新已取消。")
        }
        Thread.sleep(forTimeInterval: 0.1)
    }
    guard !files.fileExists(atPath: job.appendingPathComponent("cancel").path) else { return }
    try check(prepared)
    guard !NSWorkspace.shared.runningApplications.contains(where: {
        $0.processIdentifier != parentPID && kill($0.processIdentifier, 0) == 0 &&
          $0.bundleURL?.resolvingSymlinksInPath().standardizedFileURL == destination
    }) else { try fail("running", "另一个客户端仍在运行，更新未执行。") }
    guard renamex_np(prepared.path, destination.path, UInt32(RENAME_SWAP)) == 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    keepBackup = true
    try prepared.path.write(to: job.appendingPathComponent("backup-path"), atomically: true, encoding: .utf8)
    if geteuid() == 0 {
        guard let account = getpwuid(user), initgroups(account.pointee.pw_name, Int32(bitPattern: account.pointee.pw_gid)) == 0,
              setgid(account.pointee.pw_gid) == 0, setuid(user) == 0 else {
            try fail("update_launch", "更新已安装，请从原路径重新打开华润赢。")
        }
    }
    try "installed".write(to: job.appendingPathComponent("result"), atomically: true, encoding: .utf8)
    _ = try run("/usr/bin/open", ["-n", destination.path], timeout: 30)
}

var arguments = Array(CommandLine.arguments.dropFirst())
if arguments.last == "--progress" { reportsProgress = true; arguments.removeLast() }
do {
    if arguments.count == 8 && arguments[0] == "self-update",
       let parentPID = Int32(arguments[3]), let user = UInt32(arguments[6]) {
        let job = URL(fileURLWithPath: arguments[5]).standardizedFileURL
        do {
            try selfUpdate(URL(fileURLWithPath: arguments[1]).standardizedFileURL,
                           destination: URL(fileURLWithPath: arguments[2]).standardizedFileURL,
                           parentPID: parentPID, version: arguments[4], job: job, user: user, channel: arguments[7])
        } catch {
            let message = (error as? InstallerFailure)?.message ?? error.localizedDescription
            try? message.write(to: job.appendingPathComponent("error.txt"), atomically: true, encoding: .utf8)
            throw error
        }
    } else if arguments.count == 2 && arguments[0] == "prepare" {
        let result = try prepare(URL(fileURLWithPath: arguments[1]).resolvingSymlinksInPath().standardizedFileURL)
        progress("signature")
        let info = signingInfo(result)
        progress("signature", info)
        output(info.merging(["path": result.path]) { _, new in new })
    } else if [3, 4].contains(arguments.count) && arguments[0] == "commit" && ["true", "false"].contains(arguments[2]) {
        var approval: [String: String]?
        if arguments.count == 4 {
            guard let data = arguments[3].data(using: .utf8), let value = try JSONSerialization.jsonObject(with: data) as? [String: String],
                  Set(value.keys) == Set(["path", "bundleIdentifier", "oldIdentity", "newIdentity"]) else { try fail("arguments", "签名确认信息无效。") }
            approval = value
        }
        let result = try commit(URL(fileURLWithPath: arguments[1]).standardizedFileURL, quarantine: arguments[2] == "true", signerApproval: approval)
        output(["path": result.path])
    } else {
        try fail("arguments", "安装助手参数无效。")
    }
} catch let error as InstallerFailure {
    output(error.details.merging(["code": error.code, "message": error.message]) { _, value in value }); exit(1)
} catch {
    output(["code": "installation", "message": "安装未完成：" + error.localizedDescription]); exit(1)
}
