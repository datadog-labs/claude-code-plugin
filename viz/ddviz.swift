#!/usr/bin/env swift
import AppKit
import Dispatch
import Foundation
import WebKit

// Native macOS GUI for MCP hook visualization.

func env(_ key: String) -> String? { ProcessInfo.processInfo.environment[key] }

// ── Constants ─────────────────────────────────────────────────────

let APP_NAME = "ddviz"
let APP_VERSION = "0.0.1-preview.20260515"
let WINDOW_WIDTH = 610.0
let WINDOW_HEIGHT = 400.0
let DEBUG = env("DDVIZ_DEBUG") == "1"

let DDVIZ_DATA_DIR = env("DDVIZ_DATA_DIR") ?? NSTemporaryDirectory()
let DDVIZ_ROOT_DIR =
  URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().path

let SOCKET_FILENAME = "ddviz.sock"
let SOCKET_PATH = URL(fileURLWithPath: DDVIZ_DATA_DIR).appendingPathComponent(SOCKET_FILENAME)

let JS_HANDLER_NAME = "nativeBridge"
let IPC_MAX_MESSAGE_BYTES = 256 * 1024 * 1024

let DEFAULT_FRAME_SRC = "https://static.datadoghq.com/mcp-apps/dataviz-mcp-ui/index.html"
let TRUSTED_DOMAIN_SUFFIXES = [".datadoghq.com", ".ddog-gov.com", ".datadoghq.eu"]

let CSP_NONCE: String = {
  var bytes = [UInt8](repeating: 0, count: 16)
  let result = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
  guard result == errSecSuccess else {
    log("Fatal: SecRandomCopyBytes failed")
    exit(1)
  }
  return Data(bytes).base64EncodedString()
}()
let FRAME_SRC: String = {
  guard let override = env("DDVIZ_FRAME_SRC") else {
    return DEFAULT_FRAME_SRC
  }
  guard DEBUG else {
    log("Fatal: DDVIZ_FRAME_SRC requires DDVIZ_DEBUG=1")
    exit(1)
  }
  guard let url = URL(string: override), isTrustedURL(url) else {
    log("Fatal: DDVIZ_FRAME_SRC '\(override)' is not a trusted origin")
    exit(1)
  }
  return override
}()
/// CSP frame-src is pinned to FRAME_SRC's exact origin so a subdomain
/// compromise in *.datadoghq.com cannot be loaded into the iframe.
let CSP_FRAME_SRC: String = {
  guard let url = URL(string: FRAME_SRC),
    let scheme = url.scheme,
    let host = url.host
  else {
    log("Fatal: cannot derive CSP frame-src origin from FRAME_SRC")
    exit(1)
  }
  return "\(scheme)://\(host)"
}()

let PARENT_BUNDLE_ID: String? = {
  // __CFBundleIdentifier is injected by macOS into every process launched from a .app.
  if let bundleId = env("__CFBundleIdentifier"), !bundleId.isEmpty { return bundleId }
  log("[GUI] __CFBundleIdentifier not set: parent tracking disabled")
  return nil
}()

/// Returns the screen-coordinate frames of all on-screen windows belonging to
/// the parent application. Uses CGWindowListCopyWindowInfo which requires no
/// special permissions — window bounds are available to any process.
func parentWindowFrames() -> [NSRect] {
  guard let bid = PARENT_BUNDLE_ID else { return [] }
  let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bid)
  let pids = Set(apps.map { $0.processIdentifier })
  guard !pids.isEmpty else { return [] }

  guard
    let windowList = CGWindowListCopyWindowInfo(
      [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
  else {
    return []
  }

  var frames: [NSRect] = []
  for info in windowList {
    guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pids.contains(pid),
      let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat],
      let x = boundsDict["X"], let y = boundsDict["Y"],
      let w = boundsDict["Width"], let h = boundsDict["Height"],
      w > 0, h > 0
    else { continue }
    // CGWindowList uses top-left origin; convert to NSScreen bottom-left origin.
    let screenHeight = NSScreen.main?.frame.height ?? 0
    frames.append(NSRect(x: x, y: screenHeight - y - h, width: w, height: h))
  }
  return frames
}

// ── Assets ────────────────────────────────────────────────────────

func resolveAssetPath(_ name: String) -> String {
  URL(fileURLWithPath: DDVIZ_ROOT_DIR).appendingPathComponent("assets").appendingPathComponent(
    name
  ).path
}

let mcpHostHTML: String = {
  guard let raw = try? String(contentsOfFile: resolveAssetPath("mcp-host.html"), encoding: .utf8)
  else {
    log("Fatal: could not load assets/mcp-host.html from \(DDVIZ_ROOT_DIR)")
    exit(1)
  }

  /// Substitute `{{key}}` placeholders, aborting if any value contains chars that could
  /// break HTML attributes or JS literals (notably: `'`, `"`, `<`, `>`, backtick, `\`).
  func substitute(_ template: String, values: [(String, String)]) -> String {
    var safe = CharacterSet.alphanumerics
    safe.insert(charactersIn: "-._~:/?#@=&+!,;%()*[] ")
    var result = template
    for (key, value) in values {
      guard value.unicodeScalars.allSatisfy({ safe.contains($0) }) else {
        log("Fatal: template variable {{\(key)}} contains characters unsafe for templating")
        exit(1)
      }
      result = result.replacingOccurrences(of: "{{\(key)}}", with: value)
    }
    return result
  }

  log("Frame source: \(FRAME_SRC)")
  return substitute(
    raw,
    values: [
      ("FRAME_SRC", FRAME_SRC),
      ("DEBUG", DEBUG ? "true" : "false"),
      ("CSP_FRAME_SRC", CSP_FRAME_SRC),
      ("CSP_NONCE", CSP_NONCE),
      ("HOST_NAME", APP_NAME),
      ("HOST_VERSION", APP_VERSION),
    ])
}()

let datadogIconData: Data? = FileManager.default.contents(
  atPath: resolveAssetPath("datadog-icon.png"))

// ── Navigation ────────────────────────────────────────────────────

func isTrustedURL(_ url: URL) -> Bool {
  guard url.scheme?.lowercased() == "https" else { return false }
  guard let host = url.host?.lowercased(), !host.isEmpty else { return false }
  for suffix in TRUSTED_DOMAIN_SUFFIXES {
    let domain = String(suffix.dropFirst())  // remove leading "."
    if host == domain || host.hasSuffix(suffix) { return true }
  }
  return false
}

// ── JavaScript Bridge ─────────────────────────────────────────────

/// Validated JS script: constructed via prepareJsCallWithJSON.
struct SafeJs {
  let script: String
  fileprivate init(_ script: String) { self.script = script }
}

/// Build a safe JS call via double-serialization.
func prepareJsCallWithJSON(_ fnName: String, payload: Any) -> SafeJs {
  precondition(
    !fnName.isEmpty
      && fnName.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") },
    "Invalid JS identifier: \(fnName)"
  )

  let jsonData = try! JSONSerialization.data(withJSONObject: payload)
  let jsonStr = String(data: jsonData, encoding: .utf8)!

  // Double-serialize: JSONSerialization requires arrays/dicts at top level,
  // so wrap the string in an array, serialize, then strip the brackets.
  let wrappedData = try! JSONSerialization.data(withJSONObject: [jsonStr])
  let wrappedStr = String(data: wrappedData, encoding: .utf8)!
  let safeJSON = String(wrappedStr.dropFirst().dropLast())  // strip [ and ]

  return SafeJs("if (typeof \(fnName) === 'function') { \(fnName)(JSON.parse(\(safeJSON))); }")
}

func evalJs(_ webView: WKWebView, _ safeJs: SafeJs) {
  webView.evaluateJavaScript(safeJs.script, completionHandler: nil)
}

enum JsMessage {
  case sizeChanged(width: Double, height: Double)
  case requestDisplayMode(mode: String)
  case openLink(url: String)
  case close
  case reveal
  case initialized
  case shutdown(reason: String)
  case unknown(type: String, payload: [String: Any]?)

  var typeName: String {
    switch self {
    case .sizeChanged: return "size-changed"
    case .requestDisplayMode: return "request-display-mode"
    case .openLink: return "open-link"
    case .close: return "close"
    case .reveal: return "reveal"
    case .initialized: return "initialized"
    case .shutdown: return "shutdown"
    case .unknown(let type, _): return type
    }
  }

  static func parse(_ jsonString: String) -> JsMessage? {
    guard let data = jsonString.data(using: .utf8),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let msgType = json["type"] as? String
    else {
      return nil
    }
    let payload = json["payload"] as? [String: Any]
    switch msgType {
    case "size-changed":
      guard let w = payload?["width"] as? Double,
        let h = payload?["height"] as? Double
      else {
        return .unknown(type: msgType, payload: payload)
      }
      return .sizeChanged(width: w, height: h)
    case "request-display-mode":
      guard let mode = payload?["mode"] as? String else {
        return .unknown(type: msgType, payload: payload)
      }
      return .requestDisplayMode(mode: mode)
    case "open-link":
      guard let url = payload?["url"] as? String else {
        return .unknown(type: msgType, payload: payload)
      }
      return .openLink(url: url)
    case "close":
      return .close
    case "reveal":
      return .reveal
    case "initialized":
      return .initialized
    case "shutdown":
      let reason = payload?["reason"] as? String ?? "Unknown reason"
      return .shutdown(reason: reason)
    default:
      return .unknown(type: msgType, payload: payload)
    }
  }
}

// ── Socket & IPC ──────────────────────────────────────────────────

/// Execute a closure with a sockaddr_un for the given path. Returns -1 if the path is too long.
@discardableResult
func withSockAddr(path: String, body: (UnsafePointer<sockaddr>, socklen_t) -> Int32) -> Int32 {
  var addr = sockaddr_un()
  let maxPathLen = MemoryLayout.size(ofValue: addr.sun_path) - 1

  guard path.utf8.count <= maxPathLen else {
    log("[Socket] Path too long for Unix domain socket: \(path.utf8.count) > \(maxPathLen)")
    return -1
  }

  addr.sun_family = sa_family_t(AF_UNIX)
  path.withCString { cstr in
    withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
      let len = strlen(cstr)
      let rawPtr = UnsafeMutableRawPointer(ptr)
      _ = memcpy(rawPtr, cstr, len)
      rawPtr.storeBytes(of: 0 as CChar, toByteOffset: Int(len), as: CChar.self)
    }
  }
  return withUnsafePointer(to: &addr) { ptr in
    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
      body(sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
  }
}

func acquireInstanceLock(path: String) -> Int32 {
  let fd = Darwin.open(path, O_CREAT | O_RDWR, 0o600)
  guard fd >= 0 else { return -1 }
  if flock(fd, LOCK_EX | LOCK_NB) != 0 {
    Darwin.close(fd)
    return -1
  }
  return fd
}

class IpcServer {
  private let path: URL
  private var socketFD: Int32 = -1
  private var running = false
  private let queue = DispatchQueue(label: "IpcServer")
  private var acceptSource: DispatchSourceRead?

  enum InitResult {
    case success(IpcServer)
    case alreadyRunning
    case failed
  }

  static func create(path: URL) -> InitResult {
    let pathStr = path.path
    unlink(pathStr)

    // Force the socket to land at 0o700 from bind() so chmod() doesn't have to
    // close a wider window. umask is process-wide; safe here because create()
    // runs at startup before AppKit and dispatch queues are spawned.
    let oldUmask = umask(0o077)
    defer { umask(oldUmask) }

    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return .failed }

    let bindResult = withSockAddr(path: pathStr) { ptr, len in
      bind(fd, ptr, len)
    }

    guard bindResult == 0 else {
      Darwin.close(fd)
      return .failed
    }

    chmod(pathStr, 0o600)

    guard Darwin.listen(fd, 5) == 0 else {
      Darwin.close(fd)
      return .failed
    }

    let server = IpcServer(path: path, fd: fd)
    return .success(server)
  }

  private init(path: URL, fd: Int32) {
    self.path = path
    self.socketFD = fd
  }

  func start(callback: @escaping (Data) -> Void) {
    running = true

    let source = DispatchSource.makeReadSource(fileDescriptor: socketFD, queue: queue)
    acceptSource = source

    source.setEventHandler { [weak self] in
      guard let self = self, self.running else { return }
      let clientFD = accept(self.socketFD, nil, nil)
      guard clientFD >= 0 else { return }
      self.handleClient(fd: clientFD, callback: callback)
    }

    source.setCancelHandler { [weak self] in
      guard let self = self else { return }
      if self.socketFD >= 0 {
        Darwin.close(self.socketFD)
        self.socketFD = -1
      }
    }

    source.resume()
    log("[GUI] Listening on \(path.path)")
  }

  private func handleClient(fd: Int32, callback: @escaping (Data) -> Void) {
    var buffer = Data()
    let newline = UInt8(ascii: "\n")

    let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)

    source.setEventHandler {
      var chunk = [UInt8](repeating: 0, count: 65536)
      let bytesRead = Darwin.read(fd, &chunk, chunk.count)

      if bytesRead > 0 {
        buffer.append(contentsOf: chunk[0..<bytesRead])

        if buffer.count > IPC_MAX_MESSAGE_BYTES {
          log("[GUI] IPC message exceeded limit, dropping")
          source.cancel()
          return
        }

        // All clients are one-shot (forward.sh → nc -U). Process
        // complete \n-delimited lines as they arrive so we don't
        // wait for EOF if the payload has a trailing newline.
        while let i = buffer.firstIndex(of: newline) {
          let line = buffer[buffer.startIndex..<i]
          buffer = Data(buffer[buffer.index(after: i)...])
          if !line.isEmpty { callback(Data(line)) }
        }
      } else {
        // EOF — flush any remainder (nc may omit trailing \n).
        if !buffer.isEmpty { callback(Data(buffer)) }
        source.cancel()
      }
    }

    source.setCancelHandler {
      Darwin.close(fd)
    }

    source.resume()
  }

  func stop() {
    running = false
    acceptSource?.cancel()
    acceptSource = nil
    try? FileManager.default.removeItem(at: path)
  }

  deinit { stop() }
}

// ── VizPanel ──────────────────────────────────────────────────────

enum PanelAppearance: String {
  case hidden  // not on screen
  case idle  // visible, dimmed, traffic lights hidden
  case active  // visible, full opacity, traffic lights visible
}

/// How `parentActive` is consulted in the appearance decision.
enum UserIntent {
  case auto  // follow parentActive for automatic show/hide
  case dismissed  // user explicitly closed — stay hidden until new content
  case shown  // user explicitly opened — visible regardless of parentActive
}

/// Invisible overlay at the top of the panel that enables window dragging.
private class DragHandleView: NSView {
  required init?(coder: NSCoder) { fatalError() }
  override init(frame frameRect: NSRect) { super.init(frame: frameRect) }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
}

/// Notification-style close button: a circular × that fades in on hover.
private class CloseButton: NSView {
  var onClose: (() -> Void)?

  required init?(coder: NSCoder) { fatalError() }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.cornerRadius = frame.height / 2
    layer?.cornerCurve = .continuous
    layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.1).cgColor
    alphaValue = 0
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    guard let ctx = NSGraphicsContext.current?.cgContext else { return }
    let size = bounds.size
    let inset: CGFloat = 6
    ctx.setStrokeColor(NSColor.labelColor.withAlphaComponent(0.7).cgColor)
    ctx.setLineWidth(1.0)
    ctx.setLineCap(.round)
    ctx.move(to: CGPoint(x: inset, y: inset))
    ctx.addLine(to: CGPoint(x: size.width - inset, y: size.height - inset))
    ctx.move(to: CGPoint(x: size.width - inset, y: inset))
    ctx.addLine(to: CGPoint(x: inset, y: size.height - inset))
    ctx.strokePath()
  }

  override func mouseDown(with event: NSEvent) {
    layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.25).cgColor
  }

  override func mouseUp(with event: NSEvent) {
    layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.1).cgColor
    let loc = convert(event.locationInWindow, from: nil)
    if bounds.contains(loc) { onClose?() }
  }

  func setVisible(_ visible: Bool, animated: Bool = true) {
    let target: CGFloat = visible ? 1 : 0
    guard alphaValue != target else { return }
    if animated {
      NSAnimationContext.beginGrouping()
      NSAnimationContext.current.duration = 0.15
      animator().alphaValue = target
      NSAnimationContext.endGrouping()
    } else {
      alphaValue = target
    }
  }
}

class VizPanel: NSPanel, WKNavigationDelegate, WKScriptMessageHandler {
  enum DisplayMode: String {
    case fullscreen
    case inline
  }

  private enum Constants {
    static let alphaIdle: CGFloat = 0.3
    static let alphaActive: CGFloat = 1.0
    static let fadeInSecs: TimeInterval = 0.2
    static let fadeOutSecs: TimeInterval = 0.3
    static let windowMargin: CGFloat = 25
    static let dragHandleHeight: CGFloat = 30
  }

  private(set) var webView: WKWebView!
  private var closeButton: CloseButton!
  private var isFrameReady = false
  private var pendingPayloads: [Any] = []
  var inlineFrame: NSRect = .zero
  private var themeObservation: NSKeyValueObservation?

  // ── Appearance state ──────────────────────────────────────────
  // All visibility / opacity decisions flow through updateAppearance().
  private(set) var hasContent = false
  private(set) var userIntent: UserIntent = .auto
  private(set) var parentActive = true
  private(set) var currentAppearance: PanelAppearance = .hidden

  var onInitialized: (() -> Void)?
  var onShutdown: ((String) -> Void)?

  init() {
    let frame = NSRect(x: 0, y: 0, width: WINDOW_WIDTH, height: WINDOW_HEIGHT)
    let styleMask: NSWindow.StyleMask = [
      .resizable, .nonactivatingPanel,
    ]

    super.init(contentRect: frame, styleMask: styleMask, backing: .buffered, defer: false)

    hasShadow = false
    isOpaque = false
    backgroundColor = .clear
    level = .floating
    hidesOnDeactivate = false
    inlineFrame = frame

    positionTopRight(margin: Constants.windowMargin)

    let wkConfig = WKWebViewConfiguration()
    wkConfig.websiteDataStore = .nonPersistent()
    wkConfig.userContentController.add(self, name: JS_HANDLER_NAME)
    wkConfig.applicationNameForUserAgent = "\(APP_NAME)/\(APP_VERSION)"

    webView = WKWebView(frame: frame, configuration: wkConfig)
    webView.autoresizingMask = [.width, .height]
    webView.setValue(false, forKey: "drawsBackground")
    webView.navigationDelegate = self

    if #available(macOS 13.3, *) {
      webView.isInspectable = DEBUG
    }

    webView.loadHTMLString(mcpHostHTML, baseURL: nil)

    // Use the default contentView as a container for rounding, border,
    // web view, drag handle, and close button.
    guard let container = contentView else { fatalError("expected contentView") }
    container.wantsLayer = true
    container.layer?.cornerRadius = 10
    container.layer?.cornerCurve = .continuous
    container.layer?.masksToBounds = true
    container.layer?.borderWidth = 0.5
    container.layer?.borderColor = NSColor.separatorColor.cgColor

    webView.frame = container.bounds
    container.addSubview(webView)

    let dh = Constants.dragHandleHeight
    let dragHandle = DragHandleView(
      frame: NSRect(
        x: 0,
        y: container.bounds.height - dh,
        width: container.bounds.width,
        height: dh
      ))
    dragHandle.autoresizingMask = [.width, .minYMargin]
    container.addSubview(dragHandle)

    let btnSize: CGFloat = 17
    let btnMargin: CGFloat = 7
    closeButton = CloseButton(
      frame: NSRect(
        x: btnMargin,
        y: container.bounds.height - btnSize - btnMargin,
        width: btnSize,
        height: btnSize
      ))
    closeButton.autoresizingMask = [.maxXMargin, .minYMargin]
    closeButton.onClose = { [weak self] in self?.userClose() }
    container.addSubview(closeButton)

    setupTracking()
    alphaValue = 0

    NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
      DispatchQueue.main.async { self?.updateAppearance() }
    }

    themeObservation = NSApp.observe(\.effectiveAppearance, options: [.new, .initial]) {
      [weak self] _, _ in
      DispatchQueue.main.async { self?.notifyThemeChanged() }
    }
  }

  private var currentTheme: String {
    let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    return isDark ? "dark" : "light"
  }

  private func notifyThemeChanged() {
    let t = currentTheme
    log("[GUI] Theme changed: \(t)")
    let payload: [String: Any] = ["theme": t]
    evalJs(webView, prepareJsCallWithJSON("handleThemeChanged", payload: payload))
  }

  private func positionTopRight(margin: CGFloat) {
    guard let screen = NSScreen.main else {
      center()
      return
    }
    let sf = screen.visibleFrame
    let x = sf.origin.x + sf.size.width - frame.width - margin
    let y = sf.origin.y + sf.size.height - frame.height - margin
    setFrameOrigin(NSPoint(x: x, y: y))
  }

  override func mouseEntered(with event: NSEvent) {
    updateAppearance()
  }

  override var canBecomeKey: Bool { true }

  @objc func closeWindow(_ sender: Any?) {
    userClose()
  }

  override func cancelOperation(_ sender: Any?) {
    userClose()
  }

  override func mouseExited(with event: NSEvent) {
    updateAppearance()
  }

  override func becomeKey() {
    super.becomeKey()
    updateAppearance()
    notifyFocusChanged(true)
  }

  override func resignKey() {
    super.resignKey()
    updateAppearance()
    notifyFocusChanged(false)
  }

  private func notifyFocusChanged(_ focused: Bool) {
    let payload: [String: Any] = ["focused": focused]
    evalJs(webView, prepareJsCallWithJSON("handleWindowFocusChanged", payload: payload))
  }

  private func setCloseButtonVisible(_ visible: Bool) {
    closeButton.setVisible(visible)
  }

  private func animateAlpha(to alpha: CGFloat, duration: TimeInterval) {
    NSAnimationContext.beginGrouping()
    NSAnimationContext.current.duration = duration
    animator().alphaValue = alpha
    NSAnimationContext.endGrouping()
  }

  /// Central appearance dispatch. Always reapplies the target alpha so that
  /// transient overrides (forceFullOpacity) get corrected on the next event.
  /// Fraction of the panel's area covered by parent app windows (0.0–1.0+).
  private func parentOverlapRatio() -> CGFloat {
    let panelArea = frame.width * frame.height
    guard panelArea > 0 else { return 0 }
    return parentWindowFrames().reduce(0) { sum, parentFrame in
      let ix = frame.intersection(parentFrame)
      return ix.isNull ? sum : sum + ix.width * ix.height
    } / panelArea
  }

  func updateAppearance(forceFullOpacity: Bool = false) {
    let mouseInside = frame.contains(NSEvent.mouseLocation)
    let overlapRatio = parentOverlapRatio()
    let visible: Bool = {
      guard hasContent else { return false }
      switch userIntent {
      case .dismissed: return false
      case .shown: return true
      case .auto: return parentActive
      }
    }()
    let desired: PanelAppearance =
      !visible ? .hidden : (isKeyWindow || mouseInside) ? .active : .idle
    let changed = desired != currentAppearance
    let previous = currentAppearance
    if changed {
      currentAppearance = desired
      log(
        "[GUI] updateAppearance: \(previous.rawValue) → \(desired.rawValue) [hasContent=\(hasContent) intent=\(userIntent) parentActive=\(parentActive) key=\(isKeyWindow) mouseIn=\(mouseInside) overlap=\(String(format: "%.0f%%", overlapRatio * 100))]"
      )
    }

    let becomingVisible = changed && previous == .hidden && desired != .hidden
    if becomingVisible {
      alphaValue = 0
      if userIntent == .shown {
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
      } else {
        orderFront(nil)
      }
    }

    switch desired {
    case .hidden:
      if changed { orderOut(nil) }

    case .idle:
      setCloseButtonVisible(false)
      let idleAlpha =
        (forceFullOpacity || overlapRatio < 0.5)
        ? Constants.alphaActive : Constants.alphaIdle
      let duration = becomingVisible ? Constants.fadeInSecs : Constants.fadeOutSecs
      animateAlpha(to: idleAlpha, duration: duration)

    case .active:
      setCloseButtonVisible(true)
      animateAlpha(to: Constants.alphaActive, duration: Constants.fadeInSecs)
    }
  }

  /// Flash the border to signal new content.
  private func flashBorder() {
    guard let layer = contentView?.layer else { return }
    let anim = CABasicAnimation(keyPath: "borderColor")
    anim.fromValue = NSColor.labelColor.withAlphaComponent(0.5).cgColor
    anim.toValue = NSColor.separatorColor.cgColor
    anim.duration = 0.6
    layer.add(anim, forKey: "borderGlow")
  }

  /// New content arrived — reset intent to auto so parent-tracking resumes.
  func reveal() {
    hasContent = true
    flashBorder()
    userIntent = .auto
    updateAppearance(forceFullOpacity: true)
  }

  func userClose() {
    userIntent = .dismissed
    updateAppearance()
  }

  func userToggle() {
    userIntent = currentAppearance != .hidden ? .dismissed : .shown
    updateAppearance(forceFullOpacity: true)
  }

  func setParentActive(_ active: Bool) {
    parentActive = active
    // Reset explicit .shown intent only when returning to the parent app,
    // so the panel resumes normal parent-tracking behavior.
    if active && userIntent == .shown {
      userIntent = .auto
    }
    updateAppearance()
  }

  func sendPayload(_ payload: Any) {
    pendingPayloads.append(payload)
    flushPendingPayloads()
  }

  private func flushPendingPayloads() {
    guard isFrameReady, !pendingPayloads.isEmpty else { return }
    log("[GUI] Sending \(pendingPayloads.count) payload(s)")
    for payload in pendingPayloads {
      evalJs(webView, prepareJsCallWithJSON("handleHookPayload", payload: payload))
    }
    pendingPayloads.removeAll()
  }

  private func setupTracking() {
    guard let contentView = contentView else { return }
    let trackingArea = NSTrackingArea(
      rect: contentView.bounds,
      options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
      owner: self,
      userInfo: nil
    )
    contentView.addTrackingArea(trackingArea)
    setCloseButtonVisible(false)
  }

  func setDisplayMode(_ mode: DisplayMode) {
    switch mode {
    case .fullscreen:
      if let screen = NSScreen.main {
        let current = frame
        let screenFrame = screen.visibleFrame
        // Only store frame if not already in fullscreen.
        if current.size.width < screenFrame.size.width * 0.9 {
          inlineFrame = current
        }
        setFrame(screenFrame, display: true, animate: true)
        log("[GUI] Entered fullscreen mode")
      }
    case .inline:
      setFrame(inlineFrame, display: true, animate: true)
      log("[GUI] Restored inline mode")
    }
  }

  @discardableResult
  func openTrustedLink(_ url: URL) -> Bool {
    guard isTrustedURL(url) else {
      log("[GUI] Blocked untrusted URL: \(url.absoluteString)")
      return false
    }
    NSWorkspace.shared.open(url)
    userClose()
    return true
  }

  func webView(
    _ webView: WKWebView,
    decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
  ) {
    guard let url = navigationAction.request.url else {
      decisionHandler(.cancel)
      return
    }

    if url.absoluteString == "about:blank" {
      decisionHandler(.allow)
    } else if !isTrustedURL(url) {
      decisionHandler(.cancel)
    } else if navigationAction.targetFrame?.isMainFrame ?? true {
      openTrustedLink(url)
      decisionHandler(.cancel)
    } else {
      decisionHandler(.allow)
    }
  }

  func userContentController(
    _ userContentController: WKUserContentController,
    didReceive message: WKScriptMessage
  ) {
    guard message.frameInfo.isMainFrame else {
      log("[GUI] Blocked message from non-main frame")
      return
    }
    guard let bodyStr = message.body as? String else { return }
    guard let msg = JsMessage.parse(bodyStr) else {
      log("[GUI] Invalid JS message: \(message.body)")
      return
    }

    log("[GUI] Received JS message: \(msg.typeName)")

    switch msg {
    case .sizeChanged(let width, let height):
      log("[GUI] JS requested size: \(width)x\(height)")
    case .requestDisplayMode(let mode):
      guard let displayMode = DisplayMode(rawValue: mode) else {
        log("[GUI] Unknown display mode: \(mode)")
        return
      }
      setDisplayMode(displayMode)
      let payload: [String: Any] = ["mode": mode]
      evalJs(webView, prepareJsCallWithJSON("handleDisplayModeChanged", payload: payload))
    case .openLink(let urlString):
      log("[GUI] Opening link: \(urlString)")
      if let url = URL(string: urlString) {
        openTrustedLink(url)
      } else {
        log("[GUI] Blocked untrusted URL: \(urlString)")
      }
    case .close:
      userClose()
    case .initialized:
      log("[GUI] Iframe app initialized")
      isFrameReady = true
      notifyThemeChanged()
      flushPendingPayloads()
      onInitialized?()
    case .reveal:
      log("[GUI] JS requested reveal")
      reveal()
    case .shutdown(let reason):
      log("[GUI] Shutdown requested: \(reason)")
      onShutdown?(reason)
    case .unknown(let type, _):
      log("[GUI] Unknown JS message type: \(type)")
    }
  }
}

// ── Parent App Tracker ────────────────────────────────────────────

class ParentAppTracker {
  let bundleId: String?
  private(set) var isParentActive: Bool
  var onActivated: (() -> Void)?
  var onDeactivated: (() -> Void)?

  init(bundleId: String?) {
    self.bundleId = bundleId
    guard let bid = bundleId else {
      self.isParentActive = true
      log("[GUI] ParentAppTracker: no parent bundle ID — reveal always allowed")
      return
    }

    self.isParentActive = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bid
    log(
      "[GUI] ParentAppTracker: tracking \(bid) (currently \(isParentActive ? "active" : "inactive"))"
    )

    let nc = NSWorkspace.shared.notificationCenter
    nc.addObserver(
      self, selector: #selector(appDidActivate(_:)),
      name: NSWorkspace.didActivateApplicationNotification, object: nil)
    nc.addObserver(
      self, selector: #selector(appDidDeactivate(_:)),
      name: NSWorkspace.didDeactivateApplicationNotification, object: nil)
  }

  @objc private func appDidActivate(_ notification: Notification) {
    guard
      let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
        as? NSRunningApplication,
      app.bundleIdentifier == bundleId
    else { return }
    guard !isParentActive else { return }
    isParentActive = true
    log("[GUI] Parent app activated")
    onActivated?()
  }

  @objc private func appDidDeactivate(_ notification: Notification) {
    guard
      let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
        as? NSRunningApplication,
      app.bundleIdentifier == bundleId
    else { return }
    guard isParentActive else { return }
    isParentActive = false
    log("[GUI] Parent app deactivated")
    onDeactivated?()
  }

  deinit {
    NSWorkspace.shared.notificationCenter.removeObserver(self)
  }
}

// ── App Delegate ──────────────────────────────────────────────────

class AppDelegate: NSObject, NSApplicationDelegate {
  var panel: VizPanel?
  var statusItem: NSStatusItem?
  let ipcServer: IpcServer
  var contextMenu: NSMenu?
  var parentTracker: ParentAppTracker?

  init(ipcServer: IpcServer) {
    self.ipcServer = ipcServer
    super.init()
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    setupMainMenu()

    let vizPanel = VizPanel()
    panel = vizPanel

    let tracker = ParentAppTracker(bundleId: PARENT_BUNDLE_ID)
    parentTracker = tracker

    tracker.onActivated = { [weak vizPanel] in
      DispatchQueue.main.async { vizPanel?.setParentActive(true) }
    }
    tracker.onDeactivated = { [weak vizPanel] in
      DispatchQueue.main.async { vizPanel?.setParentActive(false) }
    }

    vizPanel.onInitialized = { [weak self] in
      guard self?.statusItem == nil else { return }
      self?.setupStatusBar()
    }

    vizPanel.onShutdown = { reason in
      log("[GUI] Shutdown: \(reason)")
      DispatchQueue.main.async { NSApp.terminate(nil) }
    }

    ipcServer.start { [weak self] data in
      self?.handleIpcMessage(data)
    }
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    false
  }

  func applicationWillTerminate(_ notification: Notification) {
    ipcServer.stop()
  }

  private func handleIpcMessage(_ data: Data) {
    log("[GUI] Received IPC data: \(String(data: data, encoding: .utf8) ?? "<binary>")")

    guard let json = try? JSONSerialization.jsonObject(with: data) else {
      log("[GUI] Invalid JSON from IPC")
      return
    }

    if let dict = json as? [String: Any], dict["command"] as? String == "shutdown" {
      log("[GUI] Received shutdown command")
      DispatchQueue.main.async { NSApp.terminate(nil) }
      return
    }

    DispatchQueue.main.async { [weak self] in
      guard let self = self, let panel = self.panel else { return }
      log("[GUI] Forwarding payload to JS")

      panel.sendPayload(json)
    }
  }

  func setupMainMenu() {
    let mainMenu = NSMenu()

    let appMenuItem = NSMenuItem()
    let appMenu = NSMenu()
    let quitItem = NSMenuItem(
      title: "Quit \(APP_NAME)", action: #selector(NSApplication.terminate(_:)),
      keyEquivalent: "q")
    appMenu.addItem(quitItem)
    appMenuItem.submenu = appMenu
    mainMenu.addItem(appMenuItem)

    let windowMenuItem = NSMenuItem()
    let windowMenu = NSMenu(title: "Window")
    let closeItem = NSMenuItem(
      title: "Close", action: #selector(VizPanel.closeWindow(_:)), keyEquivalent: "w")
    windowMenu.addItem(closeItem)
    windowMenuItem.submenu = windowMenu
    mainMenu.addItem(windowMenuItem)

    NSApp.mainMenu = mainMenu
  }

  func setupStatusBar() {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    if let button = statusItem?.button {
      if let iconData = datadogIconData, let image = NSImage(data: iconData) {
        image.size = NSSize(width: 18, height: 18)
        button.image = image
      } else {
        button.title = "D"
      }
      button.action = #selector(handleStatusItemClick)
      button.target = self
      button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    let menu = NSMenu()
    let quitItem = NSMenuItem(
      title: "Quit \(APP_NAME)", action: #selector(NSApplication.terminate(_:)),
      keyEquivalent: "")
    menu.addItem(quitItem)
    contextMenu = menu
  }

  @objc func handleStatusItemClick() {
    guard let event = NSApp.currentEvent else { return }
    if event.type == .rightMouseUp {
      showContextMenu()
    } else {
      toggleWindow()
    }
  }

  func showContextMenu() {
    guard let statusItem = statusItem, let menu = contextMenu else { return }
    statusItem.menu = menu
    statusItem.button?.performClick(nil)
    statusItem.menu = nil
  }

  @objc func toggleWindow() {
    guard let panel = panel else { return }
    panel.userToggle()
  }
}

// ── Logging ───────────────────────────────────────────────────────

let logFile: FileHandle? = {
  guard DEBUG else { return nil }
  let path = URL(fileURLWithPath: DDVIZ_DATA_DIR).appendingPathComponent("ddviz.log").path
  FileManager.default.createFile(atPath: path, contents: nil)
  return FileHandle(forWritingAtPath: path)
}()

func log(_ message: String) {
  struct Static {
    static let queue = DispatchQueue(label: "ddviz.log")
  }
  guard DEBUG else { return }
  let data = Data((message + "\n").utf8)
  Static.queue.async {
    FileHandle.standardError.write(data)
    logFile?.seekToEndOfFile()
    logFile?.write(data)
  }
}

// ── Main ──────────────────────────────────────────────────────────

let lockPath = SOCKET_PATH.path + ".lock"
let lockFD = acquireInstanceLock(path: lockPath)
guard lockFD >= 0 else {
  log("Another instance is already running, exiting")
  exit(0)
}

let ipcServer: IpcServer
switch IpcServer.create(path: SOCKET_PATH) {
case .success(let server):
  ipcServer = server
case .alreadyRunning:
  log("Unexpected: socket in use despite holding lock, exiting")
  exit(0)
case .failed:
  log("Fatal: Failed to create IPC server")
  exit(1)
}

log("[GUI] === ddviz \(APP_VERSION) starting ===")
let app = NSApplication.shared
let delegate = AppDelegate(ipcServer: ipcServer)
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
