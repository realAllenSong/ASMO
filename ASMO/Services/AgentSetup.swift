#if os(macOS)
import Foundation

/// Connects the agents on this Mac to ASMO, with nothing for the person to type: puts the `asmo` command (inside
/// the app) on ~/.local/bin, gives Claude Code and Codex the skill, and registers the MCP server with the Claude
/// desktop app. Runs at every launch and only writes what is missing or out of date.
enum AgentSetup {
    struct Status: Equatable {
        /// nil: not on this Mac.
        var command = false
        var claudeCode: Bool?
        var codex: Bool?
        var claudeDesktop: Bool?
    }

    private static let files = FileManager.default
    private static var home: URL { files.homeDirectoryForCurrentUser }

    /// The command that ships inside the app (a build from source has none: script/install.sh installs it).
    static var helper: URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/asmo")
        return files.isExecutableFile(atPath: url.path) ? url : nil
    }

    private static var skill: Data? {
        Bundle.main.url(forResource: "asmo-skill", withExtension: "md").flatMap { try? Data(contentsOf: $0) }
    }

    @discardableResult
    static func run() -> Status {
        var status = Status()
        let link = home.appendingPathComponent(".local/bin/asmo")
        if let helper {
            let current = try? files.destinationOfSymbolicLink(atPath: link.path)
            if current != helper.path {
                try? files.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? files.removeItem(at: link)
                try? files.createSymbolicLink(at: link, withDestinationURL: helper)
            }
        }
        status.command = files.isExecutableFile(atPath: link.path)

        for (folder, keyPath) in [(".claude", \Status.claudeCode), (".codex", \Status.codex)] {
            let root = home.appendingPathComponent(folder)
            guard files.fileExists(atPath: root.path) else { continue }
            let target = root.appendingPathComponent("skills/asmo/SKILL.md")
            if let skill, (try? Data(contentsOf: target)) != skill {
                try? files.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? skill.write(to: target, options: .atomic)
            }
            status[keyPath: keyPath] = files.fileExists(atPath: target.path)
        }

        let claude = home.appendingPathComponent("Library/Application Support/Claude")
        if files.fileExists(atPath: claude.path) {
            status.claudeDesktop = registerMCP(in: claude.appendingPathComponent("claude_desktop_config.json"))
        }
        return status
    }

    /// Adds (or corrects) the "asmo" entry, keeping everything else in the file as it was.
    private static func registerMCP(in config: URL) -> Bool {
        let command = helper?.path ?? home.appendingPathComponent(".local/bin/asmo").path
        guard files.isExecutableFile(atPath: command) else { return false }
        var settings: [String: Any] = [:]
        if let data = try? Data(contentsOf: config) {
            guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            settings = parsed
        }
        var servers = settings["mcpServers"] as? [String: Any] ?? [:]
        let entry = servers["asmo"] as? [String: Any]
        if entry?["command"] as? String == command, entry?["args"] as? [String] == ["mcp"] { return true }
        servers["asmo"] = ["command": command, "args": ["mcp"]]
        settings["mcpServers"] = servers
        guard let out = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return false }
        return (try? out.write(to: config, options: .atomic)) != nil
    }
}
#endif
