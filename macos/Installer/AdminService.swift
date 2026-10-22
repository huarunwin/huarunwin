import AppKit
import Security
import Darwin

// Privilege changes are confined to isolated CLI workers. The XPC listener
// never changes identity, parses an archive, or executes user supplied code.
func asInstallerUser<T>(_ user: uid_t?, _ body: () throws -> T) throws -> T {
  guard let user, geteuid() == 0 else { return try body() }
  guard user > 0, let account = getpwuid(user) else { try fail("caller", "无法确认安装用户。") }
  let group = account.pointee.pw_gid
  guard initgroups(account.pointee.pw_name, Int32(bitPattern: group)) == 0,
        setegid(group) == 0, seteuid(user) == 0 else { try fail("caller", "无法切换到原用户检查文件。") }
  defer {
    // Continuing a privileged worker in an unexpected identity is unsafe.
    if seteuid(0) != 0 || setegid(0) != 0 { _exit(1) }
  }
  return try body()
}

func checkServiceStage(_ source: URL, user: uid_t) throws {
  let stage = source.deletingLastPathComponent()
  var attributes = stat()
  guard user > 0, source.pathExtension == "app", stage.lastPathComponent.hasPrefix("huarun-install-"),
        source.path == source.resolvingSymlinksInPath().standardizedFileURL.path,
        lstat(stage.path, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFDIR,
        attributes.st_uid == user, attributes.st_mode & 0o777 == 0o700 else {
    try fail("package", "安装暂存目录已变化，请重新选择安装包。")
  }
}

private func helperPayload(in app: URL, user: uid_t, expected: String? = nil) throws -> (Data, String, String) {
  try asInstallerUser(user) {
    guard app == app.resolvingSymlinksInPath().standardizedFileURL,
          let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
          info["CFBundleIdentifier"] as? String == AdminServiceIdentity.appIdentifier else {
      try fail("helper_identity", "只能为华润赢启用管理员助手。")
    }
    _ = try AdminServiceIdentity.code(at: app, requirement: expected)
    let clientRequirement = try AdminServiceIdentity.requirement(at: app)
    let helper = app.appendingPathComponent("Contents/Helpers/HuarunInstaller")
    let requirement = try AdminServiceIdentity.requirement(at: helper, exact: true)
    let fd = open(helper.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { try fail("helper_identity", "无法读取内置管理员助手。") }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    var attributes = stat()
    guard fstat(fd, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFREG,
          attributes.st_size > 0, attributes.st_size <= 64 * 1024 * 1024,
          let data = try handle.read(upToCount: 64 * 1024 * 1024 + 1), data.count == attributes.st_size else {
      try fail("helper_identity", "内置管理员助手格式无效。")
    }
    // Check the enclosing seal again after reading the complete executable.
    _ = try AdminServiceIdentity.code(at: app, requirement: clientRequirement)
    return (data, clientRequirement, requirement)
  }
}

private func writeServiceConfiguration(_ config: [String: String]) throws {
  let data = try PropertyListSerialization.data(fromPropertyList: config, format: .xml, options: 0)
  try data.write(to: AdminServiceIdentity.configuration, options: .atomic)
  guard chmod(AdminServiceIdentity.configuration.path, 0o644) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}

private func writeServiceExecutable(_ data: Data, requirement: String) throws {
  let temporary = AdminServiceIdentity.directory.appendingPathComponent(".helper-" + UUID().uuidString)
  defer { try? files.removeItem(at: temporary) }
  try data.write(to: temporary, options: .withoutOverwriting)
  guard chmod(temporary.path, 0o755) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
  _ = try AdminServiceIdentity.code(at: temporary, requirement: requirement)
  guard rename(temporary.path, AdminServiceIdentity.executable.path) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}

private func lockAdminService() throws -> Int32 {
  let fd = open(AdminServiceIdentity.directory.appendingPathComponent("transaction.lock").path,
                O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
  guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
  var attributes = stat()
  guard fstat(fd, &attributes) == 0, attributes.st_uid == 0,
        attributes.st_mode & S_IFMT == S_IFREG, attributes.st_mode & 0o077 == 0,
        flock(fd, LOCK_EX | LOCK_NB) == 0 else {
    close(fd); try fail("busy", "管理员助手正在处理安装操作，请完成后再重试。")
  }
  return fd
}

func enableAdminService(app: URL, user: uid_t) throws {
  guard geteuid() == 0, user > 0 else { try fail("permission", "启用助手需要首次系统管理员授权。") }
  let (data, requirement, helperRequirement) = try helperPayload(in: app, user: user)
  for path in ["/Library/PrivilegedHelperTools", "/Library/LaunchDaemons"] {
    if !files.fileExists(atPath: path) {
      try files.createDirectory(atPath: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
    }
    try AdminServiceIdentity.checkRootPath(URL(fileURLWithPath: path), directory: true)
  }
  if !files.fileExists(atPath: AdminServiceIdentity.directory.path) {
    try files.createDirectory(at: AdminServiceIdentity.directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
  }
  try AdminServiceIdentity.checkRootPath(AdminServiceIdentity.directory, directory: true)
  let transaction = try lockAdminService()
  defer { close(transaction) }
  if files.fileExists(atPath: AdminServiceIdentity.configuration.path) {
    // A newly confirmed system authorization can repair partial/corrupt helper
    // files. A valid registration belonging to another user is left intact.
    if let old = try? AdminServiceIdentity.readConfiguration(complete: false), old["user"] != String(user) {
      try fail("helper_user", "助手已由其他本机用户授权，请联系管理员处理已有授权。")
    }
    _ = try InstallerProcess.run("/bin/launchctl", ["bootout", "system/" + AdminServiceIdentity.identifier], timeout: 15)
  }
  try writeServiceExecutable(data, requirement: helperRequirement)
  try writeServiceConfiguration(["protocol": AdminServiceIdentity.protocolVersion, "user": String(user),
                                 "requirement": requirement, "helperRequirement": helperRequirement])
  let plist: [String: Any] = ["Label": AdminServiceIdentity.identifier,
    "ProgramArguments": [AdminServiceIdentity.executable.path, "serve"],
    "MachServices": [AdminServiceIdentity.identifier: true], "ProcessType": "Interactive",
    "UserName": "root", "Umask": 0o077,
    "AssociatedBundleIdentifiers": [AdminServiceIdentity.appIdentifier]]
  try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    .write(to: AdminServiceIdentity.launchPlist, options: .atomic)
  guard chmod(AdminServiceIdentity.launchPlist.path, 0o644) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
  let launched = try InstallerProcess.run("/bin/launchctl", ["bootstrap", "system", AdminServiceIdentity.launchPlist.path], timeout: 20)
  guard launched.status == 0 else { try fail("helper_enable", "系统未能启动管理员助手，请在系统设置中检查后台项目后重试。") }
  output(["path": AdminServiceIdentity.executable.path])
}

// Called only after an already authenticated client's validated self-update has
// swapped successfully. This also preserves ad-hoc trust across in-app updates.
func migrateAdminServiceTrust(to app: URL, user: uid_t) throws {
  guard geteuid() == 0, files.fileExists(atPath: AdminServiceIdentity.configuration.path) else { return }
  var config = try AdminServiceIdentity.readConfiguration()
  guard config["user"] == String(user) else { try fail("helper_user", "更新用户与管理员助手授权不一致。") }
  let (_, requirement, _) = try helperPayload(in: app, user: user)
  config["requirement"] = requirement
  try writeServiceConfiguration(config)
}

final class AdminService: NSObject, NSXPCListenerDelegate {
  private let config: [String: String]
  private let operations = DispatchQueue(label: "win.huarun.admin.operations")
  private let lock = NSLock()
  private var busy = false

  init(configuration: [String: String]) { config = configuration }

  func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
    guard connection.effectiveUserIdentifier > 0,
          String(connection.effectiveUserIdentifier) == config["user"] else { return false }
    connection.setCodeSigningRequirement(config["requirement"]!)
    connection.exportedInterface = NSXPCInterface(with: AdminServiceProtocol.self)
    connection.exportedObject = AdminSession(service: self, user: connection.effectiveUserIdentifier, pid: connection.processIdentifier)
    connection.resume()
    return true
  }

  func execute(user: uid_t, pid: pid_t, operation: String, arguments: [String], reply: @escaping ([String: String]) -> Void) {
    lock.lock()
    guard !busy else { lock.unlock(); reply(["code": "busy", "message": "另一个安装操作正在进行，请稍后重试。"]); return }
    busy = true; lock.unlock()
    operations.async {
      defer { self.lock.lock(); self.busy = false; self.lock.unlock() }
      var replied = false
      func finish(_ value: [String: String]) { if !replied { replied = true; reply(value) } }
      do {
        let app = try AdminServiceIdentity.clientApplication(pid: pid, requirement: self.config["requirement"]!)
        let transaction = try lockAdminService()
        defer { close(transaction) }
        if operation == "disable" {
          try AdminServiceIdentity.checkInstallation()
          for url in [AdminServiceIdentity.launchPlist, AdminServiceIdentity.configuration, AdminServiceIdentity.executable,
                      AdminServiceIdentity.directory.appendingPathComponent("transaction.lock")] {
            try files.removeItem(at: url)
          }
          try files.removeItem(at: AdminServiceIdentity.directory)
          finish(["status": "disabled"])
          DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            _ = try? InstallerProcess.run("/bin/launchctl", ["bootout", "system/" + AdminServiceIdentity.identifier], timeout: 15)
            exit(0)
          }
          return
        }
        var args: [String]
        switch operation {
        case "install": args = ["service-commit", arguments[0], String(user)] + Array(arguments.dropFirst())
        case "trash": args = ["trash", arguments[0], String(user), String(pid)]
        case "update":
          let source = URL(fileURLWithPath: arguments[0]).standardizedFileURL
          try checkServiceStage(source, user: user)
          args = ["service-update", source.path, app.path, String(pid), arguments[1], source.deletingLastPathComponent().path, String(user), arguments[2]]
        default: try fail("arguments", "不支持此管理员助手操作。")
        }
        let result = try InstallerProcess.run(AdminServiceIdentity.executable.path, args, onLine: { line in
          if operation == "update", let data = line.data(using: .utf8),
             let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: String], value["event"] == "update_ready" {
            finish(["path": value["path"]!])
          }
        })
        let messages = result.stdout.components(separatedBy: .newlines).compactMap { line -> [String: String]? in
          guard let data = line.data(using: .utf8) else { return nil }
          return (try? JSONSerialization.jsonObject(with: data)) as? [String: String]
        }
        if let failure = messages.last(where: { $0["code"] != nil }) { finish(failure) }
        else if result.status == 0 { finish(messages.last ?? ["status": "enabled"]) }
        else { finish(["code": "helper_operation", "message": "管理员助手操作未完成，请刷新核对后重试。"] ) }
        if operation == "update" {
          DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { exit(0) }
        }
      } catch {
        let code = (error as? InstallerFailure)?.code ?? (error as NSError).userInfo["installerCode"] as? String ?? "helper_operation"
        finish(["code": code, "message": (error as? InstallerFailure)?.message ?? error.localizedDescription])
      }
    }
  }
}

private final class AdminSession: NSObject, AdminServiceProtocol {
  let service: AdminService
  let user: uid_t
  let pid: pid_t
  init(service: AdminService, user: uid_t, pid: pid_t) { self.service = service; self.user = user; self.pid = pid }
  func ping(reply: @escaping ([String: String]) -> Void) { reply(["protocol": AdminServiceIdentity.protocolVersion]) }
  func install(source: String, quarantine: Bool, approval: [String: String], reply: @escaping ([String: String]) -> Void) {
    guard source.utf8.count < 4096, approval.count <= 4 else { reply(["code": "arguments", "message": "安装参数无效。"]); return }
    guard let data = try? JSONSerialization.data(withJSONObject: approval) else { return }
    service.execute(user: user, pid: pid, operation: "install", arguments: [source, quarantine ? "true" : "false", String(decoding: data, as: UTF8.self)], reply: reply)
  }
  func trash(approval: [String: String], reply: @escaping ([String: String]) -> Void) {
    guard approval.count == 6, let data = try? JSONSerialization.data(withJSONObject: approval), data.count < 16 * 1024 else {
      reply(["code": "arguments", "message": "卸载参数无效。"]); return
    }
    service.execute(user: user, pid: pid, operation: "trash", arguments: [String(decoding: data, as: UTF8.self)], reply: reply)
  }
  func update(source: String, version: String, channel: String, reply: @escaping ([String: String]) -> Void) {
    guard source.utf8.count < 4096, version.count < 128, ["release", "debug"].contains(channel) else {
      reply(["code": "arguments", "message": "更新参数无效。"]); return
    }
    service.execute(user: user, pid: pid, operation: "update", arguments: [source, version, channel], reply: reply)
  }
  func disable(reply: @escaping ([String: String]) -> Void) { service.execute(user: user, pid: pid, operation: "disable", arguments: [], reply: reply) }
}

func serveAdminService() throws -> Never {
  guard geteuid() == 0 else { try fail("permission", "管理员助手只能由系统服务启动。") }
  let config = try AdminServiceIdentity.readConfiguration()
  let listener = NSXPCListener(machServiceName: AdminServiceIdentity.identifier)
  let delegate = AdminService(configuration: config)
  listener.setConnectionCodeSigningRequirement(config["requirement"]!)
  listener.delegate = delegate
  listener.resume()
  withExtendedLifetime((listener, delegate)) { RunLoop.current.run() }
  exit(0)
}
