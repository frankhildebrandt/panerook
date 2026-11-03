import Foundation

extension SFTPTransport {
    /// The system sftp CLI chooses posix-rename@openssh.com automatically.
    /// Send the standard v3 RENAME instead: it MUST reject an existing target.
    /// INIT and one request may be pipelined; the subsystem processes them in order.
    func moveExclusively(_ path: String, to destination: String, token: RemoteCancellation) throws {
        try token.check()
        var arguments = SSHOptions(connection: connection).sshArguments() + ["-p", String(connection.port)]
        if !connection.user.isEmpty { arguments += ["-l", connection.user] }
        arguments += ["-s", "--", connection.host, "sftp"]
        let initPacket = SFTPRenamePacket.packet(Data([1]) + SFTPRenamePacket.integer(3))
        let rename = Data([18]) + SFTPRenamePacket.integer(1)
            + SFTPRenamePacket.string(path) + SFTPRenamePacket.string(destination)
        var invocation = RemoteInvocation(executable: "/usr/bin/ssh", arguments: arguments,
                                          input: initPacket + SFTPRenamePacket.packet(rename))
        invocation.closeInputAfterOutput = SFTPRenamePacket.hasReply
        let response = try runner(invocation, token)
        try token.check()
        try SFTPRenamePacket.validate(response)
    }
}

/// Kept deliberately small: no general SFTP client, only INIT + RENAME + STATUS.
enum SFTPRenamePacket {
    static func hasReply(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        var cursor = 0, count = 0
        while cursor + 4 <= bytes.count {
            let length = Int(bytes[cursor..<cursor + 4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
            if length <= 0 || length > 1024 * 1024 { return true }
            guard cursor + 4 + length <= bytes.count else { return false }
            cursor += 4 + length; count += 1
            if count == 2 { return true }
        }
        return false
    }
    static func integer(_ value: UInt32) -> Data {
        Data([UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
              UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)])
    }
    static func string(_ value: String) -> Data { let data = Data(value.utf8); return integer(UInt32(data.count)) + data }
    static func packet(_ body: Data) -> Data { integer(UInt32(body.count)) + body }
    static func validate(_ response: Data) throws {
        let bytes = [UInt8](response)
        var cursor = 0
        func number(at offset: Int) throws -> UInt32 {
            guard offset >= 0, offset + 4 <= bytes.count else { throw RemoteError.process("Unvollständige SFTP-Antwort.") }
            return bytes[offset..<offset + 4].reduce(0) { ($0 << 8) | UInt32($1) }
        }
        var versionSeen = false
        while cursor < bytes.count {
            let length = Int(try number(at: cursor)); cursor += 4
            guard length > 0, length <= 1024 * 1024, cursor + length <= bytes.count else {
                throw RemoteError.process("Ungültige SFTP-Antwort.")
            }
            let end = cursor + length
            switch bytes[cursor] {
            case 2 where !versionSeen:
                guard length >= 5, try number(at: cursor + 1) == 3 else {
                    throw RemoteError.process("Der Server unterstützt SFTP v3 nicht.")
                }
                versionSeen = true
            case 101 where versionSeen:
                guard length >= 9, try number(at: cursor + 1) == 1 else { throw RemoteError.process("Ungültige SFTP-Statusantwort.") }
                let status = try number(at: cursor + 5)
                guard status == 0 else {
                    var detail = "Status \(status)"
                    if length >= 13 {
                        let count = Int(try number(at: cursor + 9))
                        if count <= end - cursor - 13 { detail = String(decoding: bytes[cursor + 13..<cursor + 13 + count], as: UTF8.self) }
                    }
                    throw RemoteError.process("SFTP konnte die Datei nicht ohne Überschreiben veröffentlichen: " + detail)
                }
                return
            default: throw RemoteError.process("Unerwartete SFTP-Antwort.")
            }
            cursor = end
        }
        throw RemoteError.process("Die SFTP-Bestätigung fehlt. Arbeitskopie und Serversicherung bleiben erhalten.")
    }
}
