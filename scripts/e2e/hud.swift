// Click-through pill shown while an agent drives the pointer. Exits after 180 s at most.
import AppKit
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let screen = NSScreen.screens[0].visibleFrame
let size = NSSize(width: 250, height: 34)
let w = NSWindow(contentRect: NSRect(x: screen.minX + 16, y: screen.minY + 16, width: size.width, height: size.height),
                 styleMask: .borderless, backing: .buffered, defer: false)
w.level = .screenSaver; w.ignoresMouseEvents = true; w.isOpaque = false; w.backgroundColor = .clear
w.collectionBehavior = [.canJoinAllSpaces, .stationary]
let label = NSTextField(labelWithString: "●  Claude가 화면을 제어하는 중")
label.font = .systemFont(ofSize: 13, weight: .semibold); label.textColor = .white; label.alignment = .center
label.frame = NSRect(x: 0, y: 8, width: size.width, height: 18)
let bg = NSView(frame: NSRect(origin: .zero, size: size)); bg.wantsLayer = true
bg.layer?.backgroundColor = NSColor(red: 0.85, green: 0.30, blue: 0.25, alpha: 0.92).cgColor; bg.layer?.cornerRadius = 17
bg.addSubview(label); w.contentView = bg; w.orderFrontRegardless()
DispatchQueue.main.asyncAfter(deadline: .now() + 180) { exit(0) }
app.run()
