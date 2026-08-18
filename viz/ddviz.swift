#!/usr/bin/env swift
// Unless explicitly stated otherwise all files in this repository are licensed under the Apache-2.0 License.
// This product includes software developed at Datadog (https://www.datadoghq.com/) Copyright 2026 Datadog, Inc.
//
// License: Apache-2.0
//
// ddviz: Single-file macOS visualization panel for visualizations MCP tool results.
//
// Embeds a WKWebView that loads the dataviz-mcp-ui iframe and bridges JSON-RPC
// messages between the iframe and a parent process. Two IPC modes:
//
//   hooks  Unix socket at $DDVIZ_DATA_DIR/ddviz.sock. Unidirectional;
//          receives hook payloads from Claude Code, no responses.
//
//   stdio  Reads JSON-RPC from stdin, writes to stdout. Bidirectional;
//          supports tool calls, snapshots, and host requests.

import AppKit
import Dispatch
import Foundation
import WebKit

// MARK: - Configuration

/// Application-wide configuration. Created once in `main`, passed down
/// to all subsystems. No globals — every value flows through here.
struct Config {

  static let appName = "ddviz"
  static let appVersion = "0.7.17"
  static let pluginId = "claude-code-plugin"
  static let defaultWindowWidth = 610.0
  static let defaultWindowHeight = 400.0
  static let defaultPanelPosition: PanelPosition = .topRight(margin: 25)
  // pi (stdio) presents a larger panel centered over the parent app window.
  static let stdioWindowWidth = 820.0
  static let stdioWindowHeight = 450.0
  static let stdioPanelPosition: PanelPosition = .centeredOnParent
  static let defaultFrameSrc = "https://api.datadoghq.com/api/unstable/dataviz-mcp-ui"
  static let defaultTrustedDomainSuffixes = [".datadoghq.com", ".ddog-gov.com", ".datadoghq.eu"]
  static let hostBaseURL = URL(string: "https://ddviz.localhost")!
  static let jsHandlerName = "nativeBridge"

  /// Transport selected via `DDVIZ_IPC`. Defaults to `.hooks`.
  enum IPCMode { case hooks, stdio }

  let appName: String
  let appVersion: String
  let pluginId: String
  let debug: Bool
  /// Run the WebView without showing the panel (screenshot capture).
  let headless: Bool
  /// Data directory for runtime artifacts (log file, socket, lock).
  let dataDir: String
  /// Directory containing the ddviz binary and its `assets/` folder.
  let rootDir: String
  let windowWidth: Double
  let windowHeight: Double

  /// Domain suffixes trusted for navigation (e.g. `".datadoghq.com"`).
  let trustedDomainSuffixes: [String]
  /// URL loaded inside the WebView's iframe.
  let frameSrc: String
  /// CSP nonce injected into the host HTML.
  let cspNonce: String
  /// CSP `frame-src` directive value, derived from `frameSrc`.
  let cspFrameSrc: String
  /// Base URL for the WKWebView's `loadHTMLString`. Navigations to this
  /// origin are always allowed.
  let hostBaseURL: URL
  /// Name registered for `WKScriptMessageHandler`.
  let jsHandlerName: String
  /// Bundle ID of the parent app for activation tracking. Nil disables tracking,
  /// and is always nil when ``parentPID`` is.
  let parentBundleId: String?
  let panelPosition: PanelPosition
  /// When true, a system-status-bar item and minimal main menu are installed.
  /// Intended for clients (e.g. Claude Code) that run as a persistent daemon
  /// without their own menu bar presence.
  let menubarContext: Bool
  let ipcMode: IPCMode
  /// PID of the parent process (Claude Code) passed via `DDVIZ_PARENT_PID`.
  /// When set, ddviz terminates once this process exits.
  let parentPID: pid_t?

  /// Resolve all configuration from the process environment.
  /// Calls `fatalError` on invalid values or failed security primitives.
  static func resolve() -> Config {
    let debug = env("DDVIZ_DEBUG") == "1"
    let headless = env("DDVIZ_HEADLESS") == "1"
    // Mirrors the shell hooks' fallback (forward.sh, status.sh, enable.sh,
    // disable.sh all default to $HOME/.ddviz) so the daemon and the shell-side
    // enable/disable/status checks always agree on the marker file's location.
    let dataDir = env("DDVIZ_DATA_DIR") ?? (NSHomeDirectory() + "/.ddviz")
    let rootDir = URL(fileURLWithPath: CommandLine.arguments[0])
      .deletingLastPathComponent().path

    let menubarContext = env("DDVIZ_MENUBAR_CONTEXT") == "1"

    let ipcMode: IPCMode
    switch env("DDVIZ_IPC") {
    case "stdio": ipcMode = .stdio
    case "hooks": ipcMode = .hooks
    default: fatalError("DDVIZ_IPC must be 'hooks' or 'stdio'")
    }

    // pi (stdio) shows a larger panel centered over the parent window; hooks
    // (menubar) shows a compact panel anchored to the top-right corner.
    let panelPosition: PanelPosition
    let defaultWidth: Double
    let defaultHeight: Double
    switch ipcMode {
    case .stdio:
      panelPosition = stdioPanelPosition
      defaultWidth = stdioWindowWidth
      defaultHeight = stdioWindowHeight
    case .hooks:
      panelPosition = defaultPanelPosition
      defaultWidth = defaultWindowWidth
      defaultHeight = defaultWindowHeight
    }

    let windowWidth = env("DDVIZ_WIN_WIDTH").flatMap(Double.init) ?? defaultWidth
    let windowHeight = env("DDVIZ_WIN_HEIGHT").flatMap(Double.init) ?? defaultHeight
    // Debug mode only (DDVIZ_DEBUG=1) plus explicit test env: tests may add
    // loopback trusted suffixes so the iframe can load a local fixture. Not
    // active for a default user (both DDVIZ_DEBUG and the test var are needed).
    let testSuffixes = debug ? (env("DDVIZ_TEST_TRUSTED_SUFFIXES").map { $0.split(separator: ",").map(String.init) } ?? []) : []
    let trustedDomainSuffixes = (debug ? defaultTrustedDomainSuffixes + [".datad0g.com"] : defaultTrustedDomainSuffixes) + testSuffixes

    let cspNonce = generateCSPNonce()
    let frameSrc = resolveFrameSrc(
      defaultFrameSrc: defaultFrameSrc,
      trustedDomainSuffixes: trustedDomainSuffixes,
      debug: debug
    )
    let cspFrameSrc = deriveCSPFrameSrc(frameSrc: frameSrc, trustedDomainSuffixes: trustedDomainSuffixes)

    let parentPID: pid_t? = env("DDVIZ_PARENT_PID").flatMap { Int($0) }.map { pid_t($0) }

    // Only ever resolved alongside a PID, so the tracker can key it to the
    // session that owns it. Prefer the owning GUI app from the process tree;
    // fall back to the inherited `__CFBundleIdentifier`, then nil (always reveal).
    let parentBundleId: String? = parentPID.flatMap { pid in
      if let bid = resolveParentApp(startPID: pid) { return bid }
      // A stale id can name a quit app, which could never be frontmost.
      if let id = env("__CFBundleIdentifier"), !id.isEmpty,
        NSRunningApplication.runningApplications(withBundleIdentifier: id)
          .contains(where: { $0.activationPolicy == .regular })
      { return id }
      return nil
    }

    return Config(
      appName: appName,
      appVersion: appVersion,
      pluginId: pluginId,
      debug: debug,
      headless: headless,
      dataDir: dataDir,
      rootDir: rootDir,
      windowWidth: windowWidth,
      windowHeight: windowHeight,
      trustedDomainSuffixes: trustedDomainSuffixes,
      frameSrc: frameSrc,
      cspNonce: cspNonce,
      cspFrameSrc: cspFrameSrc,
      hostBaseURL: hostBaseURL,
      jsHandlerName: jsHandlerName,
      parentBundleId: parentBundleId,
      panelPosition: panelPosition,
      menubarContext: menubarContext,
      ipcMode: ipcMode,
      parentPID: parentPID
    )
  }

  /// Whether the IPC transport can deliver responses back to the iframe.
  /// Gates host capabilities that require a reply path (`serverTools`,
  /// `updateModelContext`); stdio supports it, hooks is unidirectional.
  var bidirectional: Bool { ipcMode == .stdio }

  /// Path for the UDS socket. Only meaningful for hooks-based adapters.
  var socketPath: URL {
    URL(fileURLWithPath: dataDir).appendingPathComponent("ddviz.sock")
  }

  /// Resolve an asset path relative to the `assets/` directory next to the binary.
  func assetPath(_ name: String) -> String {
    URL(fileURLWithPath: rootDir)
      .appendingPathComponent("assets")
      .appendingPathComponent(name).path
  }

  /// Check whether a URL's host matches one of the configured trusted
  /// domain suffixes. Used by the WebView bridge and navigation policy.
  func isTrustedURL(_ url: URL) -> Bool {
    Config.isTrustedURL(url, suffixes: trustedDomainSuffixes)
  }

  /// Static variant for use before a Config instance exists (e.g. during
  /// `resolve` when validating `DDVIZ_FRAME_SRC`).
  static func isTrustedURL(_ url: URL, suffixes: [String]) -> Bool {
    guard url.scheme?.lowercased() == "https" else { return false }
    guard let host = url.host?.lowercased(), !host.isEmpty else { return false }
    for suffix in suffixes {
      let domain = String(suffix.dropFirst())
      if host == domain || host.hasSuffix(suffix) { return true }
    }
    return false
  }

  private static func env(_ key: String) -> String? {
    ProcessInfo.processInfo.environment[key]
  }

  /// Parent process id of `pid` via `sysctl(KERN_PROC)`, or nil if unavailable.
  private static func parentPID(of pid: pid_t) -> pid_t? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else {
      return nil
    }
    let ppid = info.kp_eproc.e_ppid
    return ppid > 0 ? ppid : nil
  }

  /// Walk the process tree upward from `startPID` (inclusive) and return the
  /// bundle id of the first ancestor that is a user-activatable (`.regular`)
  /// GUI application.
  ///
  /// `.regular` is required because VS Code and Cursor run integrated terminals
  /// under an `.accessory` helper that can never become frontmost.
  static func resolveParentApp(startPID: pid_t, maxDepth: Int = 24) -> String? {
    var pid = startPID
    var depth = 0
    while pid > 1, depth < maxDepth {
      if let app = NSRunningApplication(processIdentifier: pid),
        let bid = app.bundleIdentifier, !bid.isEmpty,
        app.activationPolicy == .regular
      {
        return bid
      }
      guard let parent = parentPID(of: pid) else { break }
      pid = parent
      depth += 1
    }
    return nil
  }

  private static func generateCSPNonce() -> String {
    var bytes = [UInt8](repeating: 0, count: 16)
    let result = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    guard result == errSecSuccess else {
      fatalError("SecRandomCopyBytes failed")
    }
    return Data(bytes).base64EncodedString()
  }

  private static func resolveFrameSrc(
    defaultFrameSrc: String,
    trustedDomainSuffixes: [String],
    debug: Bool
  ) -> String {
    guard let override = env("DDVIZ_FRAME_SRC") else {
      return defaultFrameSrc
    }
    guard debug else {
      fatalError("DDVIZ_FRAME_SRC requires DDVIZ_DEBUG=1")
    }
    guard let url = URL(string: override),
      isTrustedURL(url, suffixes: trustedDomainSuffixes)
    else {
      fatalError("DDVIZ_FRAME_SRC '\(override)' is not a trusted origin")
    }
    return override
  }

  /// `frameSrc`'s own origin, plus a wildcard source per trusted domain
  /// suffix (the iframe may redirect from `frameSrc` to another trusted
  /// host, e.g. the CDN serving the versioned app).
  private static func deriveCSPFrameSrc(frameSrc: String, trustedDomainSuffixes: [String]) -> String {
    guard let url = URL(string: frameSrc),
      let scheme = url.scheme,
      let host = url.host
    else {
      fatalError("Cannot derive CSP frame-src origin from: \(frameSrc)")
    }
    let origin = url.port.map { "\(scheme)://\(host):\($0)" } ?? "\(scheme)://\(host)"
    let sources = [origin] + trustedDomainSuffixes.map { "https://*\($0)" }
    return sources.joined(separator: " ")
  }
}

// MARK: - Logging

/// Minimal structured logger for ddviz.
///
/// All output is gated behind `enabled`. When disabled, calls are no-ops.
/// When enabled, messages are written to both stderr and a log file.
struct Log {
  let namespace: String
  private let sink: Sink

  static func create(enabled: Bool, directory: String) -> Log {
    let sink = Sink(enabled: enabled, directory: directory)
    return Log(namespace: "App", sink: sink)
  }
  func scoped(_ namespace: String) -> Log {
    return Log(namespace: namespace, sink: sink)
  }
  func info(_ message: String) {
    sink.write("[\(namespace)] \(message)")
  }
  var fn: (String) -> Void {
    return { message in self.sink.write("[\(self.namespace)] \(message)") }
  }
}

extension Log {
  final class Sink {
    private let enabled: Bool
    private let queue = DispatchQueue(label: "ddviz.log")
    private let fileHandle: FileHandle?

    init(enabled: Bool, directory: String) {
      self.enabled = enabled
      if enabled {
        let path = URL(fileURLWithPath: directory)
          .appendingPathComponent("ddviz.log").path
        FileManager.default.createFile(atPath: path, contents: nil)
        self.fileHandle = FileHandle(forWritingAtPath: path)
      } else {
        self.fileHandle = nil
      }
    }

    func write(_ message: String) {
      guard enabled else { return }
      let data = Data((message + "\n").utf8)
      queue.async { [fileHandle] in
        FileHandle.standardError.write(data)
        fileHandle?.seekToEndOfFile()
        fileHandle?.write(data)
      }
    }
  }
}

// MARK: - Messages

/// Namespace for JSON-RPC 2.0 validation utilities.
enum JsonRpc {
  /// A validated JSON-RPC 2.0 payload.
  /// The raw dictionary has been checked for `"jsonrpc": "2.0"` at parse time.
  struct Payload {
    let raw: [String: Any]

    enum Kind {
      case request
      case response
      case notification
    }

    var kind: Kind {
      let hasId = raw["id"] != nil
      let hasMethod = raw["method"] is String
      if hasId && hasMethod { return .request }
      if hasId { return .response }
      return .notification
    }

    var method: String? { raw["method"] as? String }
  }

  static func validate(_ dict: [String: Any]) -> Payload? {
    guard dict["jsonrpc"] as? String == "2.0" else { return nil }
    return Payload(raw: dict)
  }

  static func request(id: Any, method: String, params: [String: Any]) -> Payload? {
    let dict: [String: Any] = [
      "jsonrpc": "2.0",
      "id": id,
      "method": method,
      "params": params,
    ]
    return validate(dict)
  }

  static func response(id: Any, result: [String: Any]) -> Payload? {
    let dict: [String: Any] = [
      "jsonrpc": "2.0",
      "id": id,
      "result": result,
    ]
    return validate(dict)
  }

  static func error(id: Any, code: Int, message: String) -> Payload? {
    let dict: [String: Any] = [
      "jsonrpc": "2.0",
      "id": id,
      "error": [
        "code": code,
        "message": message,
      ] as [String: Any],
    ]
    return validate(dict)
  }
}

/// Typed message produced by any IPC adapter after parsing raw transport data.
/// Each case maps to a distinct action the app delegate dispatches.
enum InboundMessage {
  /// Request app termination (explicit command from the client).
  case shutdown

  /// Show the panel (explicit command from the parent process).
  case show

  /// Hide the panel (explicit command from the parent process).
  case hide

  /// Toggle panel visibility (explicit command from the parent process).
  case toggle

  /// A native snapshot request from the client. Only meaningful for adapters
  /// that support bidirectional communication (e.g. stdio). The `id` is the
  /// JSON-RPC request id and must be echoed back in the response.
  case snapshot(id: String)

  /// A client session ended. Includes the session id so the app can
  /// track active sessions and terminate when none remain.
  case sessionEnd(sessionId: String)

  /// An inbound tool result (hook payload wrapped as a JSON-RPC notification,
  /// or a visualization notification from the parent process).
  case toolResult(sessionId: String?, parentPID: pid_t?, payload: JsonRpc.Payload)

  /// A JSON-RPC response to a tool call the iframe initiated.
  /// Carries `id` + `result`/`error`; routed back to the iframe.
  case toolCallResponse(payload: JsonRpc.Payload)

  /// Any other valid JSON-RPC payload not matched by a specific case.
  /// Includes JSON-RPC requests from the parent process (has `id` +
  /// `method`) that should be forwarded to the iframe as host requests.
  case opaque(sessionId: String?, payload: JsonRpc.Payload)
}

/// A message received from the iframe via the native bridge.
///
/// The host page forwards JSON-RPC 2.0 messages from the iframe
/// directly to the native bridge. The bridge validates the envelope,
/// classifies the message by `method`, and extracts associated values
/// for internal panel handling. The original ``JsonRpc/Payload`` is
/// preserved for uniform forwarding to the IPC adapter.
struct OutboundMessage {
  let kind: Kind
  let payload: JsonRpc.Payload

  /// Classification of the iframe message by JSON-RPC method.
  enum Kind {
    // Panel-internal lifecycle / commands
    case initialized
    case close
    case shutdown(reason: String)
    case requestDisplayMode(mode: String)
    case openLink(url: String)
    case sizeChanged(width: Double, height: Double)

    // Forwarded upstream via IPC
    case toolCall
    case unknown(method: String)

    /// A JSON-RPC response from the iframe to a host-initiated request.
    /// Has `id` + `result`/`error`, no `method`. Forwarded upstream as-is.
    case hostRequestResponse
  }

  /// Parse a raw JSON string from the native bridge into an ``OutboundMessage``.
  ///
  /// Expects a JSON-RPC 2.0 message. Returns nil if the string is not
  /// valid JSON or fails ``JsonRpc`` validation.
  static func parse(_ jsonString: String) -> OutboundMessage? {
    guard let data = jsonString.data(using: .utf8),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let rpc = JsonRpc.validate(json)
    else {
      return nil
    }

    switch rpc.kind {
    case .response:
      return OutboundMessage(kind: .hostRequestResponse, payload: rpc)

    case .request, .notification:
      guard let method = rpc.method else { return nil }
      let params = json["params"] as? [String: Any]
      let kind: Kind
      switch method {
      case "ui/notifications/initialized":
        kind = .initialized
      case "ui/close":
        kind = .close
      case "ui/shutdown":
        let reason = params?["reason"] as? String ?? "Unknown reason"
        kind = .shutdown(reason: reason)
      case "ui/request-display-mode":
        guard let mode = params?["mode"] as? String else {
          return OutboundMessage(kind: .unknown(method: method), payload: rpc)
        }
        kind = .requestDisplayMode(mode: mode)
      case "ui/open-link":
        guard let url = params?["url"] as? String else {
          return OutboundMessage(kind: .unknown(method: method), payload: rpc)
        }
        kind = .openLink(url: url)
      case "ui/notifications/size-changed":
        guard let w = params?["width"] as? Double,
          let h = params?["height"] as? Double
        else {
          return OutboundMessage(kind: .unknown(method: method), payload: rpc)
        }
        kind = .sizeChanged(width: w, height: h)
      case "tools/call":
        kind = .toolCall
      default:
        kind = .unknown(method: method)
      }
      return OutboundMessage(kind: kind, payload: rpc)
    }
  }
}

// MARK: - IPC

/// Transport-agnostic interface for IPC communication.
///
/// The inbound callback fires on the adapter's internal queue. Consumers
/// are responsible for dispatching to the main queue when needed.
protocol IPCAdapter: AnyObject {
  /// Begin receiving messages. Parsed messages are delivered through `onMessage`.
  func start(onMessage: @escaping (InboundMessage) -> Void)

  /// Stop receiving and release transport resources.
  func stop()

  /// Send a validated JSON-RPC payload to the client. Adapters that don't
  /// support outbound communication log and drop the payload.
  func send(_ payload: JsonRpc.Payload)
}

/// IPC adapter that receives Claude Code hook payloads over a Unix domain socket.
///
/// Unidirectional: messages flow in from hook scripts (via `nc -U` or similar),
/// are parsed into ``InboundMessage`` values, and delivered through a callback.
/// No responses are sent back to the client.
///
/// The callback fires on the adapter's internal serial queue. Consumers are
/// responsible for dispatching to the main queue when needed.
class IPCHooksAdapter: IPCAdapter {
  enum CreateResult {
    case success(IPCHooksAdapter)
    case failed
  }

  private let path: URL
  private var socketFD: Int32 = -1
  private var running = false
  private let queue = DispatchQueue(label: "IPCHooksAdapter")
  private var acceptSource: DispatchSourceRead?
  private let log: (String) -> Void

  /// Maximum size of a single newline-delimited IPC message (256 MB).
  private static let maxMessageBytes = 256 * 1024 * 1024

  /// Bind a Unix domain socket at `path` and return an adapter ready to start.
  ///
  /// The socket is created with `0o600` permissions so only the current user
  /// can connect. `umask` is temporarily narrowed during `bind`; this is safe
  /// because `create` runs at startup before concurrent queues are active.
  static func create(path: URL, log: @escaping (String) -> Void) -> CreateResult {
    let pathStr = path.path
    unlink(pathStr)

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

    return .success(IPCHooksAdapter(path: path, fd: fd, log: log))
  }

  private init(path: URL, fd: Int32, log: @escaping (String) -> Void) {
    self.path = path
    self.socketFD = fd
    self.log = log
  }

  /// Begin accepting connections. Each connected client is read until EOF;
  /// complete newline-delimited JSON messages are parsed and delivered as
  /// ``InboundMessage`` values through `onMessage`.
  func start(onMessage: @escaping (InboundMessage) -> Void) {
    running = true

    let source = DispatchSource.makeReadSource(fileDescriptor: socketFD, queue: queue)
    acceptSource = source

    source.setEventHandler { [weak self] in
      guard let self = self, self.running else { return }
      let clientFD = accept(self.socketFD, nil, nil)
      guard clientFD >= 0 else { return }
      self.handleClient(fd: clientFD, onMessage: onMessage)
    }

    source.setCancelHandler { [weak self] in
      guard let self = self else { return }
      if self.socketFD >= 0 {
        Darwin.close(self.socketFD)
        self.socketFD = -1
      }
    }

    source.resume()
    log("Listening on \(path.path)")
  }

  func stop() {
    running = false
    acceptSource?.cancel()
    acceptSource = nil
    try? FileManager.default.removeItem(at: path)
  }

  /// Hooks are unidirectional — outbound messages are not supported.
  func send(_ payload: JsonRpc.Payload) {
    log("send() called on hooks adapter (unidirectional), dropping")
  }

  deinit { stop() }

  /// Read newline-delimited messages from a single client connection.
  private func handleClient(fd: Int32, onMessage: @escaping (InboundMessage) -> Void) {
    var buffer = Data()
    let newline = UInt8(ascii: "\n")
    let log = self.log

    let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)

    source.setEventHandler {
      var chunk = [UInt8](repeating: 0, count: 65536)
      let bytesRead = Darwin.read(fd, &chunk, chunk.count)

      if bytesRead > 0 {
        buffer.append(contentsOf: chunk[0..<bytesRead])

        if buffer.count > IPCHooksAdapter.maxMessageBytes {
          log("Message exceeded \(IPCHooksAdapter.maxMessageBytes) bytes, dropping")
          source.cancel()
          return
        }

        // Process complete newline-delimited lines as they arrive so we
        // don't wait for EOF if the payload has a trailing newline.
        while let i = buffer.firstIndex(of: newline) {
          let line = buffer[buffer.startIndex..<i]
          buffer = Data(buffer[buffer.index(after: i)...])
          if !line.isEmpty {
            for message in IPCHooksAdapter.parse(Data(line), log: log) {
              onMessage(message)
            }
          }
        }
      } else {
        if !buffer.isEmpty {
          for message in IPCHooksAdapter.parse(Data(buffer), log: log) {
            onMessage(message)
          }
        }
        source.cancel()
      }
    }

    source.setCancelHandler {
      Darwin.close(fd)
    }

    source.resume()
  }

  /// Parse a single newline-delimited JSON payload into zero or more
  /// ``InboundMessage`` values.
  private static func parse(_ data: Data, log: (String) -> Void) -> [InboundMessage] {
    let preview = String(data: data.prefix(512), encoding: .utf8) ?? "<binary>"
    log("Received: \(preview)\(data.count > 512 ? "... (\(data.count) bytes)" : "")")

    guard let json = try? JSONSerialization.jsonObject(with: data),
      let dict = json as? [String: Any]
    else {
      log("Dropping invalid JSON")
      return []
    }

    if let command = dict["command"] as? String {
      switch command {
      case "shutdown": return [.shutdown]
      case "show":     return [.show]
      case "hide":     return [.hide]
      case "toggle":   return [.toggle]
      default:
        log("Dropping unknown command: \(command)")
        return []
      }
    }

    // Snapshot is not supported in hooks mode (unidirectional transport).
    if let payload = JsonRpc.validate(dict), payload.method == "snapshot" {
      log("Dropping snapshot request (not supported in hooks mode)")
      return []
    }

    let sessionId = dict["session_id"] as? String
    let parentPID = (dict["ddviz_parent_pid"] as? NSNumber).map { pid_t($0.intValue) }
    let hookEvent = dict["hook_event_name"] as? String
    let wrapped: [String: Any]
    switch hookEvent {
    case "SessionEnd":
      if let sessionId = sessionId {
          return [.sessionEnd(sessionId: sessionId)]
      }
      return []
    case "PreToolUse":
      // Loading state only — deliver content but do not reveal.
      wrapped = [
        "jsonrpc": "2.0",
        "method": "ui/notifications/tool-input",
        "params": ["arguments": [String: Any]()],
      ]
      return [.toolResult(sessionId: sessionId, parentPID: parentPID, payload: JsonRpc.validate(wrapped)!)]
    case "PostToolUse":
      let response = dict["tool_response"]
      var structuredContent: Any
      if let responseStr = response as? String,
         let parsed = try? JSONSerialization.jsonObject(
           with: Data(responseStr.utf8))
      {
        structuredContent = parsed
      } else {
        structuredContent = response ?? [:]
      }
      var content: Any = [["type": "text", "text": ""]]
      if let dict = structuredContent as? [String: Any] {
        if let originalContent = dict["content"] {
          content = originalContent
        }
        if let nested = dict["structuredContent"] {
          structuredContent = nested
        }
      }

      wrapped = [
        "jsonrpc": "2.0",
        "method": "ui/notifications/tool-result",
        "params": [
          "content": content,
          "structuredContent": structuredContent,
        ],
      ]

      // Deliver the visualization data, then reveal the panel.
      return [
        .toolResult(sessionId: sessionId, parentPID: parentPID, payload: JsonRpc.validate(wrapped)!),
        .show,
      ]
    default:
      log("Dropping unknown hook event: \(hookEvent ?? "<nil>")")
      return []
    }
  }
}

private let ddvizTelemetryClientToken = "pub9e6850a2eb60360846c8dd17080ce916"
private let ddvizTelemetrySite = "datadoghq.com"
private let ddvizTelemetryService = "dataviz-mcp-ui"
private let ddvizTelemetryLogger = "ddviz-hook"

// Shells out to curl (like disable() shells out to osascript) instead of
// URLSession: the daemon calls NSApp.terminate right after this, and an
// in-process URLSession task is killed with it before it can send anything.
private func emitTelemetryEvent(event: String, status: String, attributes: [String: String], log: Log) {
  let env = ProcessInfo.processInfo.environment
  if env["DO_NOT_TRACK"] == "1" || env["DO_NOT_TRACK"] == "true" { return }
  if env["DISABLE_TELEMETRY"] == "1" || env["DISABLE_TELEMETRY"] == "true" { return }

  let attrLog = attributes.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
  log.info("Emitting telemetry: event=\(event) status=\(status)\(attrLog.isEmpty ? "" : " " + attrLog)")

  let ddtags = "env:prod,service:\(ddvizTelemetryService),version:\(Config.appVersion),plugin_id:\(Config.pluginId),event:\(event),status:\(status)"
  var payload: [String: Any] = attributes
  payload["service"] = ddvizTelemetryService
  payload["ddtags"] = ddtags
  payload["status"] = status
  payload["logger"] = ["name": ddvizTelemetryLogger]

  guard let body = try? JSONSerialization.data(withJSONObject: payload),
    let bodyString = String(data: body, encoding: .utf8)
  else { return }

  // Test-only: honored only under DDVIZ_HEADLESS so a stray shell export
  // can't silently redirect real telemetry.
  let urlOverride = env["DDVIZ_HEADLESS"] == "1" ? env["DDVIZ_TELEMETRY_URL"] : nil
  let url = urlOverride
    ?? "https://browser-intake-\(ddvizTelemetrySite)/api/v2/logs?ddsource=browser&dd-api-key=\(ddvizTelemetryClientToken)"

  let curl = Process()
  curl.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
  curl.arguments = ["-sf", "-m", "2", "-X", "POST", url, "-H", "Content-Type: application/json", "-d", bodyString]
  curl.standardOutput = FileHandle.nullDevice
  try? curl.run()
}

/// Construct a `sockaddr_un` from `path` and pass it to `body` with the
/// correctly sized length. Returns the value returned by `body`, or -1
/// if the path exceeds the Unix domain socket path limit.
@discardableResult
private func withSockAddr(
  path: String,
  body: (UnsafePointer<sockaddr>, socklen_t) -> Int32
) -> Int32 {
  var addr = sockaddr_un()
  let maxPathLen = MemoryLayout.size(ofValue: addr.sun_path) - 1

  guard path.utf8.count <= maxPathLen else { return -1 }

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

/// IPC adapter that reads newline-delimited JSON from stdin.
class IPCStdioAdapter: IPCAdapter {
  private let queue = DispatchQueue(label: "IPCStdioAdapter")
  private var source: DispatchSourceRead?
  private var buffer = Data()
  private var running = false
  private let log: (String) -> Void

  /// Maximum size of a single newline-delimited IPC message (256 MB).
  private static let maxMessageBytes = 256 * 1024 * 1024

  init(log: @escaping (String) -> Void) {
    self.log = log
  }

  func start(onMessage: @escaping (InboundMessage) -> Void) {
    running = true
    let fd = FileHandle.standardInput.fileDescriptor

    // Non-blocking so DispatchSource semantics behave; partial reads are fine.
    let flags = fcntl(fd, F_GETFL, 0)
    _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

    let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
    source = src
    let newline = UInt8(ascii: "\n")
    let log = self.log

    src.setEventHandler { [weak self] in
      guard let self = self, self.running else { return }
      var chunk = [UInt8](repeating: 0, count: 65536)
      let bytesRead = Darwin.read(fd, &chunk, chunk.count)

      if bytesRead > 0 {
        self.buffer.append(contentsOf: chunk[0..<bytesRead])

        if self.buffer.count > IPCStdioAdapter.maxMessageBytes {
          log("Message exceeded \(IPCStdioAdapter.maxMessageBytes) bytes, dropping")
          self.buffer.removeAll()
          return
        }

        while let i = self.buffer.firstIndex(of: newline) {
          let line = self.buffer[self.buffer.startIndex..<i]
          self.buffer = Data(self.buffer[self.buffer.index(after: i)...])
          if !line.isEmpty {
            if let message = IPCStdioAdapter.parse(Data(line), log: log) {
              onMessage(message)
            }
          }
        }
      } else if bytesRead == 0 {
        // EOF — parent closed stdin, time to shut down.
        if !self.buffer.isEmpty {
          if let message = IPCStdioAdapter.parse(Data(self.buffer), log: log) {
            onMessage(message)
          }
          self.buffer.removeAll()
        }
        self.running = false
        src.cancel()
        log("stdin EOF — synthesizing shutdown")
        onMessage(.shutdown)
      } else if errno != EAGAIN && errno != EWOULDBLOCK {
        log("stdin read error: errno=\(errno)")
        self.running = false
        src.cancel()
        onMessage(.shutdown)
      }
    }

    src.resume()
    log("Reading from stdin")
  }

  func stop() {
    running = false
    source?.cancel()
    source = nil
  }

  func send(_ payload: JsonRpc.Payload) {
    guard let data = try? JSONSerialization.data(withJSONObject: payload.raw),
      var line = String(data: data, encoding: .utf8)
    else {
      log("Failed to serialize outbound payload")
      return
    }
    line.append("\n")
    if let bytes = line.data(using: .utf8) {
      FileHandle.standardOutput.write(bytes)
    }
    log("Sent: \(payload.method ?? "<response>")")
  }

  /// Parse a single newline-delimited JSON payload into an ``InboundMessage``.
  private static func parse(_ data: Data, log: (String) -> Void) -> InboundMessage? {
    let preview = String(data: data.prefix(512), encoding: .utf8) ?? "<binary>"
    log("Received: \(preview)\(data.count > 512 ? "... (\(data.count) bytes)" : "")")

    guard let json = try? JSONSerialization.jsonObject(with: data),
      let dict = json as? [String: Any]
    else {
      log("Dropping invalid JSON")
      return nil
    }

    if let command = dict["command"] as? String {
      switch command {
      case "shutdown": return .shutdown
      case "show":     return .show
      case "hide":     return .hide
      case "toggle":   return .toggle
      default:
        log("Dropping unknown command: \(command)")
        return nil
      }
    }

    if let payload = JsonRpc.validate(dict) {
      switch payload.kind {
      case .response:
        // Response to a tool call the iframe initiated.
        return .toolCallResponse(payload: payload)
      case .request, .notification:
        // Native snapshot request — handle in-process rather than forwarding.
        if payload.method == "snapshot", let id = dict["id"] {
          return .snapshot(id: String(describing: id))
        }
        // Request (host request from pi) or notification (viz data).
        return .opaque(sessionId: nil, payload: payload)
      }
    }

    log("Dropping non-JSON-RPC payload")
    return nil
  }
}

// MARK: - WebView Bridge

/// Namespace for WebView ↔ native communication primitives.
enum WebViewBridge {
  /// A validated JS script. Can only be constructed via `prepareJsCall`.
  struct SafeJs {
    let script: String
    fileprivate init(_ script: String) { self.script = script }
  }

  /// Build a safe JS function call via double-serialization.
  ///
  /// The function name is validated as a strict ASCII identifier.
  /// The payload is JSON-serialized, then the resulting string is
  /// JSON-escaped again so it can be safely embedded in a JS literal.
  static func prepareJsCall(_ fnName: String, payload: Any) -> SafeJs {
    precondition(
      !fnName.isEmpty
        && fnName.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }),
      "Invalid JS identifier: \(fnName)"
    )

    let jsonData = try! JSONSerialization.data(withJSONObject: payload)
    let jsonStr = String(data: jsonData, encoding: .utf8)!

    // Double-serialize: JSONSerialization requires arrays/dicts at top level,
    // so wrap the string in an array, serialize, then strip the brackets.
    let wrappedData = try! JSONSerialization.data(withJSONObject: [jsonStr])
    let wrappedStr = String(data: wrappedData, encoding: .utf8)!
    let safeJSON = String(wrappedStr.dropFirst().dropLast())

    return SafeJs("if (typeof \(fnName) === 'function') { \(fnName)(JSON.parse(\(safeJSON))); }")
  }

  /// Evaluate a validated JS script in a WKWebView. Fire-and-forget.
  static func evalJs(_ webView: WKWebView, _ safeJs: SafeJs) {
    webView.evaluateJavaScript(safeJs.script, completionHandler: nil)
  }

  /// Forward a JSON-RPC payload to the iframe via the host page's `sendToApp`.
  static func sendToApp(_ webView: WKWebView, payload: Any) {
    evalJs(webView, prepareJsCall("sendToApp", payload: payload))
  }

  static func notifyThemeChanged(_ webView: WKWebView, theme: String) {
    evalJs(webView, prepareJsCall("handleThemeChanged", payload: ["theme": theme]))
  }

  static func notifyDisplayModeChanged(_ webView: WKWebView, mode: String) {
    evalJs(webView, prepareJsCall("handleDisplayModeChanged", payload: ["mode": mode]))
  }

  static func notifyFocusChanged(_ webView: WKWebView, focused: Bool) {
    evalJs(webView, prepareJsCall("handleWindowFocusChanged", payload: ["focused": focused]))
  }

  static func notifyFixedHeightChanged(_ webView: WKWebView, hasFixedHeight: Bool) {
    evalJs(
      webView,
      prepareJsCall(
        "handleFixedHeightChanged", payload: ["hasFixedHeight": hasFixedHeight]))
  }

  /// Create and configure a WKWebView for the ddviz host page.
  static func createWebView(
    config: Config,
    frame: NSRect,
    messageHandler: WKScriptMessageHandler,
    navigationDelegate: WKNavigationDelegate
  ) -> WKWebView {
    let wkConfig = WKWebViewConfiguration()
    wkConfig.websiteDataStore = .nonPersistent()
    wkConfig.userContentController.add(messageHandler, name: config.jsHandlerName)
    wkConfig.applicationNameForUserAgent = "\(config.appName)/\(config.appVersion) (\(config.pluginId))"

    let webView = WKWebView(frame: frame, configuration: wkConfig)
    webView.autoresizingMask = [.width, .height]
    webView.setValue(false, forKey: "drawsBackground")
    webView.navigationDelegate = navigationDelegate

    if #available(macOS 13.3, *) {
      webView.isInspectable = config.debug
    }

    let hostHTML = loadHostHTML(config: config)
    webView.loadHTMLString(hostHTML, baseURL: config.hostBaseURL)
    return webView
  }

  /// Load and template the `mcp-host.html` asset.
  static func loadHostHTML(config: Config) -> String {
    let path = config.assetPath("mcp-host.html")
    guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else {
      fatalError("Could not load assets/mcp-host.html from \(config.rootDir)")
    }

    return substitute(
      raw,
      values: [
        ("FRAME_SRC", config.frameSrc),
        ("DEBUG", config.debug ? "true" : "false"),
        ("CSP_FRAME_SRC", config.cspFrameSrc),
        ("TRUSTED_DOMAIN_SUFFIXES", jsonArray(config.trustedDomainSuffixes)),
        ("CSP_NONCE", config.cspNonce),
        ("HOST_NAME", config.appName),
        ("HOST_VERSION", config.appVersion),
        ("BIDIRECTIONAL", config.bidirectional ? "true" : "false"),
      ])
  }

  private static func jsonArray(_ values: [String]) -> String {
    let data = try! JSONSerialization.data(withJSONObject: values)
    return String(data: data, encoding: .utf8)!
  }

  /// Substitute `{{key}}` placeholders in a template string.
  private static func substitute(
    _ template: String,
    values: [(String, String)]
  ) -> String {
    var safe = CharacterSet.alphanumerics
    safe.insert(charactersIn: "-._~:/?#@=&+!,;%()*[]\" ")
    var result = template
    for (key, value) in values {
      guard value.unicodeScalars.allSatisfy({ safe.contains($0) }) else {
        fatalError("Template variable {{\(key)}} contains characters unsafe for templating")
      }
      result = result.replacingOccurrences(of: "{{\(key)}}", with: value)
    }
    return result
  }
}

// MARK: - Panel Support

/// Initial positioning strategy for the VizPanel window.
enum PanelPosition {
  /// Top-right corner of the main screen with the given margin.
  case topRight(margin: CGFloat)
  /// Centered within the parent application's window. Falls back to
  /// screen center if no single suitable parent window exists.
  case centeredOnParent
}

/// Tracks parent application state and parent process liveness. Consolidates
/// all "should ddviz stay alive?" logic:
///
/// - **App activation** (NSWorkspace) — drives panel show/hide.
/// - **Process liveness** (kqueue) — watches each parent (Claude Code) PID;
///   when the last watched PID exits (including `kill -9`), fires `onShouldTerminate`.
///
/// Each session's parent app is the GUI app containing its terminal. They
/// register as the session's PID is watched and drop when that app's last
/// session exits. With none registered, `isParentActive` is true and
/// `windowFrames()` returns an empty array. Registration state is main-queue owned.
class ParentAppTracker {
  /// Sole source of truth: an app is tracked while any watched session maps to it.
  private var pidParentApps: [pid_t: String] = [:]
  private var parentBundleIds: Set<String> { Set(pidParentApps.values) }
  private(set) var isParentActive: Bool
  var onActivated: (() -> Void)?
  var onDeactivated: (() -> Void)?

  /// Fired (on the main queue) when ddviz should terminate. The string
  /// describes why (e.g. "all watched processes exited").
  var onShouldTerminate: ((_ reason: String) -> Void)?

  private let log: Log

  static func isActive(frontmost: String?, parents: Set<String>) -> Bool {
    parents.isEmpty || (frontmost.map(parents.contains) ?? false)
  }

  init(parentBundleId: String?, parentPID: pid_t?, log: Log) {
    self.log = log
    // Keyed by PID so the founding app drops when its session exits.
    let apps = parentPID.flatMap { pid in parentBundleId.map { [pid: $0] } } ?? [:]
    self.pidParentApps = apps
    self.isParentActive = Self.isActive(
      frontmost: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
      parents: Set(apps.values))

    log.info(
      apps.values.first.map { "Tracking \($0) (currently \(isParentActive ? "active" : "inactive"))" }
        ?? "No parent app — reveal always allowed until one registers")

    // Sessions in other apps register later, so nothing to opt out of here.
    let nc = NSWorkspace.shared.notificationCenter
    nc.addObserver(
      self, selector: #selector(frontmostAppChanged(_:)),
      name: NSWorkspace.didActivateApplicationNotification, object: nil)
    nc.addObserver(
      self, selector: #selector(frontmostAppChanged(_:)),
      name: NSWorkspace.didDeactivateApplicationNotification, object: nil)
  }

  deinit {
    NSWorkspace.shared.notificationCenter.removeObserver(self)
    stopPIDWatching()
  }

  /// Screen-coordinate frames of all on-screen windows belonging to every
  /// registered parent app. Uses `CGWindowListCopyWindowInfo` which requires no
  /// special permissions.
  func windowFrames() -> [NSRect] {
    guard !parentBundleIds.isEmpty else { return [] }
    let pids = Set(
      parentBundleIds.flatMap {
        NSRunningApplication.runningApplications(withBundleIdentifier: $0).map {
          $0.processIdentifier
        }
      })
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
      // CGWindowListCopyWindowInfo reports positions in the CG coordinate system:
      // origin at the top-left of the PRIMARY display (the one with the menu bar),
      // y increasing downward. AppKit uses the same primary display as its reference
      // with the y-axis flipped (bottom-left origin). The flip formula is:
      //   nsY = primaryHeight - cgY - windowHeight
      //
      // NSScreen.main is the FOCUSED screen (keyboard focus), not necessarily the
      // primary display. On multi-monitor setups where the parent app sits on a
      // secondary monitor, using NSScreen.main's height gives the wrong primary
      // height and shifts all y-coordinates into an off-screen region.
      //
      // NSScreen.screens[0] is always the primary (menu-bar) display.
      let primaryHeight = NSScreen.screens.first?.frame.height ?? NSScreen.main?.frame.height ?? 0
      frames.append(NSRect(x: x, y: primaryHeight - y - h, width: w, height: h))
    }
    return frames
  }

  /// Compute the initial origin for a panel of the given size.
  /// Returns `nil` when the caller should fall back to `NSWindow.center()`.
  func panelOrigin(for panelFrame: NSRect, position: PanelPosition) -> NSPoint? {
    switch position {
    case .topRight(let margin):
      guard let sf = NSScreen.main?.visibleFrame else { return nil }
      return NSPoint(
        x: sf.origin.x + sf.width - panelFrame.width - margin,
        y: sf.origin.y + sf.height - panelFrame.height - margin
      )

    case .centeredOnParent:
      let frames = windowFrames()
      guard frames.count == 1 else { return nil }
      let pf = frames[0]
      guard pf.width > panelFrame.width && pf.height > panelFrame.height else { return nil }
      return NSPoint(
        x: pf.origin.x + (pf.width - panelFrame.width) / 2,
        y: pf.origin.y + (pf.height - panelFrame.height) / 2
      )
    }
  }

  private var pidSources: [pid_t: DispatchSourceProcess] = [:]
  private let pidQueue = DispatchQueue(label: "ParentAppTracker.pid")

  /// Watch a parent (Claude Code) process. The daemon lives as long as any
  /// watched process is alive and terminates once the last one exits — including
  /// on `kill -9`, which the `SessionEnd` hook can't catch. Idempotent, and a
  /// no-op if the PID is already dead. All `pidSources` access is serialized on
  /// `pidQueue`, the same queue the exit handler runs on.
  func watchPID(_ pid: pid_t) {
    guard pid > 0 else { return }
    pidQueue.sync {
      guard pidSources[pid] == nil else { return }
      guard kill(pid, 0) == 0 else {
        log.info("PID \(pid) already dead, not watching")
        terminateIfNoneWatched()
        return
      }
      let source = DispatchSource.makeProcessSource(
        identifier: pid, eventMask: .exit, queue: pidQueue)
      source.setEventHandler { [weak self] in
        guard let self else { return }
        source.cancel()
        self.pidSources.removeValue(forKey: pid)
        self.log.info("PID \(pid) exited (remaining: \(self.pidSources.count))")
        DispatchQueue.main.async { [weak self] in self?.unregisterParentApp(for: pid) }
        self.terminateIfNoneWatched()
      }
      pidSources[pid] = source
      source.resume()
      log.info("Watching PID \(pid) (total: \(pidSources.count))")
      DispatchQueue.main.async { [weak self] in self?.registerParentApp(for: pid) }
    }
  }

  /// Terminate once no watched process remains. Must run on `pidQueue`.
  private func terminateIfNoneWatched() {
    guard pidSources.isEmpty else { return }
    DispatchQueue.main.async { [weak self] in self?.onShouldTerminate?("all watched processes exited") }
  }

  private func stopPIDWatching() {
    pidQueue.sync {
      for (_, source) in pidSources { source.cancel() }
      pidSources.removeAll()
    }
  }

  @objc private func frontmostAppChanged(_ notification: Notification) {
    refreshParentActive()
  }

  /// Recompute from the current frontmost app, not the notification's app:
  /// switching between parent apps delivers deactivate and activate in no fixed order.
  private func refreshParentActive() {
    dispatchPrecondition(condition: .onQueue(.main))
    let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    let parents = parentBundleIds
    // Frontmost is transiently nil mid-switch; with no parents the answer is true anyway.
    if frontmost == nil && !parents.isEmpty { return }
    let active = Self.isActive(frontmost: frontmost, parents: parents)
    guard active != isParentActive else { return }
    isParentActive = active
    log.info("Parent app \(active ? "activated" : "deactivated") (frontmost: \(frontmost ?? "none"))")
    if active { onActivated?() } else { onDeactivated?() }
  }

  private func registerParentApp(for pid: pid_t) {
    dispatchPrecondition(condition: .onQueue(.main))
    guard let bundleId = Config.resolveParentApp(startPID: pid) else {
      log.info("No activatable parent app for PID \(pid) — reveal always allowed")
      return
    }
    pidParentApps[pid] = bundleId
    log.info("Registered parent app \(bundleId) for PID \(pid) (parents: \(parentBundleIds.count))")
    refreshParentActive()
  }

  private func unregisterParentApp(for pid: pid_t) {
    dispatchPrecondition(condition: .onQueue(.main))
    guard let bundleId = pidParentApps.removeValue(forKey: pid) else { return }
    if !parentBundleIds.contains(bundleId) {
      log.info("Unregistered parent app \(bundleId) (parents: \(parentBundleIds.count))")
    }
    refreshParentActive()
  }
}

/// Panel visibility state. All transitions flow through
/// ``VizPanel/updateAppearance(forceFullOpacity:)``.
enum PanelAppearance: String {
  case hidden   // not on screen
  case idle     // visible, dimmed, close button hidden
  case active   // visible, full opacity, close button visible
}

/// Visibility intent policy for the panel.
enum UserIntent {
  case dismissed  // hidden until an explicit re-show
  case sticky     // visible while a parent app is frontmost, or the panel is key
  case pinned     // visible regardless of focus; the next setParentActive call (either direction) returns it to .sticky
}

/// Invisible overlay at the top of the panel that enables window dragging.
private class DragHandleView: NSView {
  required init?(coder: NSCoder) { fatalError() }
  override init(frame frameRect: NSRect) { super.init(frame: frameRect) }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
}

/// Notification-style close button: a circular × that fades in on hover.
class CloseButton: NSView {
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

// MARK: - Panel

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
    static let dragHandleHeight: CGFloat = 30
    static let closeButtonSize: CGFloat = 21
    static let closeButtonMargin: CGFloat = 7
    /// Floor for a content-driven resize.
    static let minContentHeight: CGFloat = 320
    /// A live drag shorter than this reads as a mis-click, not intent to fix the
    /// height. macOS has no published equivalent; matches GTK's drag-threshold
    /// default.
    static let userResizeThreshold: CGFloat = 8
    /// Deltas below this are ignored, which stops a resize feeding the next report.
    static let contentHeightEpsilon: CGFloat = 12
  }

  private let config: Config
  private let log: Log
  let parentTracker: ParentAppTracker
  private(set) var webView: WKWebView!
  private var closeButton: CloseButton!
  private(set) var isFrameReady = false
  private var pendingPayloads: [JsonRpc.Payload] = []
  var inlineFrame: NSRect = .zero
  /// Set by `setDisplayMode`. Content-driven resizes are skipped in fullscreen,
  /// where the frame is owned by the display mode rather than the app.
  private(set) var displayMode: DisplayMode = .inline
  private(set) var hasFixedHeight = false
  /// Set around every native `setFrame` call, so a resize we trigger ourselves
  /// (fullscreen toggle, content-driven resize) can't be mistaken for the user
  /// dragging the edge.
  private var isProgrammaticResize = false
  private var liveResizeStartHeight: CGFloat?
  private var themeObservation: NSKeyValueObservation?
  /// Starts `.dismissed` so the panel stays hidden until an explicit show
  private(set) var userIntent: UserIntent = .dismissed
  /// One-shot: when set, the next show grabs key focus.
  private var grabFocusOnNextShow = false
  private(set) var currentAppearance: PanelAppearance = .hidden
  var onInitialized: (() -> Void)?
  var onShutdown: ((String) -> Void)?
  /// Called when the iframe sends a message that should be forwarded
  /// upstream (initialization, tool call, host request response,
  /// send-user-message).
  var onOutbound: ((OutboundMessage) -> Void)?

  init(config: Config, log: Log, parentTracker: ParentAppTracker) {
    self.config = config
    self.log = log.scoped("GUI")
    self.parentTracker = parentTracker

    let frame = NSRect(x: 0, y: 0, width: config.windowWidth, height: config.windowHeight)
    super.init(
      contentRect: frame,
      styleMask: [.resizable, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )

    hasShadow = false
    isOpaque = false
    backgroundColor = .clear
    level = .floating
    hidesOnDeactivate = false
    inlineFrame = frame

    if let origin = parentTracker.panelOrigin(for: frame, position: config.panelPosition) {
      setFrameOrigin(origin)
      if screen == nil {
        // The computed origin landed off every display (e.g. multi-monitor coordinate
        // conversion edge-case). Fall back to centering on the primary screen so the
        // panel is always findable.
        center()
        log.info("Initial position: origin (\(Int(origin.x)),\(Int(origin.y))) was off all screens, falling back to center()")
      }
    } else {
      center()
    }

    webView = WebViewBridge.createWebView(
      config: config,
      frame: frame,
      messageHandler: self,
      navigationDelegate: self
    )
    log.info("Loading frame src: \(config.frameSrc)")

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

    let bs = Constants.closeButtonSize
    let bm = Constants.closeButtonMargin
    closeButton = CloseButton(
      frame: NSRect(
        x: bm,
        y: container.bounds.height - bs - bm,
        width: bs,
        height: bs
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

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleWillStartLiveResize),
      name: NSWindow.willStartLiveResizeNotification,
      object: self)
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleWindowDidResize),
      name: NSWindow.didResizeNotification,
      object: self)
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleDidEndLiveResize),
      name: NSWindow.didEndLiveResizeNotification,
      object: self)

    updateAppearance()

    // Headless: order front at alpha 0 so WebKit renders at full rate
    // (off-screen windows are throttled to ~1 fps). canBecomeKey returns false
    // in headless mode so WebKit cannot make this window key, which is what
    // would otherwise activate the process and steal focus from the terminal.
    if config.headless {
      ignoresMouseEvents = true
      orderFrontRegardless()
    }
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  private var currentTheme: String {
    let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    return isDark ? "dark" : "light"
  }

  private func notifyThemeChanged() {
    let t = currentTheme
    log.info("Theme changed: \(t)")
    WebViewBridge.notifyThemeChanged(webView, theme: t)
  }

  private func notifyFixedHeightChanged() {
    WebViewBridge.notifyFixedHeightChanged(webView, hasFixedHeight: hasFixedHeight)
  }

  override func mouseEntered(with event: NSEvent) {
    updateAppearance()
  }

  override var canBecomeKey: Bool { !config.headless }

  @objc func closeWindow(_ sender: Any?) {
    userClose()
  }

  override func cancelOperation(_ sender: Any?) {
    userClose()
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    // In menubar context the main menu owns all keyboard shortcuts.
    if config.menubarContext { return super.performKeyEquivalent(with: event) }
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    // Cmd+W / Cmd+Q — standard macOS close shortcuts.
    if flags == .command &&
       (event.charactersIgnoringModifiers == "w" || event.charactersIgnoringModifiers == "q") {
      userClose()
      return true
    }
    // Ctrl+Shift+O — mirrors the pi toggle shortcut so it works when the
    // panel has key focus. keyCode 31 = physical O on all layouts (AZERTY etc).
    if flags == [.control, .shift] && event.keyCode == 31 {
      userClose()
      return true
    }
    return super.performKeyEquivalent(with: event)
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
    WebViewBridge.notifyFocusChanged(webView, focused: focused)
  }

  private func setCloseButtonVisible(_ visible: Bool) {
    closeButton.setVisible(visible)
  }

  private func animateAlpha(to alpha: CGFloat, duration: TimeInterval) {
    // In headless mode the window must stay invisible (alpha 0) so the
    // user never sees it, while still being on-screen for WKWebView rendering.
    guard !config.headless else { return }
    NSAnimationContext.beginGrouping()
    NSAnimationContext.current.duration = duration
    animator().alphaValue = alpha
    NSAnimationContext.endGrouping()
  }

  /// Fraction of the panel's area covered by parent app windows (0.0–1.0+).
  private func parentOverlapRatio() -> CGFloat {
    let panelArea = frame.width * frame.height
    guard panelArea > 0 else { return 0 }
    return parentTracker.windowFrames().reduce(0) { sum, parentFrame in
      let ix = frame.intersection(parentFrame)
      return ix.isNull ? sum : sum + ix.width * ix.height
    } / panelArea
  }

  func updateAppearance(forceFullOpacity: Bool = false) {
    let mouseInside = frame.contains(NSEvent.mouseLocation)
    let overlapRatio = parentOverlapRatio()
    let visible: Bool = {
      switch userIntent {
      case .dismissed: return false
      case .pinned: return true
      case .sticky: return parentTracker.isParentActive || isKeyWindow
      }
    }()
    let desired: PanelAppearance =
      !visible ? .hidden : (isKeyWindow || mouseInside) ? .active : .idle
    let changed = desired != currentAppearance
    let previous = currentAppearance
    if changed {
      currentAppearance = desired
      log.info(
        "updateAppearance: \(previous.rawValue) → \(desired.rawValue) [intent=\(userIntent) parentActive=\(parentTracker.isParentActive) key=\(isKeyWindow) mouseIn=\(mouseInside) overlap=\(String(format: "%.0f%%", overlapRatio * 100))]"
      )
    }

    let becomingVisible = changed && previous == .hidden && desired != .hidden
    if becomingVisible {
      alphaValue = 0
      if grabFocusOnNextShow {
        makeKeyAndOrderFront(nil)
      } else {
        orderFront(nil)
      }
    }
    grabFocusOnNextShow = false

    switch desired {
    case .hidden:
      if changed {
        orderOut(nil)
      }

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

  private func flashBorder() {
    guard let layer = contentView?.layer else { return }
    let anim = CABasicAnimation(keyPath: "borderColor")
    anim.fromValue = NSColor.labelColor.withAlphaComponent(0.5).cgColor
    anim.toValue = NSColor.separatorColor.cgColor
    anim.duration = 0.6
    layer.add(anim, forKey: "borderGlow")
  }

  func reveal() {
    guard !config.headless else { return }
    flashBorder()
    // Explicit show should stay visible while the user looks for the panel.
    // A later parent activation returns the panel to .sticky and resumes
    // normal focus tracking.
    userIntent = .pinned
    updateAppearance(forceFullOpacity: true)
    let screenName = screen?.localizedName ?? "none"
    log.info("reveal: frame=\(Int(frame.origin.x)),\(Int(frame.origin.y)) size=\(Int(frame.width))x\(Int(frame.height)) screen=\(screenName)")
  }

  func userClose() {
    userIntent = .dismissed
    updateAppearance()
  }

  func userToggle(pinned: Bool) {
    if currentAppearance != .hidden {
      userIntent = .dismissed
    } else {
      userIntent = pinned ? .pinned : .sticky
      grabFocusOnNextShow = true
    }
    updateAppearance(forceFullOpacity: true)
  }

  func setParentActive(_ active: Bool) {
    // `.pinned` returns to `.sticky` all the time
    if userIntent == .pinned {
      userIntent = .sticky
    }
    updateAppearance()
  }

  /// Queue a JSON-RPC payload for delivery to the iframe. Payloads are
  /// held until the iframe signals initialized, then flushed in order.
  func sendPayload(_ payload: JsonRpc.Payload) {
    pendingPayloads.append(payload)
    flushPendingPayloads()
  }

  private func flushPendingPayloads() {
    guard isFrameReady, !pendingPayloads.isEmpty else { return }
    log.info("Sending \(pendingPayloads.count) payload(s)")
    for payload in pendingPayloads {
      WebViewBridge.sendToApp(webView, payload: payload.raw)
    }
    pendingPayloads.removeAll()
  }

  /// Capture a PNG snapshot of the current WebView content.
  /// The completion handler is called on the main thread.
  func takeSnapshot(completionHandler: @escaping (Result<String, Error>) -> Void) {
    let config = WKSnapshotConfiguration()
    webView.takeSnapshot(with: config) { image, error in
      if let error = error {
        completionHandler(.failure(error))
        return
      }
      guard let image = image,
            let tiffData = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiffData),
            let pngData = bitmap.representation(using: .png, properties: [:])
      else {
        completionHandler(.failure(SnapshotError.conversionFailed))
        return
      }
      completionHandler(.success(pngData.base64EncodedString()))
    }
  }

  private enum SnapshotError: Error {
    case conversionFailed
    var localizedDescription: String { "Failed to convert WebView snapshot to PNG" }
  }

  @objc private func handleWillStartLiveResize() {
    liveResizeStartHeight = frame.size.height
  }

  @objc private func handleWindowDidResize() {
    guard !isProgrammaticResize, inLiveResize, !hasFixedHeight, displayMode == .inline,
      let start = liveResizeStartHeight,
      abs(frame.size.height - start) >= Constants.userResizeThreshold
    else {
      return
    }
    hasFixedHeight = true
    log.info("User dragged the panel past the intent threshold; the height is now fixed")
    notifyFixedHeightChanged()
  }

  @objc private func handleDidEndLiveResize() {
    liveResizeStartHeight = nil
  }

  func applyContentHeight(_ contentHeight: CGFloat) {
    guard contentHeight > 0, !hasFixedHeight, displayMode == .inline, !inLiveResize,
      let visible = (screen ?? NSScreen.main)?.visibleFrame
    else {
      return
    }
    let target = min(max(contentHeight, Constants.minContentHeight), visible.size.height)
    guard abs(target - frame.size.height) >= Constants.contentHeightEpsilon else {
      return
    }
    isProgrammaticResize = true
    setFrame(
      NSRect(
        x: frame.minX,
        y: max(frame.maxY - target, visible.minY),
        width: frame.size.width,
        height: target),
      display: true,
      animate: false)
    isProgrammaticResize = false
    log.info("Resized panel to reported content height: \(target)")
  }

  func setDisplayMode(_ mode: DisplayMode) {
    displayMode = mode
    if hasFixedHeight {
      hasFixedHeight = false
      notifyFixedHeightChanged()
    }
    isProgrammaticResize = true
    defer { isProgrammaticResize = false }
    switch mode {
    case .fullscreen:
      if let screen = NSScreen.main {
        let current = frame
        let screenFrame = screen.visibleFrame
        if current.size.width < screenFrame.size.width * 0.9 {
          inlineFrame = current
        }
        setFrame(screenFrame, display: true, animate: true)
        log.info("Entered fullscreen mode")
      }
    case .inline:
      setFrame(inlineFrame, display: true, animate: true)
      log.info("Restored inline mode")
    }
  }

  @discardableResult
  func openTrustedLink(_ url: URL) -> Bool {
    guard config.isTrustedURL(url) else {
      log.info("Dropping untrusted URL: \(url.absoluteString)")
      return false
    }
    NSWorkspace.shared.open(url)
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

    if url.scheme == config.hostBaseURL.scheme && url.host == config.hostBaseURL.host {
      decisionHandler(.allow)
    } else if !config.isTrustedURL(url) {
      decisionHandler(.cancel)
    } else if navigationAction.targetFrame?.isMainFrame ?? true {
      openTrustedLink(url)
      decisionHandler(.cancel)
    } else {
      decisionHandler(.allow)
    }
  }

  // WKNavigationDelegate callback, invoked automatically by WKWebView on TLS trust challenges.
  // Debug mode only (DDVIZ_DEBUG=1) plus explicit DDVIZ_TEST_INSECURE_TLS, and
  // only for a loopback host: accept a local fixture server's self-signed cert
  // so tests can drive the real iframe bridge headless. Not reachable in prod.
  func webView(
    _ webView: WKWebView,
    didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    let host = challenge.protectionSpace.host
    guard config.debug, ProcessInfo.processInfo.environment["DDVIZ_TEST_INSECURE_TLS"] == "1",
      host == "localhost" || host == "127.0.0.1",
      challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
      let trust = challenge.protectionSpace.serverTrust
    else {
      completionHandler(.performDefaultHandling, nil)
      return
    }
    completionHandler(.useCredential, URLCredential(trust: trust))
  }

  func userContentController(
    _ userContentController: WKUserContentController,
    didReceive message: WKScriptMessage
  ) {
    guard message.frameInfo.isMainFrame else {
      log.info("Dropping message from non-main frame")
      return
    }
    guard let bodyStr = message.body as? String else { return }
    guard let msg = OutboundMessage.parse(bodyStr) else {
      log.info("Dropping invalid bridge message")
      return
    }

    switch msg.kind {
    case .initialized:
      log.info("Iframe initialized")
      isFrameReady = true
      notifyThemeChanged()
      notifyFixedHeightChanged()
      flushPendingPayloads()
      onInitialized?()
      onOutbound?(msg)

    case .close:
      userClose()

    case .shutdown(let reason):
      log.info("Shutdown requested: \(reason)")
      onShutdown?(reason)

    case .requestDisplayMode(let mode):
      guard let dm = DisplayMode(rawValue: mode) else {
        log.info("Dropping unknown display mode: \(mode)")
        return
      }
      setDisplayMode(dm)
      WebViewBridge.notifyDisplayModeChanged(webView, mode: mode)

    case .openLink(let urlString):
      if let url = URL(string: urlString) {
        if openTrustedLink(url) {
          log.info("Opened link: \(urlString)")
        }
      } else {
        log.info("Dropping invalid URL: \(urlString)")
      }

    case .sizeChanged(let w, let h):
      log.info("Size changed: \(w)x\(h)")
      applyContentHeight(CGFloat(h))

    case .toolCall, .unknown, .hostRequestResponse:
      onOutbound?(msg)
    }
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
}

// MARK: - Application

/// Application delegate — wires IPC, VizPanel, and ParentAppTracker.
class AppDelegate: NSObject, NSApplicationDelegate {
  let config: Config
  let log: Log
  let adapter: IPCAdapter
  private var panel: VizPanel?
  private var parentTracker: ParentAppTracker?
  private var statusItem: NSStatusItem?
  private var contextMenu: NSMenu?

  init(config: Config, log: Log, adapter: IPCAdapter) {
    self.config = config
    self.log = log
    self.adapter = adapter
    super.init()
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    let log = self.log.scoped("GUI")

    let tracker = ParentAppTracker(
      parentBundleId: config.parentBundleId, parentPID: config.parentPID,
      log: self.log.scoped("Parent"))
    parentTracker = tracker

    let vizPanel = VizPanel(config: config, log: self.log, parentTracker: tracker)
    panel = vizPanel

    tracker.onActivated = { [weak vizPanel] in
      DispatchQueue.main.async { vizPanel?.setParentActive(true) }
    }
    tracker.onDeactivated = { [weak vizPanel] in
      DispatchQueue.main.async { vizPanel?.setParentActive(false) }
    }

    if config.menubarContext {
      setupMainMenu()
      vizPanel.onInitialized = { [weak self] in
        guard let self, self.statusItem == nil else { return }
        self.setupStatusBar()
      }
    }

    vizPanel.onShutdown = { reason in
      log.info("Shutdown: \(reason)")
      DispatchQueue.main.async { NSApp.terminate(nil) }
    }

    vizPanel.onOutbound = { [weak self] msg in
      self?.handleOutbound(msg)
    }

    tracker.onShouldTerminate = { reason in
      log.info("Terminating: \(reason)")
      DispatchQueue.main.async { NSApp.terminate(nil) }
    }

    adapter.start { [weak self] message in
      DispatchQueue.main.async { self?.handleInbound(message) }
    }

    if let pid = config.parentPID {
      tracker.watchPID(pid)
    }

    log.info("AppDelegate ready")

    if config.debug, ProcessInfo.processInfo.environment["DDVIZ_DEBUG_TRIGGER_DISABLE"] == "1" {
      disable(emitter: "debug")
    }
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    false
  }

  func applicationWillTerminate(_ notification: Notification) {
    adapter.stop()
  }

  private func handleInbound(_ message: InboundMessage) {
    let log = self.log.scoped("GUI")

    switch message {
    case .shutdown:
      log.info("Received shutdown command")
      NSApp.terminate(nil)

    case .show:
      log.info("Received show command")
      panel?.reveal()

    case .hide:
      log.info("Received hide command")
      panel?.userClose()

    case .toggle:
      log.info("Received toggle command")
      panel?.userToggle(pinned: false)

    case .snapshot(let id):
      log.info("Snapshot requested (id: \(id))")
      guard let panel = panel else {
        if let payload = JsonRpc.error(id: id, code: -32000, message: "Panel not available") {
          adapter.send(payload)
        }
        return
      }
      panel.takeSnapshot { [weak self] result in
        guard let self else { return }
        switch result {
        case .success(let base64):
          if let payload = JsonRpc.response(
            id: id,
            result: ["data": base64, "mimeType": "image/png"]
          ) {
            self.adapter.send(payload)
          }
        case .failure(let error):
          if let payload = JsonRpc.error(id: id, code: -32000, message: error.localizedDescription) {
            self.adapter.send(payload)
          }
        }
      }

    case .sessionEnd:
      break  // Lifecycle is driven by parent-PID exit; SessionEnd is advisory.

    case .toolResult(_, let parentPID, let payload):
      if let parentPID { parentTracker?.watchPID(parentPID) }
      panel?.sendPayload(payload)

    case .toolCallResponse(let payload):
      panel?.sendPayload(payload)

    case .opaque(_, let payload):
      panel?.sendPayload(payload)
    }
  }

  private func handleOutbound(_ msg: OutboundMessage) {
    adapter.send(msg.payload)
  }

  /// Installs a minimal main menu so macOS keyboard shortcuts (⌘Q, ⌘W)
  /// and the application menu work while the panel has key focus.
  private func setupMainMenu() {
    let mainMenu = NSMenu()

    let appMenuItem = NSMenuItem()
    let appMenu = NSMenu()
    appMenu.addItem(
      NSMenuItem(
        title: "Quit \(config.appName)",
        action: #selector(NSApplication.terminate(_:)),
        keyEquivalent: "q"))
    appMenuItem.submenu = appMenu
    mainMenu.addItem(appMenuItem)

    let windowMenuItem = NSMenuItem()
    let windowMenu = NSMenu(title: "Window")
    windowMenu.addItem(
      NSMenuItem(
        title: "Close",
        action: #selector(VizPanel.closeWindow(_:)),
        keyEquivalent: "w"))
    windowMenuItem.submenu = windowMenu
    mainMenu.addItem(windowMenuItem)

    NSApp.mainMenu = mainMenu
  }

  /// Creates the system status bar item, loaded after the WebView initialises
  /// so the icon appears only once the app is fully ready.
  private func setupStatusBar() {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    guard let button = statusItem?.button else { return }

    let iconPath = config.assetPath("datadog-icon.png")
    if let image = NSImage(contentsOfFile: iconPath) {
      image.size = NSSize(width: 18, height: 18)
      button.image = image
    } else {
      button.title = "D"
    }
    button.action = #selector(handleStatusItemClick)
    button.target = self
    button.sendAction(on: [.leftMouseUp, .rightMouseUp])

    let menu = NSMenu()
    menu.addItem(
      NSMenuItem(
        title: "Disable \(config.appName)",
        action: #selector(disableMenuItemClicked),
        keyEquivalent: ""))
    menu.addItem(NSMenuItem.separator())
    // Ephemeral, unlike Disable: no marker written, so the next chart respawns
    // the daemon and icon as usual. The only way to clear the menubar icon
    // without opting out of ddviz entirely.
    menu.addItem(
      NSMenuItem(
        title: "Quit \(config.appName)",
        action: #selector(NSApplication.terminate(_:)),
        keyEquivalent: ""))
    contextMenu = menu
  }

  /// Writes the persistent opt-out marker (mirrors `/ddviz disable`'s disable.sh), then terminates.
  func disable(emitter: String) {
    // dataDir already exists: the daemon can't be running without having created it at lock-acquisition.
    let markerPath = URL(fileURLWithPath: config.dataDir).appendingPathComponent("DDVIZ_DISABLED").path
    let wrote = FileManager.default.createFile(atPath: markerPath, contents: nil)
    log.scoped("GUI").info(wrote ? "Wrote disable marker at \(markerPath)" : "FAILED to write disable marker at \(markerPath)")

    // Clicking this notification opens Script Editor (blank): osascript notifications
    // attribute to Script Editor unless the caller is itself a bundled .app.
    let script = Process()
    script.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    script.arguments = [
      "-e",
      "display notification \"Type /ddviz enable in Claude Code to turn it back on.\" with title \"ddviz disabled\"",
    ]
    try? script.run()
    log.scoped("GUI").info("Posted disable notification")

    emitTelemetryEvent(
      event: "disable", status: wrote ? "info" : "error", attributes: ["emitter": emitter], log: log.scoped("GUI"))

    NSApp.terminate(nil)
  }

  @objc private func handleStatusItemClick() {
    guard let event = NSApp.currentEvent else { return }
    let isSecondaryClick = event.type == .rightMouseUp
      // Control-click arrives as .leftMouseUp with .control set, not .rightMouseUp.
      || (event.type == .leftMouseUp && event.modifierFlags.contains(.control))
    if isSecondaryClick {
      showContextMenu()
    } else {
      toggleWindow()
    }
  }

  private func showContextMenu() {
    guard let item = statusItem, let menu = contextMenu else { return }
    item.menu = menu
    item.button?.performClick(nil)
    item.menu = nil
  }

  @objc private func toggleWindow() {
    panel?.userToggle(pinned: true)
  }

  @objc private func disableMenuItemClicked() {
    disable(emitter: "menubar")
  }
}

// MARK: - Entry Point

enum Main {
  /// Boot the application. All configuration is read from the environment
  /// via `Config.resolve()`; the IPC adapter is selected by `DDVIZ_IPC`.
  static func start() {
    let config = Config.resolve()
    let log = Log.create(enabled: config.debug, directory: config.dataDir)
    log.info("=== ddviz \(config.appVersion) starting ===")

    let ipcLog = log.scoped("IPC").fn
    let adapter: IPCAdapter
    switch config.ipcMode {
    case .hooks:
      guard Main.acquireHooksInstanceLock(config: config, log: log) else {
        // Another daemon holds the lock (defer to it) or the lock could not be
        // opened. acquireHooksInstanceLock logs the specific reason.
        log.info("ddviz daemon not started, exiting")
        exit(0)
      }
      switch IPCHooksAdapter.create(path: config.socketPath, log: ipcLog) {
      case .success(let a):
        adapter = a
      case .failed:
        fatalError("[IPC] Failed to create hooks adapter at \(config.socketPath.path)")
      }
    case .stdio:
      adapter = IPCStdioAdapter(log: ipcLog)
    }

    let app = NSApplication.shared
    let delegate = AppDelegate(config: config, log: log, adapter: adapter)
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
  }

  // Never closed, so the advisory flock is held for the process lifetime.
  private static var lockFD: Int32 = -1

  /// Acquire the single-instance lock. Returns true to become the daemon, false
  /// to defer (another holds the lock) or on a lock-open failure. The lock lives
  /// under `config.dataDir` (set by the hooks via DDVIZ_DATA_DIR).
  static func acquireHooksInstanceLock(config: Config, log: Log) -> Bool {
    // Create the data dir first, or open() below fails with ENOENT, which the
    // old code misreported as "already running".
    try? FileManager.default.createDirectory(
      atPath: config.dataDir, withIntermediateDirectories: true)

    let lockPath = config.socketPath.path + ".lock"
    let fd = Darwin.open(lockPath, O_CREAT | O_RDWR, 0o600)
    guard fd >= 0 else {
      // A real open failure, distinct from lock contention.
      log.info("[lock] cannot open \(lockPath): \(String(cString: strerror(errno)))")
      return false
    }
    if flock(fd, LOCK_EX | LOCK_NB) != 0 {
      Darwin.close(fd)
      log.info("[lock] another ddviz daemon already holds \(lockPath), deferring")
      return false
    }
    lockFD = fd
    try? "\(getpid())".write(toFile: config.socketPath.path + ".pid", atomically: true, encoding: .utf8)
    return true
  }
}

Main.start()
