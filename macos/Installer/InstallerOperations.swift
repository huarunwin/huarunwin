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

func runningApplicationPIDs(at app: URL) throws -> [pid_t] {
    guard getuid() == 0 else {
        return NSWorkspace.shared.runningApplications.filter {
            !$0.isTerminated && $0.bundleURL?.resolvingSymlinksInPath().standardizedFileURL.path == app.path
        }.map { $0.processIdentifier }
    }
    // A daemon has no GUI NSWorkspace. Inspect kernel executable paths only
    // during the requested operation, including other users running this app.
    let originalUser = geteuid()
    if originalUser != 0 && seteuid(0) != 0 { try fail("caller", "无法核对应用运行状态。") }
    defer { if originalUser != 0 && seteuid(originalUser) != 0 { _exit(1) } }
    return try kernelApplicationPIDs(at: app)
}

func kernelApplicationPIDs(at app: URL) throws -> [pid_t] {
    let root = app.resolvingSymlinksInPath().standardizedFileURL.path
    let capacity = proc_listallpids(nil, 0) + 128
    guard capacity > 128 else { try fail("running_check", "无法核对应用运行状态，请重试。") }
    var processes = [pid_t](repeating: 0, count: Int(capacity))
    let count = processes.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
    guard count >= 0, count < capacity else { try fail("running_check", "应用运行状态已变化，请重试。") }
    // PROC_PIDPATHINFO_MAXSIZE is a C expression macro not imported by Swift.
    var path = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
    var running: [pid_t] = []
    for pid in processes.prefix(Int(count)) where pid > 1 {
        let length = path.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
        if length > 0 {
            let raw = String(decoding: path.prefix(Int(length)).prefix(while: { $0 != 0 }), as: UTF8.self)
            let executable = URL(fileURLWithPath: raw).resolvingSymlinksInPath().standardizedFileURL.path
            if executable.hasPrefix(root + "/") { running.append(pid) }
        }
    }
    return running
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
    guard try runningApplicationPIDs(at: destination).isEmpty else {
        try fail("running", "\(destination.deletingPathExtension().lastPathComponent) 正在运行，退出后才能继续安装。", details: [
            "path": destination.path,
            "bundleIdentifier": bundleID,
        ])
    }
    return true
}

func commit(_ source: URL, quarantine: Bool, signerApproval: [String: String]? = nil, user: uid_t? = nil) throws -> URL {
    let stage = source.deletingLastPathComponent()
    guard stage.lastPathComponent.hasPrefix("huarun-install-"),
          source == source.resolvingSymlinksInPath().standardizedFileURL else {
        try fail("package", "安装暂存路径无效。")
    }
    if let user { try checkServiceStage(source, user: user) }
    let stageAttrs = try files.attributesOfItem(atPath: stage.path)
    guard (stageAttrs[.posixPermissions] as? NSNumber)?.intValue == 0o700 else {
        try fail("package", "安装暂存目录的权限无效。")
    }
    progress("validating")
    let bundleID = try asInstallerUser(user) { try validateBundle(source) }
    if user != nil && bundleID == AdminServiceIdentity.appIdentifier {
        try fail("update_identity", "请通过华润赢的客户端更新入口安装自身更新。")
    }
    let destination = URL(fileURLWithPath: "/Applications", isDirectory: true).appendingPathComponent(source.lastPathComponent)
    _ = try asInstallerUser(user) { try replacementExists(at: destination, bundleID: bundleID) }
    progress("signature")
    let signature = try asInstallerUser(user) { signingInfo(source, assess: false) }
    try asInstallerUser(user) { try checkSigningChange(destination, bundleID: bundleID, incoming: signature, approval: signerApproval) }
    try requireSpace(at: URL(fileURLWithPath: "/Applications"), bytes: asInstallerUser(user) { try bundleBytes(source) })
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
    if let user, chown(temporary.path, user, gid_t.max) != 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    // Read and copy all untrusted content as the original user. In particular,
    // a raced source symlink must never disclose root-only files or create a
    // root-owned setuid executable. Only the final fixed-directory rename is root.
    try asInstallerUser(user) { try files.copyItem(at: source, to: prepared) }
    if user != nil {
        guard chown(temporary.path, 0, 0) == 0, chmod(temporary.path, 0o711) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }
    guard try asInstallerUser(user, { try validateBundle(prepared) }) == bundleID else {
        try fail("package", "安装包在复制过程中已变化，请重新选择安装包。")
    }
    let copiedSignature = try asInstallerUser(user) { signingInfo(prepared, assess: false) }
    guard copiedSignature["signature"] == signature["signature"], copiedSignature["teamIdentifier"] == signature["teamIdentifier"] else {
        try fail("changed", "应用签名在复制过程中已变化，请重试；现有应用未被修改。")
    }
    if quarantine { progress("quarantine"); try asInstallerUser(user) { try removeQuarantine(prepared) } }
    let replacing = try asInstallerUser(user) { try replacementExists(at: destination, bundleID: bundleID) }
    try asInstallerUser(user) { try checkSigningChange(destination, bundleID: bundleID, incoming: copiedSignature, approval: signerApproval) }
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

func trashApplication(_ approval: [String: String], user: uid_t, clientPID: pid_t) throws -> URL {
    guard geteuid() == 0, user > 0, clientPID > 1,
          Set(approval.keys) == Set(["path", "bundleIdentifier", "version", "device", "inode", "trash"]),
          let account = getpwuid(user) else {
        try fail("arguments", "卸载授权信息无效，请重新选择应用。")
    }
    let home = URL(fileURLWithPath: String(cString: account.pointee.pw_dir), isDirectory: true).standardizedFileURL
    var process = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.size
    var query: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, clientPID]
    guard sysctl(&query, UInt32(query.count), &process, &size, nil, 0) == 0,
          size == MemoryLayout<kinfo_proc>.size,
          process.kp_eproc.e_ucred.cr_uid == user, process.kp_eproc.e_pcred.p_ruid == user,
          let configuration = try? AdminServiceIdentity.readConfiguration(),
          configuration["user"] == String(user),
          (try? AdminServiceIdentity.clientApplication(pid: clientPID, requirement: configuration["requirement"]!)) != nil else {
        try fail("caller", "无法确认发起卸载的客户端与用户，请重新打开华润赢后重试。")
    }
    let app = URL(fileURLWithPath: approval["path"]!).standardizedFileURL
    let identifier = approval["bundleIdentifier"]!
    let parent = app.deletingLastPathComponent()
    let roots = [URL(fileURLWithPath: "/Applications", isDirectory: true), home.appendingPathComponent("Applications", isDirectory: true)]
    let infoURL = app.appendingPathComponent("Contents/Info.plist")
    let infoValues = try infoURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard roots.contains(parent), app.pathExtension.lowercased() == "app",
          app == app.resolvingSymlinksInPath().standardizedFileURL,
          !identifier.isEmpty, !identifier.lowercased().hasPrefix("com.apple."), identifier != "win.huarun.huarunwin",
          infoURL.resolvingSymlinksInPath().path.hasPrefix(app.path + "/"),
          infoValues.isRegularFile == true, let infoSize = infoValues.fileSize, infoSize <= 4 * 1024 * 1024,
          let info = NSDictionary(contentsOf: infoURL), info["CFBundleIdentifier"] as? String == identifier,
          info["CFBundleShortVersionString"] as? String == approval["version"] else {
        try fail("changed", "应用路径或身份已变化，或属于受保护的应用，请刷新后重新选择。")
    }
    let trash = URL(fileURLWithPath: approval["trash"]!, isDirectory: true).standardizedFileURL
    var trashRoots = [home.appendingPathComponent(".Trash", isDirectory: true)]
    if let volume = try app.resourceValues(forKeys: [.volumeURLKey]).volume {
        trashRoots.append(volume.appendingPathComponent(".Trashes", isDirectory: true).appendingPathComponent(String(user), isDirectory: true))
    }
    guard trashRoots.contains(trash), trash == trash.resolvingSymlinksInPath().standardizedFileURL else {
        try fail("trash", "无法安全确认当前用户的废纸篓，请在 Finder 中手动处理。")
    }
    // Never create a root-owned Trash, copy/delete across volumes, follow a
    // replacement symlink, or overwrite an existing item in the user's Trash.
    // Directory-relative rename needs search access, not directory contents.
    // O_RDONLY on the user's Trash requests protected enumeration even as root.
    let sourceFD = open(parent.path, O_SEARCH | O_NOFOLLOW | O_CLOEXEC)
    guard sourceFD >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    defer { close(sourceFD) }
    let trashFD = open(trash.path, O_SEARCH | O_NOFOLLOW | O_CLOEXEC)
    guard trashFD >= 0 else {
        let code = errno
        if code == EPERM || code == EACCES {
            try fail("trash_permission", "macOS 拒绝访问当前用户的废纸篓，管理员授权不能替代系统隐私权限。请在 Finder 中手动移走所选应用。")
        }
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }
    defer { close(trashFD) }
    var sourceAttributes = stat(), trashAttributes = stat()
    guard fstat(sourceFD, &sourceAttributes) == 0, fstat(trashFD, &trashAttributes) == 0,
          trashAttributes.st_uid == user, trashAttributes.st_mode & 0o077 == 0,
          trashAttributes.st_mode & S_IFMT == S_IFDIR else {
        try fail("trash", "废纸篓的归属或权限无效，请在 Finder 中手动处理。")
    }
    guard sourceAttributes.st_dev == trashAttributes.st_dev else {
        try fail("trash", "应用与废纸篓不在同一磁盘卷，请在 Finder 中手动处理。")
    }
    func recheck() throws {
        var current = stat()
        guard fstatat(sourceFD, app.lastPathComponent, &current, AT_SYMLINK_NOFOLLOW) == 0,
              current.st_mode & S_IFMT == S_IFDIR, current.st_flags & UInt32(SF_RESTRICTED) == 0,
              String(current.st_dev) == approval["device"], String(current.st_ino) == approval["inode"],
              let currentInfo = NSDictionary(contentsOf: infoURL),
              currentInfo["CFBundleIdentifier"] as? String == identifier,
              currentInfo["CFBundleShortVersionString"] as? String == approval["version"] else {
            try fail("changed", "授权期间卸载目标已变化，请刷新后重新选择。")
        }
        guard try runningApplicationPIDs(at: app).isEmpty else {
            try fail("running", "请先保存内容并退出所选应用，再重试卸载。")
        }
    }
    try recheck()
    func move(to name: String) throws -> Bool {
        if renameatx_np(sourceFD, app.lastPathComponent, trashFD, name, UInt32(RENAME_EXCL)) == 0 { return true }
        let code = errno
        if code == EEXIST { return false }
        if code == EPERM || code == EACCES {
            try fail("app_management_permission", "macOS 仍拒绝移动所选应用。请在系统设置“隐私与安全性 → App 管理”中允许华润赢后重试。若应用被锁定或受其他保护，请在 Finder 中手动处理。")
        }
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }
    var name = app.lastPathComponent
    if try !move(to: name) {
        name = app.deletingPathExtension().lastPathComponent + " (" + UUID().uuidString + ").app"
        try recheck()
        guard try move(to: name) else {
            try fail("trash", "废纸篓中存在同名应用，请重试或在 Finder 中手动处理。")
        }
    }
    return trash.appendingPathComponent(name)
}

func selfUpdate(_ source: URL, destination: URL, parentPID: pid_t, version: String, job: URL, user: uid_t, channel: String) throws {
    let identity = "win.huarun.huarunwin"
    let fileUser: uid_t? = geteuid() == 0 ? user : nil
    if fileUser != nil {
        try checkServiceStage(source, user: user)
        guard destination.deletingLastPathComponent().path == "/Applications" else {
            try fail("update_path", "需要管理员权限的客户端更新仅支持 /Applications 中的华润赢。请先移到“应用程序”文件夹。")
        }
    }
    guard source == source.resolvingSymlinksInPath().standardizedFileURL,
          destination == destination.resolvingSymlinksInPath().standardizedFileURL,
          try asInstallerUser(fileUser, { try validateBundle(source) }) == identity,
          try asInstallerUser(fileUser, { try validateBundle(destination) }) == identity,
          (fileUser == nil || job == source.deletingLastPathComponent()),
          user > 0, parentPID > 1,
          try runningApplicationPIDs(at: destination).contains(parentPID) else {
        try fail("update_identity", "无法确认当前客户端与更新应用的身份。")
    }
    func check(_ incoming: URL) throws {
      try asInstallerUser(fileUser) {
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
    }
    try check(source)
    let parent = destination.deletingLastPathComponent()
    try requireSpace(at: parent, bytes: asInstallerUser(fileUser) { try bundleBytes(source) })
    let stage = parent.appendingPathComponent(".huarun-update-" + UUID().uuidString)
    try files.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    var keepBackup = false
    defer { if !keepBackup { try? files.removeItem(at: stage) } }
    let prepared = stage.appendingPathComponent(destination.lastPathComponent)
    if let fileUser, chown(stage.path, fileUser, gid_t.max) != 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    try asInstallerUser(fileUser) { try files.copyItem(at: source, to: prepared) }
    if fileUser != nil {
        guard chown(stage.path, 0, 0) == 0, chmod(stage.path, 0o711) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }
    try check(prepared)
    try asInstallerUser(fileUser) { try removeQuarantine(prepared) }
    guard !files.fileExists(atPath: job.appendingPathComponent("cancel").path) else { return }
    try asInstallerUser(fileUser) { try "ready".write(to: job.appendingPathComponent("ready"), atomically: true, encoding: .utf8) }
    if fileUser != nil { output(["event": "update_ready", "path": job.path]) }
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
    guard try runningApplicationPIDs(at: destination).filter({ $0 != parentPID }).isEmpty else {
        try fail("running", "另一个客户端仍在运行，更新未执行。")
    }
    guard renamex_np(prepared.path, destination.path, UInt32(RENAME_SWAP)) == 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    keepBackup = true
    try asInstallerUser(fileUser) { try prepared.path.write(to: job.appendingPathComponent("backup-path"), atomically: true, encoding: .utf8) }
    if fileUser != nil {
        do { try migrateAdminServiceTrust(to: destination, user: user) }
        catch { try? asInstallerUser(fileUser) { try "管理员助手身份迁移失败，下次需要权限时请重新确认系统授权。".write(to: job.appendingPathComponent("helper-warning.txt"), atomically: true, encoding: .utf8) } }
    }
    if geteuid() == 0 {
        try asInstallerUser(user) { try "installed".write(to: job.appendingPathComponent("result"), atomically: true, encoding: .utf8) }
        // Enter the user's GUI bootstrap namespace before the child permanently
        // drops real/saved IDs. No downloaded executable is ever launched as root.
        let launch = try InstallerProcess.run("/bin/launchctl", ["asuser", String(user), AdminServiceIdentity.executable.path,
          "user-tool", String(user), "/usr/bin/open", "-n", destination.path], timeout: 30)
        guard launch.status == 0 else { try fail("update_launch", "更新已安装，请从原路径重新打开华润赢。") }
        return
    }
    try "installed".write(to: job.appendingPathComponent("result"), atomically: true, encoding: .utf8)
    _ = try run("/usr/bin/open", ["-n", destination.path], timeout: 30)
}
