import AppKit

/// Character defaults follow the keyboard layout; recorded shortcuts identify the pressed key.
/// `usesKeyCode` is optional so existing keyBindings preferences remain readable.
struct AppKeyBinding: Codable, Equatable {
    var keyCode: UInt16
    var modifiers: UInt
    var characters: String
    var usesKeyCode: Bool?
    var baseCharacters: String?

    static let modifierMask: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
    static let unassigned = AppKeyBinding(keyCode: 0, modifiers: 0, characters: "", usesKeyCode: false)

    init(keyCode: UInt16, modifiers: UInt, characters: String, usesKeyCode: Bool? = true) {
        self.keyCode = keyCode
        self.modifiers = modifiers & Self.modifierMask.rawValue
        self.characters = characters
        self.usesKeyCode = usesKeyCode
    }

    init?(event: NSEvent) {
        guard event.type == .keyDown, let characters = event.charactersIgnoringModifiers, !characters.isEmpty else { return nil }
        self.init(keyCode: event.keyCode, modifiers: event.modifierFlags.rawValue, characters: characters)
        baseCharacters = event.characters(byApplyingModifiers: [])
    }

    static func character(_ characters: String, modifiers: NSEvent.ModifierFlags = [.command]) -> AppKeyBinding {
        AppKeyBinding(keyCode: 0, modifiers: modifiers.rawValue, characters: characters, usesKeyCode: false)
    }

    static func physical(_ code: UInt16, characters: String, modifiers: NSEvent.ModifierFlags = []) -> AppKeyBinding {
        AppKeyBinding(keyCode: code, modifiers: modifiers.rawValue, characters: characters)
    }

    static func function(_ number: Int) -> AppKeyBinding {
        let codes: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111,
                               105, 107, 113, 106, 64, 79, 80, 90]
        precondition((1...20).contains(number))
        return physical(codes[number - 1], characters: String(UnicodeScalar(NSF1FunctionKey + number - 1)!))
    }

    private var physical: Bool { usesKeyCode ?? (keyCode != 0) }
    private var normalizedModifiers: UInt { modifiers & Self.modifierMask.rawValue }
    private var normalizedCharacters: String {
        characters == "\u{3}" ? "\r" : characters.lowercased()
    }
    var isAssigned: Bool { !characters.isEmpty }
    var isFunctionKey: Bool {
        guard let scalar = characters.unicodeScalars.first else { return false }
        return (NSF1FunctionKey...NSF35FunctionKey).contains(Int(scalar.value))
    }
    /// Plain keys belong to a list/panel context and must never steal text entry.
    var isTextInput: Bool {
        NSEvent.ModifierFlags(rawValue: normalizedModifiers).intersection([.command, .control, .option]).isEmpty && !isFunctionKey
    }

    private var isPunctuation: Bool {
        !characters.isEmpty && characters.unicodeScalars.allSatisfy { CharacterSet.punctuationCharacters.contains($0) || CharacterSet.symbols.contains($0) }
    }
    private func modifiersMatch(_ other: AppKeyBinding) -> Bool {
        if normalizedModifiers == other.normalizedModifiers { return true }
        // AppKit implicitly adds Shift for character equivalents such as ⌘?.
        let shift = NSEvent.ModifierFlags.shift.rawValue
        guard normalizedModifiers ^ other.normalizedModifiers == shift,
              normalizedCharacters == other.normalizedCharacters else { return false }
        return (!physical && isPunctuation && normalizedModifiers & shift == 0)
            || (!other.physical && other.isPunctuation && other.normalizedModifiers & shift == 0)
    }
    func matches(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, isAssigned else { return false }
        if physical {
            return keyCode == event.keyCode && normalizedModifiers == event.modifierFlags.intersection(Self.modifierMask).rawValue
        }
        guard let pressed = AppKeyBinding(event: event), modifiersMatch(pressed) else { return false }
        return normalizedCharacters == pressed.normalizedCharacters
            || normalizedCharacters == pressed.baseCharacters?.lowercased()
    }

    func conflicts(with other: AppKeyBinding) -> Bool {
        guard isAssigned, other.isAssigned, modifiersMatch(other) else { return false }
        if physical && other.physical { return keyCode == other.keyCode }
        if normalizedCharacters == other.normalizedCharacters { return true }
        if !physical && normalizedCharacters == other.baseCharacters?.lowercased() { return true }
        return !other.physical && other.normalizedCharacters == baseCharacters?.lowercased()
    }

    var label: String {
        guard isAssigned else { return "Nicht belegt" }
        let flags = NSEvent.ModifierFlags(rawValue: normalizedModifiers)
        let prefix = (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "")
            + (flags.contains(.shift) ? "⇧" : "") + (flags.contains(.command) ? "⌘" : "")
        if isFunctionKey, let scalar = characters.unicodeScalars.first {
            return prefix + "F\(Int(scalar.value) - NSF1FunctionKey + 1)"
        }
        let names = ["\r": "↩", "\u{3}": "⌤", "\t": "⇥", "\u{19}": "⇤", " ": "Leertaste",
                     "\u{1b}": "Esc", "\u{8}": "⌫", "\u{7f}": "⌫",
                     functionKey(NSDeleteFunctionKey): "⌦", functionKey(NSUpArrowFunctionKey): "↑",
                     functionKey(NSDownArrowFunctionKey): "↓", functionKey(NSLeftArrowFunctionKey): "←",
                     functionKey(NSRightArrowFunctionKey): "→", functionKey(NSHomeFunctionKey): "↖",
                     functionKey(NSEndFunctionKey): "↘", functionKey(NSPageUpFunctionKey): "⇞",
                     functionKey(NSPageDownFunctionKey): "⇟"]
        return prefix + (names[characters] ?? characters.uppercased())
    }

    /// AppKit menu equivalents are character based even for recorded physical keys.
    var menuKeyEquivalent: String { characters.lowercased() }
}
