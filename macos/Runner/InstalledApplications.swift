import Foundation

enum InstalledApplicationReader {
  static func scan(in roots: [URL] = [
    URL(fileURLWithPath: "/Applications", isDirectory: true),
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
  ]) throws -> [[String: Any]] {
    let files = FileManager.default
    var applications: [[String: Any]] = []
    var visited = Set<String>()
    for root in roots where files.fileExists(atPath: root.path) {
      let entries = try files.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
        options: [.skipsHiddenFiles]
      )
      for app in entries where app.pathExtension.lowercased() == "app" {
        let path = app.standardizedFileURL.path
        guard visited.insert(path).inserted,
              let values = try? app.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true, values.isSymbolicLink != true,
              let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              let bundleID = info["CFBundleIdentifier"] as? String, !bundleID.isEmpty,
              let version = info["CFBundleShortVersionString"] as? String, !version.isEmpty,
              let executable = info["CFBundleExecutable"] as? String,
              !executable.isEmpty, executable != ".", executable != "..", !executable.contains("/"),
              files.isExecutableFile(atPath: app.appendingPathComponent("Contents/MacOS").appendingPathComponent(executable).path) else { continue }
        let names = [
          info["CFBundleDisplayName"] as? String,
          info["CFBundleName"] as? String,
          app.deletingPathExtension().lastPathComponent
        ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        applications.append([
          "path": path,
          "bundleIdentifier": bundleID,
          "version": version,
          "names": Array(Set(names))
        ])
      }
    }
    return applications
  }
}
