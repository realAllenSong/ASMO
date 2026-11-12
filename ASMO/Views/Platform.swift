import SwiftUI
#if os(macOS)
import AppKit
typealias PlatformImage = NSImage
typealias PlatformFont = NSFont
typealias PlatformColor = NSColor
extension Image { init(platformImage: NSImage) { self.init(nsImage: platformImage) } }
#else
import UIKit
typealias PlatformImage = UIImage
typealias PlatformFont = UIFont
typealias PlatformColor = UIColor
extension Image { init(platformImage: UIImage) { self.init(uiImage: platformImage) } }
#endif
