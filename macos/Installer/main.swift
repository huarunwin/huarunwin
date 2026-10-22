import Foundation
import Darwin

var arguments = Array(CommandLine.arguments.dropFirst())
if arguments.last == "--progress" { reportsProgress = true; arguments.removeLast() }
do {
    if arguments.count >= 3 && arguments[0] == "user-tool" {
        let allowed = ["/usr/bin/lipo", "/usr/sbin/sysctl", "/usr/bin/codesign", "/usr/sbin/spctl", "/usr/bin/open"]
        guard getuid() == 0, let user = UInt32(arguments[1]), user > 0,
              allowed.contains(arguments[2]), seteuid(0) == 0, let account = getpwuid(user),
              initgroups(account.pointee.pw_name, Int32(bitPattern: account.pointee.pw_gid)) == 0,
              setgid(account.pointee.pw_gid) == 0, setuid(user) == 0,
              getuid() == user, geteuid() == user else { try fail("caller", "无法以普通用户运行检查工具。") }
        setenv("HOME", account.pointee.pw_dir, 1)
        setenv("USER", account.pointee.pw_name, 1)
        setenv("LOGNAME", account.pointee.pw_name, 1)
        unsetenv("TMPDIR")
        let result = try InstallerProcess.run(arguments[2], Array(arguments.dropFirst(3)))
        FileHandle.standardOutput.write(Data(result.stdout.utf8))
        FileHandle.standardError.write(Data(result.stderr.utf8))
        exit(result.status)
    } else if arguments == ["serve"] {
        try serveAdminService()
    } else if arguments.count == 3 && arguments[0] == "enable-service", let user = UInt32(arguments[2]) {
        try enableAdminService(app: URL(fileURLWithPath: arguments[1]).standardizedFileURL, user: user)
    } else if arguments.count == 5 && arguments[0] == "service-commit", geteuid() == 0,
              let user = UInt32(arguments[2]), ["true", "false"].contains(arguments[3]),
              let data = arguments[4].data(using: .utf8), let approval = try JSONSerialization.jsonObject(with: data) as? [String: String],
              approval.isEmpty || Set(approval.keys) == Set(["path", "bundleIdentifier", "oldIdentity", "newIdentity"]) {
        let result = try commit(URL(fileURLWithPath: arguments[1]).standardizedFileURL, quarantine: arguments[3] == "true", signerApproval: approval.isEmpty ? nil : approval, user: user)
        output(["path": result.path])
    } else if arguments.count == 8 && ["self-update", "service-update"].contains(arguments[0]),
       let parentPID = Int32(arguments[3]), let user = UInt32(arguments[6]) {
        let job = URL(fileURLWithPath: arguments[5]).standardizedFileURL
        do {
            try selfUpdate(URL(fileURLWithPath: arguments[1]).standardizedFileURL,
                           destination: URL(fileURLWithPath: arguments[2]).standardizedFileURL,
                           parentPID: parentPID, version: arguments[4], job: job, user: user, channel: arguments[7])
        } catch {
            let message = (error as? InstallerFailure)?.message ?? error.localizedDescription
            try? asInstallerUser(geteuid() == 0 ? user : nil) { try message.write(to: job.appendingPathComponent("error.txt"), atomically: true, encoding: .utf8) }
            throw error
        }
    } else if arguments.count == 4 && arguments[0] == "trash",
              let user = UInt32(arguments[2]), let clientPID = Int32(arguments[3]),
              let data = arguments[1].data(using: .utf8), let approval = try JSONSerialization.jsonObject(with: data) as? [String: String] {
        let result = try trashApplication(approval, user: user, clientPID: clientPID)
        output(["path": result.path])
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
    let uninstalling = arguments.first == "trash"
    output(["code": uninstalling ? "trash" : "installation",
            "message": (uninstalling ? "未能移到废纸篓，请重试或在 Finder 中手动处理：" : "安装未完成：") + error.localizedDescription]); exit(1)
}
