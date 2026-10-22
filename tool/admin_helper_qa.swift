import AppKit
import Foundation

@main
struct AdminHelperQA {
  static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
  }

  static func rejected(_ operation: () throws -> Void) -> Bool {
    do { try operation(); return false } catch { return true }
  }

  static func exchange(client: String, server: String, user: uid_t, mutate: Bool = false) -> [String: String]? {
    let listener = NSXPCListener.anonymous()
    let delegate = AdminService(configuration: ["user": String(user), "requirement": client])
    listener.setConnectionCodeSigningRequirement(client)
    listener.delegate = delegate
    listener.resume()
    defer { listener.invalidate() }
    let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
    connection.remoteObjectInterface = NSXPCInterface(with: AdminServiceProtocol.self)
    connection.setCodeSigningRequirement(server)
    let lock = NSLock()
    var finished = false, value: [String: String]?
    func finish(_ response: [String: String]?) {
      lock.lock(); defer { lock.unlock() }
      value = response; finished = true
    }
    connection.invalidationHandler = { finish(nil) }
    connection.resume()
    defer { connection.invalidate() }
    let proxy = connection.remoteObjectProxyWithErrorHandler { _ in finish(nil) } as! AdminServiceProtocol
    if mutate {
      proxy.trash(approval: ["path": "/Applications/Fixture.app", "bundleIdentifier": "org.example.fixture",
                            "version": "1", "device": "0", "inode": "0", "trash": "/tmp"]) { finish($0) }
    } else { proxy.ping { finish($0) } }
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
      lock.lock(); let done = finished; lock.unlock()
      if done { break }
      RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    lock.lock(); let result = value; lock.unlock()
    return result
  }

  static func main() throws {
    require(geteuid() != 0, "Run this validation as an ordinary user.")
    let own = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    let expected = try AdminServiceIdentity.requirement(at: own, exact: true)
    let ownProcesses = try kernelApplicationPIDs(at: own.deletingLastPathComponent())
    require(ownProcesses.contains(getpid()), "Kernel process lookup missed the running fixture")
    let other = "identifier \"org.example.untrusted\""
    _ = try AdminServiceIdentity.code(at: own, requirement: expected)
    require(rejected { _ = try AdminServiceIdentity.code(at: own, requirement: other) }, "Unexpected signing identity accepted")
    require(exchange(client: expected, server: expected, user: getuid())?["protocol"] == AdminServiceIdentity.protocolVersion, "Authenticated XPC handshake failed")
    require(exchange(client: other, server: expected, user: getuid()) == nil, "Untrusted caller accepted")
    require(exchange(client: expected, server: other, user: getuid()) == nil, "Untrusted service accepted")
    require(exchange(client: expected, server: expected, user: getuid() + 1) == nil, "Wrong user accepted")
    require(exchange(client: expected, server: expected, user: getuid(), mutate: true)?["code"] == "helper_identity", "A command-line caller was allowed to mutate applications")
    require(rejected { try serveAdminService() }, "An unprivileged process served as root")
    require(rejected { try enableAdminService(app: own, user: getuid()) }, "A service was installed without authorization")

    let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("huarun-admin-qa-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: temporary) }
    require(rejected { try AdminServiceIdentity.checkRootPath(temporary, directory: true) }, "User-writable trust anchor accepted")
    let stage = temporary.appendingPathComponent("huarun-install-fixture")
    try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let app = stage.appendingPathComponent("Fixture.app")
    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: false)
    try checkServiceStage(app, user: getuid())
    require(rejected { try checkServiceStage(app, user: getuid() + 1) }, "Wrong stage owner accepted")
    _ = chmod(stage.path, 0o777)
    require(rejected { try checkServiceStage(app, user: getuid()) }, "Writable stage accepted")
    _ = chmod(stage.path, 0o700)
    try FileManager.default.removeItem(at: app)
    try FileManager.default.createSymbolicLink(at: app, withDestinationURL: temporary)
    require(rejected { try checkServiceStage(app, user: getuid()) }, "Symlinked stage accepted")
    if CommandLine.arguments.count == 2 {
      let app = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
      guard let running = NSWorkspace.shared.runningApplications.first(where: { $0.bundleURL?.path == app.path }) else {
        fatalError("The client fixture is not running")
      }
      let clientRequirement = try AdminServiceIdentity.requirement(at: app)
      let resolved = try AdminServiceIdentity.clientApplication(pid: running.processIdentifier, requirement: clientRequirement)
      require(resolved.path == app.path, "Signed client process resolved to the wrong application")
      let clientProcesses = try kernelApplicationPIDs(at: app)
      require(clientProcesses.contains(running.processIdentifier), "Kernel process lookup missed the client")
      print("PASS running signed client identity and kernel process lookup")
    }
    print("Administrator helper checks passed; no system service installed or application changed.")
  }
}
