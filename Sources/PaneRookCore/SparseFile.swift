import Foundation
import Darwin

public enum SparseFileUnit: String, CaseIterable, Sendable {
    case bytes, kibibytes, mebibytes, gibibytes, tebibytes

    public var label: String {
        switch self {
        case .bytes: return "B"
        case .kibibytes: return "KiB"
        case .mebibytes: return "MiB"
        case .gibibytes: return "GiB"
        case .tebibytes: return "TiB"
        }
    }
    private var shift: Int {
        switch self {
        case .bytes: return 0
        case .kibibytes: return 10
        case .mebibytes: return 20
        case .gibibytes: return 30
        case .tebibytes: return 40
        }
    }
    fileprivate var multiplier: Int64 { Int64(1) << shift }
}

public enum SparseFileError: LocalizedError {
    case invalidSize, localDirectoryOnly

    public var errorDescription: String? {
        switch self {
        case .invalidSize:
            return "Bitte eine nicht negative Größe in ganzen Bytes eingeben (höchstens 9.223.372.036.854.775.807 Bytes)."
        case .localDirectoryOnly:
            return "Eine Sparse-Datei benötigt einen lokalen Ordner."
        }
    }
}

public enum SparseFile {
    /// Accept decimal comma or point, but never round fractional bytes or overflow.
    public static func logicalSize(from input: String, unit: SparseFileUnit) throws -> Int64 {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.range(of: #"^[0-9]+([.,][0-9]+)?$"#, options: .regularExpression) != nil else {
            throw SparseFileError.invalidSize
        }
        let parts = value.replacingOccurrences(of: ",", with: ".").split(separator: ".", omittingEmptySubsequences: false)
        let whole = String(parts[0].drop(while: { $0 == "0" }))
        let fraction = parts.count == 2 ? String(parts[1].reversed().drop(while: { $0 == "0" }).reversed()) : ""
        let significant = (whole + fraction).drop(while: { $0 == "0" })
        if significant.isEmpty { return 0 }
        // Decimal has 38 significant digits and a finite exponent range. Do not
        // allow its parser to silently discard digits supplied by the user.
        guard significant.count <= 38, fraction.count <= 127,
              var amount = Decimal(string: (whole.isEmpty ? "0" : whole) + (fraction.isEmpty ? "" : "." + fraction),
                                   locale: Locale(identifier: "en_US_POSIX")) else { throw SparseFileError.invalidSize }
        var factor = Decimal(unit.multiplier)
        var bytes = Decimal()
        guard NSDecimalMultiply(&bytes, &amount, &factor, .plain) == .noError,
              bytes >= 0, bytes <= Decimal(Int64.max) else { throw SparseFileError.invalidSize }
        var integer = Decimal()
        NSDecimalRound(&integer, &bytes, 0, .plain)
        guard integer == bytes else { throw SparseFileError.invalidSize }
        return NSDecimalNumber(decimal: bytes).int64Value
    }

    /// ftruncate grows the logical address space without writing or preallocating
    /// file contents. The target is created exclusively, even if it is a symlink.
    @discardableResult public static func create(named name: String, in directory: URL, logicalSize: Int64) throws -> URL {
        try FileActions.validateName(name)
        guard directory.isFileURL, !directory.path.contains("\0") else { throw SparseFileError.localDirectoryOnly }
        guard logicalSize >= 0 else { throw SparseFileError.invalidSize }
        let parent = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard parent >= 0 else { throw posix(directory) }
        defer { close(parent) }
        let destination = directory.appendingPathComponent(name)
        let descriptor = openat(parent, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o666)
        guard descriptor >= 0 else { throw posix(destination) }
        defer { close(descriptor) }
        var original = stat()
        guard fstat(descriptor, &original) == 0 else {
            // The descriptor is valid and owned exclusively by this call. Without
            // an inode snapshot, leave the entry intact rather than unlink a race.
            throw posix(destination)
        }
        var completed = false
        defer {
            if !completed {
                var current = stat()
                if fstatat(parent, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
                   current.st_dev == original.st_dev, current.st_ino == original.st_ino {
                    unlinkat(parent, name, 0)
                }
            }
        }
        guard ftruncate(descriptor, off_t(logicalSize)) == 0 else { throw posix(destination) }
        completed = true
        return destination
    }

    private static func posix(_ url: URL) -> Error {
        let code = errno
        if code == EEXIST { return FileActionError.collision(url.lastPathComponent) }
        return NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: url.path])
    }
}
