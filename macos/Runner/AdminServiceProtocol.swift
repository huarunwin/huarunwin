import Foundation
import Security
import Darwin

// Deliberately expose operations, never a command line or an executable path.
@objc(HuarunAdminServiceProtocol) protocol AdminServiceProtocol {
  func ping(reply: @escaping ([String: String]) -> Void)
  func install(source: String, quarantine: Bool, approval: [String: String], reply: @escaping ([String: String]) -> Void)
  func trash(approval: [String: String], reply: @escaping ([String: String]) -> Void)
  func update(source: String, version: String, channel: String, reply: @escaping ([String: String]) -> Void)
  func disable(reply: @escaping ([String: String]) -> Void)
}

enum AdminServiceIdentity {
  static let identifier = "win.huarun.huarunwin.installer"
  static let appIdentifier = "win.huarun.huarunwin"
  static let directory = URL(fileURLWithPath: "/Library/PrivilegedHelperTools/" + identifier, isDirectory: true)
  static let executable = directory.appendingPathComponent("HuarunInstaller")
  static let configuration = directory.appendingPathComponent("client.plist")
  static let launchPlist = URL(fileURLWithPath: "/Library/LaunchDaemons/" + identifier + ".plist")
  static let protocolVersion = "1"

  static func error(_ code: String, _ message: String) -> NSError {
    NSError(domain: identifier, code: 1, userInfo: [NSLocalizedDescriptionKey: message, "installerCode": code])
  }

  // Every installed trust anchor is root owned and outside user writable paths.
  // Read using the checked descriptor so a replaced symlink is never followed.
  static func checkRootPath(_ url: URL, directory: Bool) throws {
    var attributes = stat()
    guard lstat(url.path, &attributes) == 0, attributes.st_uid == 0,
          attributes.st_mode & 0o022 == 0,
          attributes.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG),
          url.standardizedFileURL == url.resolvingSymlinksInPath().standardizedFileURL else {
      throw error("helper_integrity", "管理员助手的文件归属或权限无效，请重试并重新确认系统授权。")
    }
  }

  static func checkInstallation() throws {
    for path in ["/Library", "/Library/PrivilegedHelperTools", directory.path, "/Library/LaunchDaemons"] {
      try checkRootPath(URL(fileURLWithPath: path), directory: true)
    }
    try checkRootPath(executable, directory: false)
    try checkRootPath(launchPlist, directory: false)
    try checkRootPath(configuration, directory: false)
  }

  static func readConfiguration(complete: Bool = true) throws -> [String: String] {
    if complete { try checkInstallation() }
    else { try checkRootPath(configuration, directory: false) }
    let fd = open(configuration.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw error("helper_integrity", "无法读取管理员助手配置。") }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    var attributes = stat()
    guard fstat(fd, &attributes) == 0, attributes.st_uid == 0,
          attributes.st_mode & 0o022 == 0, attributes.st_mode & S_IFMT == S_IFREG,
          attributes.st_size > 0, attributes.st_size < 64 * 1024,
          let data = try handle.read(upToCount: 64 * 1024),
          let config = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String],
          config["protocol"] == protocolVersion, let user = UInt32(config["user"] ?? ""), user > 0,
          let requirement = config["requirement"], !requirement.isEmpty else {
      throw error("helper_integrity", "管理员助手配置无效，请重试并重新确认系统授权。")
    }
    var parsed: SecRequirement?
    guard SecRequirementCreateWithString(requirement as CFString, [], &parsed) == errSecSuccess else {
      throw error("helper_integrity", "管理员助手签名配置无效，请重试并重新确认系统授权。")
    }
    return config
  }

  static func code(at url: URL, requirement: String? = nil) throws -> SecStaticCode {
    var code: SecStaticCode?
    var expected: SecRequirement?
    if let requirement {
      guard SecRequirementCreateWithString(requirement as CFString, [], &expected) == errSecSuccess else {
        throw error("helper_identity", "管理员助手的签名要求无效。")
      }
    }
    guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
          SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode), expected) == errSecSuccess else {
      throw error("helper_identity", "客户端或管理员助手签名已变化，请重试并重新确认系统授权。")
    }
    return code
  }

  static func requirement(at url: URL, exact: Bool = false) throws -> String {
    let code = try self.code(at: url)
    if exact {
      var information: CFDictionary?
      guard SecCodeCopySigningInformation(code, [], &information) == errSecSuccess,
            let values = information as? [String: Any], let hash = values[kSecCodeInfoUnique as String] as? Data else {
        throw error("helper_identity", "无法确认管理员助手的精确签名。")
      }
      return "cdhash H\"" + hash.map { String(format: "%02x", $0) }.joined() + "\""
    }
    var requirement: SecRequirement?
    var text: CFString?
    guard SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess, let requirement,
          SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text else {
      throw error("helper_identity", "无法确认客户端或管理员助手的签名。")
    }
    return text as String
  }

  static func clientApplication(pid: pid_t, requirement: String) throws -> URL {
    // A launch daemon has no GUI login session. Resolve the authenticated
    // process through Security rather than the daemon's NSWorkspace session.
    var guest: SecCode?, staticCode: SecStaticCode?, path: CFURL?, expected: SecRequirement?
    guard SecRequirementCreateWithString(requirement as CFString, [], &expected) == errSecSuccess,
          SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid as String: pid] as CFDictionary, [], &guest) == errSecSuccess,
          let guest, SecCodeCheckValidity(guest, [], expected) == errSecSuccess,
          SecCodeCopyStaticCode(guest, [], &staticCode) == errSecSuccess, let staticCode,
          SecCodeCopyPath(staticCode, [], &path) == errSecSuccess, let path else {
      throw error("helper_identity", "无法确认连接的华润赢客户端。")
    }
    var app = path as URL
    if app.deletingLastPathComponent().lastPathComponent == "MacOS",
       app.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "Contents" {
      app = app.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    var information: CFDictionary?
    guard app.pathExtension == "app", app.path == app.resolvingSymlinksInPath().standardizedFileURL.path,
          SecCodeCopySigningInformation(staticCode, [], &information) == errSecSuccess,
          let values = information as? [String: Any], values[kSecCodeInfoIdentifier as String] as? String == appIdentifier else {
      throw error("helper_identity", "连接进程不是华润赢应用。")
    }
    _ = try code(at: app, requirement: requirement)
    return app
  }
}
