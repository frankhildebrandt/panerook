import Foundation

struct SSHOptions {
    let connection: RemoteConnection
    func sshArguments() -> [String] {
        var args = [
            "-oBatchMode=yes", "-oStrictHostKeyChecking=yes", "-oConnectTimeout=\(connection.timeout)",
            "-oServerAliveInterval=15", "-oServerAliveCountMax=2",
        ]
        if !connection.identityFile.isEmpty {
            args += ["-i", (connection.identityFile as NSString).expandingTildeInPath]
        }
        return args
    }
}
