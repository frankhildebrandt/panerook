import AppKit

struct AppKeyBinding: Codable {
    var keyCode: UInt16
    var modifiers: UInt
    var characters: String
    static func function(_ number: Int) -> AppKeyBinding {
        let codes: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109]
        precondition((1...10).contains(number))
        return AppKeyBinding(
            keyCode: codes[number - 1], modifiers: 0,
            characters: String(UnicodeScalar(NSF1FunctionKey + number - 1)!))
    }
    func matches(_ event: NSEvent) -> Bool {
        keyCode == event.keyCode
            && modifiers == event.modifierFlags.intersection([.command, .control, .option, .shift]).rawValue
    }
    var label: String {
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
        let prefix =
            (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "")
            + (flags.contains(.shift) ? "⇧" : "") + (flags.contains(.command) ? "⌘" : "")
        if let scalar = characters.unicodeScalars.first, Int(scalar.value) >= NSF1FunctionKey,
            Int(scalar.value) <= NSF35FunctionKey
        {
            return prefix + "F\(Int(scalar.value) - NSF1FunctionKey + 1)"
        }
        return prefix + characters.uppercased()
    }
}
