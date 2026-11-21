import AppKit
import ApplicationServices

/// What is focused right now, read through the Accessibility API.
struct FocusSnapshot {
    var appName: String?
    var bundleID: String?
    var processID: pid_t = 0
    var element: AXUIElement?
    var role: String?
    var isSecureField = false
    /// Full text of the focused field. Nil when unavailable or very large.
    var value: String?
    /// Selection as UTF-16 offsets into `value`.
    var selection: NSRange?
    /// Characters right before and after the insertion point, when they could be read.
    var precedingCharacter: Character?
    var followingCharacter: Character?
    /// True when the text around the cursor was readable, so spacing decisions can be trusted.
    var hasTextContext = false
}

/// Thin wrappers over AXUIElement. Every call has a short timeout so an unresponsive app cannot stall dictation.
enum Accessibility {
    static let queue = DispatchQueue(label: "app.nabra.accessibility", qos: .userInitiated)
    private static let largestReadableValue = 200_000
    private static var manualAccessibilityRequested = Set<pid_t>()
    private static let lock = NSLock()

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that sends the user to Privacy & Security > Accessibility.
    static func requestTrust() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// The frontmost application, without touching the Accessibility API.
    static func frontmostApplication() -> (name: String?, bundleID: String?, pid: pid_t) {
        let app = NSWorkspace.shared.frontmostApplication
        return (app?.localizedName, app?.bundleIdentifier, app?.processIdentifier ?? 0)
    }

    /// Reads the focused element. `readText` also fetches the text around the cursor.
    static func snapshot(readText: Bool) -> FocusSnapshot {
        var snapshot = FocusSnapshot()
        let front = frontmostApplication()
        snapshot.appName = front.name
        snapshot.bundleID = front.bundleID
        snapshot.processID = front.pid
        guard isTrusted, front.pid != 0 else { return snapshot }

        let application = AXUIElementCreateApplication(front.pid)
        AXUIElementSetMessagingTimeout(application, 0.25)
        guard let element = focusedElement(of: application, pid: front.pid) else { return snapshot }
        AXUIElementSetMessagingTimeout(element, 0.25)
        snapshot.element = element
        snapshot.role = string(element, kAXRoleAttribute)
        let subrole = string(element, kAXSubroleAttribute)
        snapshot.isSecureField = subrole == (kAXSecureTextFieldSubrole as String)
        guard readText, !snapshot.isSecureField else { return snapshot }

        if let range = selectedRange(element) {
            snapshot.selection = range
            if range.location > 0, let before = text(element, NSRange(location: range.location - 1, length: 1)) {
                snapshot.precedingCharacter = before.last
                snapshot.hasTextContext = true
            } else if range.location == 0 {
                snapshot.hasTextContext = true
            }
            if let after = text(element, NSRange(location: range.location + range.length, length: 1)) {
                snapshot.followingCharacter = after.first
            }
        }
        if let count = number(element, kAXNumberOfCharactersAttribute), count > largestReadableValue {
            return snapshot
        }
        if let value = string(element, kAXValueAttribute), value.utf16.count <= largestReadableValue {
            snapshot.value = value
            if let range = snapshot.selection, !snapshot.hasTextContext || snapshot.precedingCharacter == nil {
                let utf16 = value as NSString
                if range.location > 0, range.location <= utf16.length {
                    snapshot.precedingCharacter = utf16.substring(with: NSRange(location: range.location - 1, length: 1)).last
                }
                if range.location <= utf16.length { snapshot.hasTextContext = true }
                let end = range.location + range.length
                if snapshot.followingCharacter == nil, end < utf16.length {
                    snapshot.followingCharacter = utf16.substring(with: NSRange(location: end, length: 1)).first
                }
            }
        }
        return snapshot
    }

    /// Current text and selection of an element captured earlier.
    static func currentText(of element: AXUIElement) -> (value: String, selection: NSRange?)? {
        if let count = number(element, kAXNumberOfCharactersAttribute), count > largestReadableValue { return nil }
        guard let value = string(element, kAXValueAttribute), value.utf16.count <= largestReadableValue else { return nil }
        return (value, selectedRange(element))
    }

    /// The element that has the keyboard focus in the app with `pid`, if that app is in front.
    static func focusedElement(pid: pid_t) -> AXUIElement? {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return nil }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.2)
        guard let element = focusedElement(of: application, pid: pid) else { return nil }
        AXUIElementSetMessagingTimeout(element, 0.25)
        return element
    }

    /// Whether `element` is still the focused element of its application.
    static func isStillFocused(_ element: AXUIElement, pid: pid_t) -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return false }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.2)
        guard let focused = focusedElement(of: application, pid: pid) else { return false }
        return CFEqual(focused, element)
    }

    // MARK: - Attribute helpers

    private static func focusedElement(of application: AXUIElement, pid: pid_t) -> AXUIElement? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &value)
        if status == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
            return (value as! AXUIElement)
        }
        // Electron and Chromium apps only build their accessibility tree when asked to.
        lock.lock()
        let firstAttempt = manualAccessibilityRequested.insert(pid).inserted
        lock.unlock()
        if firstAttempt {
            AXUIElementSetAttributeValue(application, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
        return nil
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func number(_ element: AXUIElement, _ attribute: String) -> Int? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return (value as? NSNumber)?.intValue
    }

    private static func selectedRange(_ element: AXUIElement) -> NSRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range), range.location >= 0, range.length >= 0 else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    private static func text(_ element: AXUIElement, _ range: NSRange) -> String? {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let parameter = AXValueCreate(.cfRange, &cfRange) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString,
                                                         parameter, &value) == .success
        else { return nil }
        let string = value as? String
        return string?.isEmpty == false ? string : nil
    }
}
