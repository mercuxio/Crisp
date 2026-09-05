import Foundation

public struct ParseError: Error, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
}

public struct ListOptions: Equatable, Sendable {
    public var displayIndex: Int?
    public var includeAll: Bool
    public var json: Bool

    public init(displayIndex: Int? = nil, includeAll: Bool = false, json: Bool = false) {
        self.displayIndex = displayIndex
        self.includeAll = includeAll
        self.json = json
    }
}

public struct SetOptions: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var displayIndex: Int?
    public var refreshMilliHz: Int?
    public var hiDPI: Bool?
    public var includeUnsafe: Bool
    public var includeStretched: Bool
    public var permanent: Bool
    public var assumeYes: Bool
    public var timeoutSeconds: Int

    public init(
        width: Int,
        height: Int,
        displayIndex: Int? = nil,
        refreshMilliHz: Int? = nil,
        hiDPI: Bool? = nil,
        includeUnsafe: Bool = false,
        includeStretched: Bool = false,
        permanent: Bool = false,
        assumeYes: Bool = false,
        timeoutSeconds: Int = 15
    ) {
        self.width = width
        self.height = height
        self.displayIndex = displayIndex
        self.refreshMilliHz = refreshMilliHz
        self.hiDPI = hiDPI
        self.includeUnsafe = includeUnsafe
        self.includeStretched = includeStretched
        self.permanent = permanent
        self.assumeYes = assumeYes
        self.timeoutSeconds = timeoutSeconds
    }
}

public enum Command: Equatable, Sendable {
    case list(ListOptions)
    case set(SetOptions)
    case restore
    case doctor
    case help
}

public enum ArgumentParser {
    public static func parse(_ arguments: [String]) throws -> Command {
        guard let verb = arguments.first else { return .help }
        let rest = Array(arguments.dropFirst())

        switch verb {
        case "--help", "-h", "help": return .help
        case "list": return .list(try parseList(rest))
        case "set": return .set(try parseSet(rest))
        case "restore":
            try requireNoArguments(rest, for: "restore")
            return .restore
        case "doctor":
            try requireNoArguments(rest, for: "doctor")
            return .doctor
        default:
            throw ParseError("unknown command '\(verb)' — try 'displayctl --help'")
        }
    }

    private static func requireNoArguments(_ rest: [String], for verb: String) throws {
        guard rest.isEmpty else {
            throw ParseError("'\(verb)' takes no arguments, got '\(rest[0])'")
        }
    }

    private static func parseList(_ rest: [String]) throws -> ListOptions {
        var options = ListOptions()
        var seen: Set<String> = []
        var index = 0
        while index < rest.count {
            try markSeen(rest[index], canonical: rest[index], in: &seen, for: "list")
            switch rest[index] {
            case "--display":
                options.displayIndex = try value(rest, after: &index, flag: "--display")
            case "--all":
                options.includeAll = true
            case "--json":
                options.json = true
            default:
                throw ParseError("unexpected argument '\(rest[index])' for 'list'")
            }
            index += 1
        }
        return options
    }

    private static func parseSet(_ rest: [String]) throws -> SetOptions {
        guard let resolution = rest.first else {
            throw ParseError("'set' needs a resolution, e.g. 'displayctl set 2560x1440'")
        }
        let (width, height) = try parseResolution(resolution)

        var options = SetOptions(width: width, height: height)
        var seen: Set<String> = []
        var index = 1
        while index < rest.count {
            let canonical = canonicalSetFlag(rest[index])
            try markSeen(rest[index], canonical: canonical, in: &seen, for: "set")
            switch rest[index] {
            case "--display":
                options.displayIndex = try value(rest, after: &index, flag: "--display")
            case "--hz":
                options.refreshMilliHz = try refreshValue(rest, after: &index)
            case "--hidpi":
                options.hiDPI = true
            case "--no-hidpi":
                options.hiDPI = false
            case "--unsafe":
                options.includeUnsafe = true
            case "--stretched":
                options.includeStretched = true
            case "--permanent":
                options.permanent = true
            case "--yes", "-y":
                options.assumeYes = true
            case "--timeout":
                options.timeoutSeconds = try value(rest, after: &index, flag: "--timeout")
            default:
                throw ParseError("unexpected argument '\(rest[index])' for 'set'")
            }
            index += 1
        }
        return options
    }

    /// Maps a `set` flag to the key that tracks whether it (or an alias, or an
    /// opposite that changes the same field) has already been given.
    ///
    /// `--yes` and `-y` are two spellings of the same field, so they share a
    /// key: `set 1920x1080 -y --yes` is just as much a repeat as `--yes
    /// --yes`. `--hidpi` and `--no-hidpi` are not spellings of each other, but
    /// they set the same field to opposite values, and giving both is the
    /// contradiction that actually changes which mode gets applied to a
    /// screen — silent last-wins there is worse than for the harmless
    /// `-y`/`--yes` pair, so it collides on one key too.
    private static func canonicalSetFlag(_ flag: String) -> String {
        switch flag {
        case "-y": return "--yes"
        case "--no-hidpi": return "--hidpi"
        default: return flag
        }
    }

    /// Rejects a flag that has already been given once.
    ///
    /// A repeated flag with a value is silent last-wins otherwise: `set
    /// 2560x1440 --display 1 --display 2` would reconfigure a screen the user
    /// did not name, and `set` is the tool reached for when the screen cannot
    /// be seen to notice the mistake. `flag` is the token actually typed, used
    /// only for the error message; `canonical` is what gets recorded as seen,
    /// so aliases (or contradictory opposites) of the same option collide with
    /// each other. When `flag` differs from `canonical`, the message names
    /// both spellings — otherwise "'-y' was given more than once" is false
    /// when `-y` appeared exactly once and `--yes` was the earlier repeat.
    private static func markSeen(
        _ flag: String, canonical: String, in seen: inout Set<String>, for verb: String
    ) throws {
        guard flag.hasPrefix("-") else { return }
        guard seen.insert(canonical).inserted else {
            if flag == canonical {
                throw ParseError("'\(flag)' was given more than once for '\(verb)'")
            }
            throw ParseError(
                "'\(flag)' and '\(canonical)' are the same option for '\(verb)' "
                    + "— it was given more than once")
        }
    }

    /// Accepts `2560x1440` and `2560X1440` — someone typing this blind should
    /// not be defeated by caps lock.
    private static func parseResolution(_ text: String) throws -> (Int, Int) {
        let parts = text.lowercased().split(separator: "x", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let width = Int(parts[0]), let height = Int(parts[1]),
              width > 0, height > 0
        else {
            throw ParseError("'\(text)' is not a resolution — expected WIDTHxHEIGHT, e.g. 2560x1440")
        }
        return (width, height)
    }

    private static func value(
        _ rest: [String], after index: inout Int, flag: String
    ) throws -> Int {
        guard index + 1 < rest.count, let parsed = Int(rest[index + 1]), parsed > 0 else {
            throw ParseError("'\(flag)' needs a positive whole number")
        }
        index += 1
        return parsed
    }

    private static func refreshValue(_ rest: [String], after index: inout Int) throws -> Int {
        guard index + 1 < rest.count, let hz = Double(rest[index + 1]), hz > 0 else {
            throw ParseError("'--hz' needs a refresh rate, e.g. 60 or 59.94")
        }
        index += 1
        return Int((hz * 1000).rounded())
    }
}
