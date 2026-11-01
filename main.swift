import Cocoa
import ApplicationServices
import Carbon
import Darwin

func lockInstance(at path: String) -> Int32 {
    let descriptor = open(path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else { return -1 }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { close(descriptor); return -1 }
    return descriptor
}

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    AXUIElementCopyAttributeValue(element, name as CFString, &value)
    return value
}
func text(_ element: AXUIElement, _ name: String) -> String {
    attribute(element, name) as? String ?? ""
}
func parseCode(_ value: String) -> String? {
    let code = value.filter { !$0.isWhitespace }
    guard code.utf8.count == 6, code.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
    return code
}
struct Discovery {
    let code: String
    let window: AXUIElement
    func matches(_ other: Discovery) -> Bool {
        code == other.code && CFEqual(window, other.window)
    }
}
func discover(in apps: [NSRunningApplication]) -> Discovery? {
    guard AXIsProcessTrusted() else { return nil }
    var matches: [Discovery] = []
    for app in apps {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.3)
        for window in attribute(root, kAXWindowsAttribute) as? [AXUIElement] ?? []
            where text(window, kAXTitleAttribute) == "Verification Code" {
            var codes = Set<String>()
            var isHelium = false
            var visited = 0
            func read(_ node: AXUIElement, _ depth: Int) {
                guard depth < 16, visited < 300 else { return }
                visited += 1
                for key in [kAXValueAttribute, kAXTitleAttribute] {
                    let value = text(node, key)
                    if value.contains("Enable Password AutoFill for “Helium”") { isHelium = true }
                    if let code = parseCode(value) { codes.insert(code) }
                }
                for child in attribute(node, kAXChildrenAttribute) as? [AXUIElement] ?? [] { read(child, depth + 1) }
            }
            read(window, 0)
            guard isHelium else { continue }
            if codes.count == 1, let code = codes.first { matches.append(Discovery(code: code, window: window)) }
        }
    }
    return matches.count == 1 ? matches[0] : nil
}

let extensionID = "pejdijmoenmkgeppbflobdenhhabjlaj"
func validPromptURL(_ value: String) -> Bool {
    guard let url = URLComponents(string: value) else { return false }
    return url.scheme == "chrome-extension" && url.host == extensionID &&
        url.user == nil && url.password == nil && url.port == nil &&
        url.percentEncodedPath == "/page_popup.html"
}
func validPrefix(_ values: [String], code: String, index: Int) -> Bool {
    let digits = code.map(String.init)
    guard values.count == 6, digits.count == 6, (0..<6).contains(index) else { return false }
    return values.indices.allSatisfy { $0 < index ? values[$0] == digits[$0] : values[$0].isEmpty }
}
struct Destination {
    let pid: pid_t
    let area: AXUIElement
    let fields: [AXUIElement]
    let values: [String]
    let index: Int
    func matches(_ other: Destination) -> Bool {
        pid == other.pid && CFEqual(area, other.area) && fields.count == other.fields.count &&
            zip(fields, other.fields).allSatisfy { CFEqual($0, $1) }
    }
}
func element(_ root: AXUIElement, _ key: String) -> AXUIElement? {
    guard let value = attribute(root, key), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return (value as! AXUIElement)
}
func destination() -> Destination? {
    guard let app = NSWorkspace.shared.frontmostApplication,
          app.bundleIdentifier == "net.imput.helium",
          app.bundleURL?.resolvingSymlinksInPath().path == "/Applications/Helium.app",
          let focused = element(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute),
          text(focused, kAXRoleAttribute) == kAXTextFieldRole else { return nil }
    var pid: pid_t = 0
    guard AXUIElementGetPid(focused, &pid) == .success, pid == app.processIdentifier else { return nil }
    var ancestor: AXUIElement? = focused
    for _ in 0..<24 {
        guard let node = ancestor else { return nil }
        if text(node, kAXRoleAttribute) == "AXWebArea" {
            let rawURL = attribute(node, kAXURLAttribute)
            let url = (rawURL as? URL)?.absoluteString ?? (rawURL as? String ?? "")
            guard validPromptURL(url), text(node, kAXTitleAttribute) == "iCloud Passwords" else { return nil }
            var fields: [AXUIElement] = []
            var visited = 0
            var complete = true
            func walk(_ child: AXUIElement, _ depth: Int) {
                guard depth < 20, visited < 256 else { complete = false; return }
                visited += 1
                let role = text(child, kAXRoleAttribute)
                if role == "AXWebArea" && !CFEqual(child, node) { complete = false; return }
                if role == kAXTextFieldRole { fields.append(child) }
                for item in attribute(child, kAXChildrenAttribute) as? [AXUIElement] ?? [] { walk(item, depth + 1) }
            }
            walk(node, 0)
            guard complete, fields.count == 6,
                  let index = fields.firstIndex(where: { CFEqual($0, focused) }) else { return nil }
            for (i, field) in fields.enumerated() {
                guard (attribute(field, kAXEnabledAttribute) as? Bool) == true else { return nil }
                let identifier = text(field, "AXDOMIdentifier")
                if !identifier.isEmpty && identifier != "PIN\(i)" { return nil }
            }
            return Destination(pid: pid, area: node, fields: fields,
                               values: fields.map { text($0, kAXValueAttribute) }, index: index)
        }
        ancestor = element(node, kAXParentAttribute)
    }
    return nil
}

final class OverlayClickSurface: NSView {
    var onClick: (() -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }
    override func mouseDown(with event: NSEvent) { }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

final class HUD: NSPanel {
    let label = NSTextField(labelWithString: "")
    let clickSurface = OverlayClickSurface()
    var onFill: (() -> Void)?
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 260, height: 32),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        contentView!.wantsLayer = true
        contentView!.layer?.backgroundColor = NSColor(white: 0.16, alpha: 1).cgColor
        contentView!.layer?.cornerRadius = 10
        contentView!.layer?.cornerCurve = .continuous
        contentView!.layer?.masksToBounds = true
        hasShadow = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        ignoresMouseEvents = false
        becomesKeyOnlyIfNeeded = true
        label.frame = contentView!.bounds.insetBy(dx: 12, dy: 8)
        label.autoresizingMask = [.width, .height]
        label.font = .systemFont(ofSize: 12)
        label.textColor = NSColor(white: 0.92, alpha: 1)
        label.alignment = .center
        label.maximumNumberOfLines = 1
        label.drawsBackground = false
        contentView!.addSubview(label)
        clickSurface.frame = contentView!.bounds
        clickSurface.autoresizingMask = [.width, .height]
        clickSurface.onClick = { [weak self] in self?.onFill?() }
        contentView!.addSubview(clickSurface)
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    func position(below window: AXUIElement) -> Bool {
        guard let position = attribute(window, kAXPositionAttribute),
              let size = attribute(window, kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(),
              CFGetTypeID(size) == AXValueGetTypeID(),
              let primaryScreen = NSScreen.screens.first else { return false }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return false }
        let origin = NSPoint(x: point.x + (dimensions.width - frame.width) / 2,
                             y: primaryScreen.frame.maxY - point.y - dimensions.height - frame.height - 6)
        if frame.origin != origin { setFrameOrigin(origin) }
        return true
    }
    func show(below window: AXUIElement) {
        label.stringValue = "Click or ⌘↩ to fill · Esc to dismiss"
        guard position(below: window) else { orderOut(nil); return }
        orderFrontRegardless()
    }

}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var status: NSStatusItem!
    var hud: HUD?
    var helpers: [NSRunningApplication] = []
    var observers: [pid_t: AXObserver] = [:]
    var fallback = false
    var scheduled: DispatchWorkItem?
    var timer: Timer?
    var pending: Discovery?
    var handled: Discovery?
    var approveKey: EventHotKeyRef?
    var dismissKey: EventHotKeyRef?
    var manualKey: EventHotKeyRef?
    var handler: EventHandlerRef?
    var busy = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.image = NSImage(systemSymbolName: "key", accessibilityDescription: "Verification Code Shortcut")
        let menu = NSMenu()
        for (title, action) in [("Find code    ⌃⌥⌘V", #selector(scan)),
                                ("Accessibility Settings…", #selector(settings)), ("Quit", #selector(quit))] {
            menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
        }
        status.menu = menu
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let context, let event else { return noErr }
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            let app = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
            if id.id == 1 { app.approve() }
            if id.id == 2 { app.dismiss() }
            if id.id == 3 { app.scan() }
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
        _ = bind(3, UInt32(kVK_ANSI_V), UInt32(controlKey | optionKey | cmdKey), &manualKey)
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(appChanged), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(appChanged), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        connect()

    }
    @objc func appChanged(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier == "com.apple.PasswordManagerBrowserExtensionHelper" else { return }
        connect()
    }
    func connect() {
        for observer in observers.values {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observers.removeAll()
        helpers = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == "com.apple.PasswordManagerBrowserExtensionHelper" && !$0.isTerminated
        }
        fallback = !AXIsProcessTrusted()
        if !fallback {
            for app in helpers {
                var observer: AXObserver?
                let result = AXObserverCreate(app.processIdentifier, { _, _, notification, context in
                    guard let context else { return }
                    let app = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
                    app.queueRefresh()
                    if notification as String == kAXWindowCreatedNotification {
                        for delay in [0.5, 2.0] {
                            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak app] in app?.poll() }
                        }
                    }
                }, &observer)
                guard result == .success, let observer else { fallback = true; continue }
                let root = AXUIElementCreateApplication(app.processIdentifier)
                let context = Unmanaged.passUnretained(self).toOpaque()
                let added = AXObserverAddNotification(observer, root, kAXWindowCreatedNotification as CFString, context)
                guard added == .success else { fallback = true; continue }
                observers[app.processIdentifier] = observer
                CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            }
        }
        poll()
    }
    func queueRefresh() {
        guard scheduled == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.scheduled = nil
            self?.poll()
        }
        scheduled = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04, execute: work)
    }
    func watch(_ window: AXUIElement) {
        var pid: pid_t = 0
        AXUIElementGetPid(window, &pid)
        guard let observer = observers[pid] else { return }
        for notification in [kAXUIElementDestroyedNotification, kAXMovedNotification, kAXResizedNotification] {
            AXObserverAddNotification(observer, window, notification as CFString, Unmanaged.passUnretained(self).toOpaque())
        }
    }
    func updateTimer() {
        let interval: TimeInterval? = (pending != nil || handled != nil) ? 0.8 : (fallback ? 5 : nil)
        if let interval, timer?.timeInterval == interval { return }
        timer?.invalidate()
        timer = nil
        if let interval {
            timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                guard let self else { return }
                if self.fallback { self.connect() } else { self.poll() }
            }
            timer?.tolerance = interval * 0.2
        }
    }
    func bind(_ id: UInt32, _ key: UInt32, _ modifiers: UInt32, _ ref: inout EventHotKeyRef?) -> Bool {
        RegisterEventHotKey(key, modifiers, EventHotKeyID(signature: 0x56435343, id: id),
                            GetApplicationEventTarget(), 0, &ref) == noErr
    }
    func clear() {
        pending = nil
        if let approveKey { UnregisterEventHotKey(approveKey) }; approveKey = nil
        if let dismissKey { UnregisterEventHotKey(dismissKey) }; dismissKey = nil
        hud?.orderOut(nil)
    }
    func poll() {
        autoreleasepool { refresh() }
    }
    func refresh() {
        guard !busy else { return }
        defer { updateTimer() }
        guard let found = discover(in: helpers) else { clear(); handled = nil; return }
        if handled?.matches(found) == true { return }
        if pending?.matches(found) == true {
            if hud?.position(below: found.window) != true { clear() }
            return
        }
        clear()
        pending = found
        _ = bind(1, UInt32(kVK_Return), UInt32(cmdKey), &approveKey)
        _ = bind(2, UInt32(kVK_Escape), 0, &dismissKey)
        watch(found.window)
        if hud == nil {
            hud = HUD()
            hud?.onFill = { [weak self] in self?.approve() }
        }
        hud?.show(below: found.window)
    }
    @objc func scan() { handled = nil; clear(); connect() }
    func dismiss() { handled = pending; clear(); updateTimer() }
    func approve() {
        guard !busy, let found = pending, let target = destination(),
              validPrefix(target.values, code: found.code, index: target.index) else { return }
        busy = true
        clear()
        waitForRelease(found, target, 0)
    }
    func waitForRelease(_ found: Discovery, _ target: Destination, _ attempts: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            let flags = CGEventSource.flagsState(.combinedSessionState)
            if !flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty {
                if attempts < 40 { self.waitForRelease(found, target, attempts + 1) }
                else { self.finish() }
                return
            }
            self.type(found, target: target, index: target.index)
        }
    }
    func finish() { busy = false; poll() }
    func type(_ found: Discovery, target: Destination, index: Int) {
        guard let current = discover(in: helpers), current.matches(found),
              let focused = destination(), focused.matches(target), focused.index == index,
              validPrefix(focused.values, code: found.code, index: index) else { finish(); return }
        var digit = Array(found.code.utf16)[index]
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else { finish(); return }
        for event in [down, up] {
            event.flags = []
            event.keyboardSetUnicodeString(stringLength: 1, unicodeString: &digit)
            event.postToPid(target.pid)
        }
        if index < 5 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.type(found, target: target, index: index + 1)
            }
        } else {
            handled = found
            finish()
        }
    }
    @objc func settings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @objc func quit() { NSApp.terminate(nil) }
}

let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Verification Code Shortcut")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
    guard lockInstance(at: directory.appendingPathComponent("instance.lock").path) >= 0 else { exit(0) }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
