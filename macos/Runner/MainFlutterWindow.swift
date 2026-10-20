import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var installerChannel: InstallerChannel?
  private var startupChannel: FlutterMethodChannel?
  private var firstFrameShown = false

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.backgroundColor = .windowBackgroundColor
    flutterViewController.backgroundColor = .windowBackgroundColor
    let windowFrame = NSRect(x: 0, y: 0, width: 1240, height: 820)
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: false)

    RegisterGeneratedPlugins(registry: flutterViewController)
    installerChannel = InstallerChannel(messenger: flutterViewController.engine.binaryMessenger)
    startupChannel = FlutterMethodChannel(
      name: "win.huarun/window", binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    startupChannel?.setMethodCallHandler { [weak self] call, result in
      guard call.method == "firstFrameReady" else {
        result(FlutterMethodNotImplemented)
        return
      }
      if let self, !self.firstFrameShown {
        self.firstFrameShown = true
        self.makeKeyAndOrderFront(nil)
      }
      result(nil)
    }
    self.minSize = NSSize(width: 460, height: 640)
    self.title = "华润赢"
    self.titleVisibility = .hidden
    self.titlebarAppearsTransparent = true
    self.styleMask.insert(.fullSizeContentView)
    self.isMovableByWindowBackground = true
    if #available(macOS 11.0, *) {
      self.titlebarSeparatorStyle = .none
    }
    let dragArea = WindowDragArea()
    dragArea.translatesAutoresizingMaskIntoConstraints = false
    flutterViewController.view.addSubview(dragArea)
    NSLayoutConstraint.activate([
      dragArea.topAnchor.constraint(equalTo: flutterViewController.view.topAnchor),
      dragArea.leadingAnchor.constraint(equalTo: flutterViewController.view.leadingAnchor),
      dragArea.trailingAnchor.constraint(equalTo: flutterViewController.view.trailingAnchor),
      dragArea.heightAnchor.constraint(equalToConstant: 32),
    ])
    self.center()

    super.awakeFromNib()
    // A hidden window does not trigger FlutterViewController.viewWillAppear.
    flutterViewController.engine.run(withEntrypoint: nil)
  }
}

private final class WindowDragArea: NSView {
  override func mouseDown(with event: NSEvent) {
    if event.clickCount == 2 {
      window?.performZoom(nil)
    } else {
      window?.performDrag(with: event)
    }
  }
}
