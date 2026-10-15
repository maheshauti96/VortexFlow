#!/usr/bin/env swift
// Read-only WindowServer watcher. Run `swift Scripts/observe-overlay.swift 60`, then
// trigger the switcher in working and failing Spaces. No input taps or permissions
// are installed. Output includes geometry and app identifiers, never window titles.
import AppKit
import CoreGraphics

guard let duration = Double(CommandLine.arguments.dropFirst().first ?? "60"), duration >= 0 else {
    fputs("Usage: swift Scripts/observe-overlay.swift [seconds]\n", stderr)
    exit(2)
}

let deadline = Date().addingTimeInterval(duration)
let formatter = ISO8601DateFormatter()
formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
var previous = ""

repeat {
    let applications = NSWorkspace.shared.runningApplications
    let switcherPIDs = Set(applications.filter {
        $0.bundleIdentifier == "io.vortexflow.Vortexflow"
    }.map(\.processIdentifier))
    let windows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]] ?? []
    let frontmost = NSWorkspace.shared.frontmostApplication
    let frontmostWindows: [[String: Any]] = windows.compactMap { window in
        guard let pid = window[kCGWindowOwnerPID as String] as? Int32,
              pid == frontmost?.processIdentifier,
              window[kCGWindowIsOnscreen as String] as? Bool == true else { return nil }
        return [
            "window": window[kCGWindowNumber as String] ?? 0,
            "layer": window[kCGWindowLayer as String] ?? 0,
            "bounds": window[kCGWindowBounds as String] ?? [:],
        ]
    }
    let overlays: [[String: Any]] = windows.compactMap { window in
        guard let pid = window[kCGWindowOwnerPID as String] as? Int32,
              switcherPIDs.contains(pid),
              window[kCGWindowLayer as String] as? Int == NSWindow.Level.popUpMenu.rawValue
        else { return nil }
        return [
            "pid": pid,
            "window": window[kCGWindowNumber as String] ?? 0,
            "layer": window[kCGWindowLayer as String] ?? 0,
            "onScreen": window[kCGWindowIsOnscreen as String] as? Bool ?? false,
            "alpha": window[kCGWindowAlpha as String] ?? 0,
            "bounds": window[kCGWindowBounds as String] ?? [:],
        ]
    }
    var snapshot: [String: Any] = [
        "frontmost": frontmost?.bundleIdentifier ?? "none",
        "frontmostWindows": frontmostWindows,
        "screens": NSScreen.screens.map {
            ["name": $0.localizedName, "frame": NSStringFromRect($0.frame)]
        },
        "overlays": overlays,
    ]
    let signatureData = try JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys])
    let signature = String(decoding: signatureData, as: UTF8.self)
    if signature != previous {
        previous = signature
        snapshot["time"] = formatter.string(from: Date())
        snapshot["pointer"] = NSStringFromPoint(NSEvent.mouseLocation)
        let data = try JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
        fflush(stdout)
    }
    if Date() >= deadline { break }
    RunLoop.current.run(until: min(deadline, Date().addingTimeInterval(0.1)))
} while Date() < deadline
