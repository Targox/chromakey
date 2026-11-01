import ScreenCaptureKit

let project = URL(fileURLWithPath: CommandLine.arguments[1])
let templateURL = project.appendingPathComponent("assets/readme/prompt-template.png")
let mediaURL = project.appendingPathComponent("media", isDirectory: true)
let renderApp = NSApplication.shared
renderApp.setActivationPolicy(.prohibited)
renderApp.appearance = NSAppearance(named: .darkAqua)

func imageData(size: NSSize, scale: CGFloat = 2, drawing: () -> Void) -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
        pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.current!.cgContext.scaleBy(x: scale, y: scale)
    drawing()
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}
func axRect(_ element: AXUIElement) -> CGRect? {
    guard let p = attribute(element, kAXPositionAttribute), let s = attribute(element, kAXSizeAttribute) else { return nil }
    var origin = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(p as! AXValue, .cgPoint, &origin), AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
    return CGRect(origin: origin, size: size)
}
func captureTemplate() async throws {
    var candidates: [(pid_t, CGRect, CGRect)] = []
    for helper in NSWorkspace.shared.runningApplications where helper.bundleIdentifier == "com.apple.PasswordManagerBrowserExtensionHelper" {
        let root = AXUIElementCreateApplication(helper.processIdentifier)
        for window in attribute(root, kAXWindowsAttribute) as? [AXUIElement] ?? [] where text(window, kAXTitleAttribute) == "Verification Code" {
            guard let frame = axRect(window) else { continue }
            var codeFrame: CGRect?
            func visit(_ node: AXUIElement, _ depth: Int) {
                guard depth < 16 else { return }
                if text(node, kAXRoleAttribute) == kAXStaticTextRole, parseCode(text(node, kAXValueAttribute)) != nil {
                    codeFrame = axRect(node)
                }
                for child in attribute(node, kAXChildrenAttribute) as? [AXUIElement] ?? [] { visit(child, depth + 1) }
            }
            visit(window, 0)
            if let codeFrame { candidates.append((helper.processIdentifier, frame, codeFrame)) }
        }
    }
    guard candidates.count == 1 else { throw NSError(domain: "Render", code: 1) }
    let (pid, frame, codeFrame) = candidates[0]
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    let windows = content.windows.filter { $0.owningApplication?.processID == pid && $0.title == "Verification Code" }
    guard windows.count == 1, let window = windows.first else { throw NSError(domain: "Render", code: 2) }
    let configuration = SCStreamConfiguration()
    configuration.width = Int(frame.width * 2)
    configuration.height = Int(frame.height * 2)
    configuration.showsCursor = false
    configuration.ignoreShadowsSingleWindow = true
    configuration.captureResolution = .best
    let captured = try await SCScreenshotManager.captureImage(
        contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: configuration)
    let bitmap = NSBitmapImageRep(cgImage: captured)
    let scale = CGFloat(captured.width) / frame.width
    let textFrame = codeFrame.offsetBy(dx: -frame.minX, dy: -frame.minY)
    guard textFrame.minX > 12, textFrame.maxX < frame.width, textFrame.maxY < frame.height else {
        throw NSError(domain: "Render", code: 3)
    }
    guard !bitmap.isPlanar, bitmap.bitsPerSample == 8, let pixels = bitmap.bitmapData else {
        throw NSError(domain: "Render", code: 5)
    }
    let pixelBytes = bitmap.bitsPerPixel / 8
    let sampleOffset = Int(textFrame.midY * scale) * bitmap.bytesPerRow + Int((textFrame.minX - 10) * scale) * pixelBytes
    let background = Array(UnsafeBufferPointer(start: pixels + sampleOffset, count: pixelBytes))
    let clear = textFrame.insetBy(dx: -24, dy: -3)
    for y in Int(floor(clear.minY * scale))..<Int(ceil(clear.maxY * scale)) {
        for x in Int(floor(clear.minX * scale))..<Int(ceil(clear.maxX * scale)) {
            let offset = y * bitmap.bytesPerRow + x * pixelBytes
            for channel in 0..<pixelBytes { pixels[offset + channel] = background[channel] }
        }
    }
    try bitmap.representation(using: .png, properties: [:])!.write(to: templateURL)
}
func captureSettings() async throws {
    let initial = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    let alreadyOpen = initial.windows.contains {
        $0.owningApplication?.bundleIdentifier == "local.zimeng.verification-code-shortcut" && $0.title == "Chromakey"
    }
    let appURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Chromakey.app")
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    let application = try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
    var selected: SCWindow?
    for _ in 0..<40 {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        selected = content.windows.first { $0.owningApplication?.processID == application.processIdentifier && $0.title == "Chromakey" }
        if selected != nil { break }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    guard let window = selected else { throw NSError(domain: "Render", code: 6) }
    let capture = SCStreamConfiguration()
    capture.width = Int(window.frame.width * 2)
    capture.height = Int(window.frame.height * 2)
    capture.showsCursor = false
    capture.ignoreShadowsSingleWindow = true
    capture.captureResolution = .best
    let image = try await SCScreenshotManager.captureImage(
        contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: capture)
    try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
        .write(to: project.appendingPathComponent("assets/readme/settings-template.png"))
    if !alreadyOpen {
        let root = AXUIElementCreateApplication(application.processIdentifier)
        for window in attribute(root, kAXWindowsAttribute) as? [AXUIElement] ?? [] where text(window, kAXTitleAttribute) == "Chromakey" {
            if let close = element(window, kAXCloseButtonAttribute) { AXUIElementPerformAction(close, kAXPressAction as CFString) }
        }
    }
}
func renderImages() throws {
    let hud = HUD()
    hud.label.stringValue = "Click or ⌘↩ to fill"
    let view = hud.contentView!
    (view.subviews.first { $0 is NSImageView } as? NSImageView)?.image = NSImage(contentsOf: project.appendingPathComponent("assets/AppIcon.icns"))
    view.layoutSubtreeIfNeeded()
    view.displayIfNeeded()
    let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
    view.cacheDisplay(in: view.bounds, to: representation)
    let overlay = NSImage(size: view.bounds.size)
    overlay.addRepresentation(representation)
    let overlayData = imageData(size: view.bounds.size) { overlay.draw(in: view.bounds) }
    try overlayData.write(to: mediaURL.appendingPathComponent("overlay@2x.png"))
    guard let prompt = NSImage(contentsOf: templateURL) else { throw NSError(domain: "Render", code: 4) }
    let size = NSSize(width: 480, height: 228)
    let sample = NSAttributedString(string: "123\u{00a0}456", attributes: [
        .font: NSFont.systemFont(ofSize: 32), .kern: 4,
        .foregroundColor: NSColor.labelColor
    ])
    let promptData = imageData(size: size) {
        prompt.draw(in: CGRect(origin: .zero, size: size))
        sample.draw(at: CGPoint(x: 280 - sample.size().width / 2, y: 66))
    }
    try promptData.write(to: mediaURL.appendingPathComponent("prompt@2x.png"))
    let renderedPrompt = NSImage(data: promptData)!
    let canvas = NSSize(width: 528, height: 314)
    let composite = imageData(size: canvas) {
        NSColor(srgbRed: 0.22, green: 0.22, blue: 0.23, alpha: 1).setFill()
        CGRect(origin: .zero, size: canvas).fill()
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.4)
        shadow.shadowBlurRadius = 18
        shadow.shadowOffset = NSSize(width: 0, height: -8)
        shadow.set()
        renderedPrompt.draw(in: CGRect(x: 24, y: 62, width: 480, height: 228))
        NSGraphicsContext.restoreGraphicsState()
        overlay.draw(in: CGRect(x: (canvas.width - view.bounds.width) / 2, y: 24, width: view.bounds.width, height: view.bounds.height))
    }
    try composite.write(to: mediaURL.appendingPathComponent("preview@2x.png"))
    guard let settings = NSImage(contentsOf: project.appendingPathComponent("assets/readme/settings-template.png")) else {
        throw NSError(domain: "Render", code: 7)
    }
    let settingsBitmap = settings.representations.compactMap { $0 as? NSBitmapImageRep }.first!
    let settingsSize = NSSize(width: CGFloat(settingsBitmap.pixelsWide) / 2, height: CGFloat(settingsBitmap.pixelsHigh) / 2)
    let settingsCanvas = NSSize(width: settingsSize.width + 48, height: settingsSize.height + 48)
    let settingsData = imageData(size: settingsCanvas) {
        NSColor(srgbRed: 0.22, green: 0.22, blue: 0.23, alpha: 1).setFill()
        CGRect(origin: .zero, size: settingsCanvas).fill()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.4)
        shadow.shadowBlurRadius = 18
        shadow.shadowOffset = NSSize(width: 0, height: -8)
        shadow.set()
        settings.draw(in: CGRect(x: 24, y: 24, width: settingsSize.width, height: settingsSize.height))
    }
    try settingsData.write(to: mediaURL.appendingPathComponent("settings@2x.png"))

}
try FileManager.default.createDirectory(at: mediaURL, withIntermediateDirectories: true)
let finished = DispatchSemaphore(value: 0)
var renderError: Error?
Task { @MainActor in
    do {
        if CommandLine.arguments.contains("--capture-template") { try await captureTemplate() }
        if CommandLine.arguments.contains("--capture-settings") { try await captureSettings() }
        try renderImages()
    } catch { renderError = error }
    finished.signal()
}
while finished.wait(timeout: .now()) != .success { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01)) }
if let renderError {
    FileHandle.standardError.write(Data("Render failed: \(renderError)\n".utf8))
    exit(1)
}
