import AppKit
import Foundation

guard CommandLine.arguments.count == 3,
      let icon = NSImage(contentsOfFile: CommandLine.arguments[1]),
      NSWorkspace.shared.setIcon(icon, forFile: CommandLine.arguments[2], options: []) else {
    fputs("Could not set the disk image file icon.\n", stderr)
    exit(1)
}
