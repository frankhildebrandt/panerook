import Foundation

public struct RemoteProviderDescription: Sendable {
    public let title: String
    public let menuTitle: String
    public let menuOrder: Int
    public let defaultPort: Int
    public let usesPassword: Bool
    public var hostPlaceholder = "server.example.org"
    public var hostHint: String? = nil
    public var passwordLabel = "Passwort"
    public var passwordAccessibilityLabel = "Passwort"
    public var passwordHint: String? = nil
    public var pathHint: String? = nil
    public var notice = "SSH-Schlüssel/Agent · bekannte Hosts erforderlich."
    public var deleteTitle = "Remote-Einträge endgültig löschen?"
    public var deleteNotice = "Ordner werden mit ihrem Inhalt gelöscht. PaneRook verwendet dabei keinen Papierkorb."
}

extension RemoteProtocol {
    /// Stable UI order; adding a protocol never requires editing dialogs or menus.
    public static var available: [RemoteProtocol] { [.sftp, .shell, .ftp, .nextcloud] }
    public var provider: RemoteProviderDescription {
        RemoteProviderRegistry.provider(for: self).description
    }
}
