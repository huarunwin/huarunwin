import AppKit
import ServiceManagement

/// Called only on InstallerChannel's worker queue. Mutations are never retried
/// after an interrupted connection: their result may already have committed.
final class AdminHelper {
  private var bundledHelper: URL {
    Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/HuarunInstaller")
  }

  func status() -> [String: String] {
    guard FileManager.default.fileExists(atPath: AdminServiceIdentity.configuration.path) else {
      return ["status": "disabled"]
    }
    do {
      let config = try AdminServiceIdentity.readConfiguration()
      guard config["user"] == String(getuid()) else {
        return ["status": "unavailable", "message": "此助手已由其他本机用户授权，当前用户无法复用。请联系管理员处理已有授权。"]
      }
      _ = try AdminServiceIdentity.code(at: Bundle.main.bundleURL, requirement: config["requirement"])
      if SMAppService.statusForLegacyPlist(at: AdminServiceIdentity.launchPlist) == .requiresApproval {
        return ["status": "approvalRequired", "message": "请在系统设置的“登录项与扩展”中允许华润赢在后台运行。"]
      }
      return ["status": "enabled"]
    } catch {
      return ["status": "unavailable", "message": error.localizedDescription]
    }
  }

  func request(_ operation: (AdminServiceProtocol, @escaping ([String: String]) -> Void) -> Void,
               timeout: TimeInterval? = nil) throws -> [String: String] {
    let config = try AdminServiceIdentity.readConfiguration()
    guard config["user"] == String(getuid()) else {
      throw AdminServiceIdentity.error("helper_user", "管理员助手属于其他用户，无法复用此授权。")
    }
    _ = try AdminServiceIdentity.code(at: Bundle.main.bundleURL, requirement: config["requirement"])
    let expected = try AdminServiceIdentity.requirement(at: AdminServiceIdentity.executable, exact: true)
    let connection = NSXPCConnection(machServiceName: AdminServiceIdentity.identifier, options: .privileged)
    connection.remoteObjectInterface = NSXPCInterface(with: AdminServiceProtocol.self)
    connection.setCodeSigningRequirement(expected)
    let semaphore = DispatchSemaphore(value: 0), lock = NSLock()
    var response: [String: String]?
    func complete(_ value: [String: String]) {
      lock.lock(); defer { lock.unlock() }
      guard response == nil else { return }
      response = value; semaphore.signal()
    }
    let disconnected = ["code": "helper_connection", "message": "管理员助手连接中断。请刷新核对应用状态后重试；若系统已关闭后台运行，请在系统设置“通用 → 登录项与扩展”中允许华润赢。"]
    connection.interruptionHandler = { complete(disconnected) }
    connection.invalidationHandler = { complete(disconnected) }
    connection.resume()
    defer { connection.invalidate() }
    guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in complete(disconnected) }) as? AdminServiceProtocol else {
      throw AdminServiceIdentity.error("helper_connection", disconnected["message"]!)
    }
    operation(proxy) { value in
      guard connection.effectiveUserIdentifier == 0 else {
        complete(["code": "helper_identity", "message": "管理员助手未以系统服务身份运行。"]); return
      }
      complete(value)
    }
    if let timeout, semaphore.wait(timeout: .now() + timeout) == .timedOut {
      throw AdminServiceIdentity.error("helper_connection", disconnected["message"]!)
    }
    if timeout == nil { semaphore.wait() }
    lock.lock(); let value = response!; lock.unlock()
    if let code = value["code"] {
      throw NSError(domain: AdminServiceIdentity.identifier, code: 1,
        userInfo: [NSLocalizedDescriptionKey: value["message"] ?? "管理员助手操作失败。",
                   "installerCode": code, "installerDetails": value])
    }
    return value
  }

  func ensureEnabled(allowAuthorization: Bool) throws {
    let state = status()
    if state["status"] == "enabled" {
      let reachable: Bool
      do {
        let response = try request({ $0.ping(reply: $1) }, timeout: 5)
        guard response["protocol"] == AdminServiceIdentity.protocolVersion else {
          throw AdminServiceIdentity.error("helper_version", "管理员助手需要更新，请再次确认系统授权。")
        }
        reachable = true
      }
      catch {
        if !allowAuthorization {
          // Only a status probe has run, so a separate authorization can safely
          // repair the service before any installation or uninstall is sent.
          throw AdminServiceIdentity.error("permission_required", "管理员助手暂不可用，需要重新确认系统授权。")
        }
        reachable = false
      }
      if reachable {
        return
      }
    }
    guard allowAuthorization else {
      throw AdminServiceIdentity.error("permission_required", "需要系统管理员授权，授权后安装、卸载和客户端更新可持续复用。")
    }
    if state["status"] == "approvalRequired" {
      throw AdminServiceIdentity.error("helper_approval", state["message"]!)
    }
    func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    let command = [bundledHelper.path, "enable-service", Bundle.main.bundleURL.path, String(getuid())].map(quote).joined(separator: " ")
    let literal = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    let result = try InstallerProcess.run("/usr/bin/osascript", ["-e", "do shell script \"\(literal)\" with administrator privileges"])
    guard result.status == 0 else {
      if result.stderr.contains("(-128)") { throw AdminServiceIdentity.error("cancelled", "你已取消管理员助手授权。") }
      throw AdminServiceIdentity.error("helper_enable", "未能启用管理员助手，请重试。\n" + String(result.stdout.suffix(1500)))
    }
    _ = try request({ $0.ping(reply: $1) }, timeout: 5)
  }
}
