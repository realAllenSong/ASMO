import Foundation

// asmo: the command coding agents (and people) use to read and change 逐日 (ASMO).
// It sends one JSON request to the running app over a socket in the app's container and prints the JSON answer.
// The app is started in the background when it isn't running. `asmo mcp` offers the same as an MCP server.

let usage = """
asmo — read and change 逐日 (ASMO) from the command line. Answers are JSON.

Days are YYYY-MM-DD, today, tomorrow, yesterday, +N / -N (days from today), or YYYY-MM (a plan for the month).
Times are 24-hour HH:MM. Ids can be shortened to their first characters (4 or more).

Items
  asmo today                         everything on today: tasks (with subtasks), routines, dates, the page
  asmo day DAY                       the same for another day
  asmo list FROM [TO] [--open]       tasks in a range of days (--open: unfinished only)
  asmo search TEXT                   tasks whose title or note contains TEXT
  asmo add TITLE [--day DAY] [--time HH:MM] [--end HH:MM] [--note TEXT] [--under ID] [--done]
  asmo add --json [--day DAY]        many at once, JSON on stdin:
                                     [{"title":"…","time":"09:00","end":"10:00","note":"…","day":"…",
                                       "subtasks":[{"title":"…"}]}]
  asmo set ID [--title T] [--day DAY] [--time HH:MM|none] [--end HH:MM|none] [--note TEXT] [--under ID|none]
  asmo done ID…  /  asmo undone ID…  check off / uncheck
  asmo rm ID…                        delete (subtasks go with their parent)

The day's page (free notes under the items), written in Markdown
  asmo page [DAY]                    the page as blocks: b1, b2, … each with its Markdown
  asmo page write [DAY] [--file F] [--replace] [--after BLOCK|top]
                                     Markdown from stdin (or --file) goes at the end of the page; --replace
                                     rewrites the whole page; --after puts it after a block (or at the top)
  asmo page set DAY BLOCK [--file F] replace one block with the Markdown from stdin (or --file)
  asmo page rm DAY BLOCK…            remove blocks
  asmo pages [FROM] [TO]             which days have a page, with each one's length and first line
  asmo page import [--file F] [--replace|--append]
                                     many days at once: a JSON object {"YYYY-MM-DD": "Markdown", …} on stdin;
                                     by default only days with no page yet are written (--replace rewrites them,
                                     --append adds below); one save, one undo
  asmo attach FILE… [--day DAY] [--caption TEXT]
                                     put pictures on the page
  Markdown: headings, **bold**, *italic*, ~~strike~~, `code`, [links](https://…), lists, - [ ] checkboxes,
  > quotes, tables, ``` code blocks, ```mermaid diagrams (drawn as pictures), and ![pictures](path or URL).

Routines
  asmo routines                      repeating items
  asmo routine add TITLE [--on daily|weekdays|weekends|mon,thu|monthly|monthly:15] [--time HH:MM] [--end HH:MM] [--from DAY]
  asmo routine done|skip|clear ID [--day DAY]
  asmo routine stop ID               ends it from today on

Important dates (birthdays, anniversaries, holidays; every year)
  asmo dates
  asmo date add TITLE --on MM-DD [--year YYYY] [--kind birthday|anniversary|holiday] [--lunar]
  asmo date rm ID

  asmo undo                          take back the last change made with asmo (repeat for earlier ones)
  asmo mirror [on|off]               keep Apple Calendar (timed items) and Reminders (day items) in step
                                     with 逐日 now, both ways, and report what changed; on/off turns it on or off
  asmo open                          bring the app's window to the front
  asmo ping                          is the app there
  asmo mcp                           run as an MCP server on stdin/stdout (for apps without a shell)
  asmo setup [--skill FILE]          put asmo on your PATH (~/.local/bin), give Claude Code and Codex the skill,
                                     and register the MCP server with the Claude desktop app

Add --test to talk to the Debug build's test store instead of the real data.
"""

struct Problem: Error { let message: String }

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

// MARK: Talking to the app

var useTestStore = false
/// The app's bundle id (a build made under another id: ASMO_BUNDLE_ID=com.you.asmo).
let bundleID = ProcessInfo.processInfo.environment["ASMO_BUNDLE_ID"] ?? "com.realallensong.asmo"

func connectToApp(_ path: String) -> Int32? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { close(fd); return nil }
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
    let result = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    if result == 0 { return fd }
    close(fd)
    return nil
}

/// One request, one answer (without its "ok"). Starts the app in the background when it isn't running.
func send(_ request: [String: Any]) throws -> [String: Any] {
    let socketName = useTestStore ? "asmo-test.sock" : "asmo.sock"
    // Since 1.1 the app lives outside the sandbox (Application Support/ASMO); 1.0 kept the socket in its container.
    let paths = [NSHomeDirectory() + "/Library/Application Support/ASMO/" + socketName,
                 NSHomeDirectory() + "/Library/Containers/\(bundleID)/Data/" + socketName]
    func reach() -> Int32? { paths.lazy.compactMap(connectToApp).first }
    var connection = reach()
    if connection == nil {
        if useTestStore { throw Problem(message: "The test build isn't running. Start it with script/run_test_store.sh.") }
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-g", "-b", bundleID]
        try? open.run()
        open.waitUntilExit()
        for _ in 0..<50 where connection == nil {
            usleep(200_000)
            connection = reach()
        }
    }
    guard let fd = connection else {
        throw Problem(message: "Couldn't reach 逐日 (ASMO). Is it installed in /Applications, and is this program allowed to read other apps' data?")
    }
    defer { close(fd) }
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    let body = try JSONSerialization.data(withJSONObject: request)
    body.withUnsafeBytes { raw in
        var sent = 0
        while sent < raw.count {
            let count = write(fd, raw.baseAddress! + sent, raw.count - sent)
            if count <= 0 { break }
            sent += count
        }
    }
    shutdown(fd, SHUT_WR)
    var answer = Data()
    var buffer = [UInt8](repeating: 0, count: 65_536)
    while true {
        let count = read(fd, &buffer, buffer.count)
        if count <= 0 { break }
        answer.append(buffer, count: count)
    }
    guard var reply = try? JSONSerialization.jsonObject(with: answer) as? [String: Any] else { throw Problem(message: "The app gave no answer.") }
    if reply["ok"] as? Bool != true { throw Problem(message: reply["error"] as? String ?? "failed") }
    reply["ok"] = nil
    return reply
}

func text(_ reply: [String: Any]) -> String {
    let data = (try? JSONSerialization.data(withJSONObject: reply, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
    return String(decoding: data, as: UTF8.self)
}

/// The pictures a piece of Markdown points at (files on this Mac, or web addresses), read here and sent along:
/// the app is sandboxed and can't open them itself. Pictures already on the page ("asmo-image:2") stay as they are.
func pictures(in markdown: String) throws -> [String: String] {
    var found: [String: String] = [:]
    let pattern = try NSRegularExpression(pattern: #"!\[[^\]]*\]\(\s*(?:<([^>]+)>|([^)\s]+))(?:\s+"[^"]*")?\s*\)"#)
    for match in pattern.matches(in: markdown, range: NSRange(markdown.startIndex..., in: markdown)) {
        guard let range = Range(match.range(at: 1), in: markdown) ?? Range(match.range(at: 2), in: markdown) else { continue }
        let target = String(markdown[range])
        if target.hasPrefix("asmo-image:") || found[target] != nil { continue }
        let data: Data?
        if target.hasPrefix("http://") || target.hasPrefix("https://") {
            data = URL(string: target).flatMap { try? Data(contentsOf: $0) }
        } else {
            let path = (target.removingPercentEncoding ?? target) as NSString
            data = FileManager.default.contents(atPath: path.expandingTildeInPath)
        }
        guard let data, !data.isEmpty else { throw Problem(message: "Couldn't read the picture \(target).") }
        found[target] = data.base64EncodedString()
    }
    return found
}

/// A page-writing request with its pictures.
func pageRequest(_ request: [String: Any]) throws -> [String: Any] {
    var request = request
    if let markdown = request["markdown"] as? String {
        let images = try pictures(in: markdown)
        if !images.isEmpty { request["images"] = images }
    }
    return request
}

// MARK: MCP (the same commands as tools, for apps that have no shell)

struct Tool {
    var name: String
    var about: String
    var properties: [String: Any]
    var required: [String] = []
    var request: ([String: Any]) throws -> [String: Any]
}

let dayHelp = "YYYY-MM-DD, today, tomorrow, yesterday, or +N / -N days from today"
let stringType: [String: Any] = ["type": "string"]
func described(_ type: String, _ about: String) -> [String: Any] { ["type": type, "description": about] }
let itemSchema: [String: Any] = [
    "type": "object",
    "properties": [
        "title": described("string", "Short, says the thing to do"),
        "day": described("string", dayHelp + ", or YYYY-MM for some time that month"),
        "time": described("string", "Start, 24-hour HH:MM"),
        "end": described("string", "End, HH:MM"),
        "note": stringType,
        "done": ["type": "boolean"],
        "subtasks": described("array", "Items of the same shape, up to three levels deep"),
    ],
    "required": ["title"],
]

func passing(_ command: String) -> ([String: Any]) throws -> [String: Any] {
    { arguments in arguments.merging(["cmd": command]) { _, new in new } }
}

let tools: [Tool] = [
    Tool(name: "day", about: "Everything on one day of the user's 逐日 (ASMO) planner: tasks with subtasks, routines, important dates, and the day's page as Markdown. Read this before changing a day.",
         properties: ["day": described("string", dayHelp)], request: passing("day")),
    Tool(name: "list_tasks", about: "Tasks in a range of days.",
         properties: ["from": described("string", dayHelp), "to": described("string", dayHelp),
                      "open_only": described("boolean", "Leave out finished tasks")], required: ["from"],
         request: { ["cmd": "list", "from": $0["from"] ?? "today", "to": $0["to"] ?? $0["from"] ?? "today", "done": !($0["open_only"] as? Bool ?? false)] }),
    Tool(name: "search_tasks", about: "Tasks whose title or note contains the text.",
         properties: ["query": stringType], required: ["query"], request: passing("search")),
    Tool(name: "add_tasks", about: "Add one or more tasks (with subtasks). Work out dates and times yourself and pass them explicitly.",
         properties: ["day": described("string", "The day for items that don't name their own; " + dayHelp),
                      "items": ["type": "array", "items": itemSchema]], required: ["items"], request: passing("add")),
    Tool(name: "update_task", about: "Change a task: title, day, time, end, note, done, or the task it sits under. Pass \"\" for time, end or parent to clear it. A new start time keeps the length.",
         properties: ["id": stringType, "title": stringType, "day": described("string", dayHelp), "time": stringType, "end": stringType,
                      "note": stringType, "done": ["type": "boolean"], "parent": described("string", "Id of the task to put it under")],
         required: ["id"], request: passing("update")),
    Tool(name: "set_done", about: "Check tasks off, or uncheck them.",
         properties: ["ids": ["type": "array", "items": stringType], "done": ["type": "boolean"]], required: ["ids"], request: passing("done")),
    Tool(name: "delete_tasks", about: "Delete tasks (subtasks go with their parent). Only what the user asked to remove; `undo` takes it back.",
         properties: ["ids": ["type": "array", "items": stringType]], required: ["ids"], request: passing("delete")),
    Tool(name: "read_page", about: "A day's page (free notes under the items) as blocks b1, b2, …, each with its Markdown.",
         properties: ["day": described("string", dayHelp)], request: passing("page")),
    Tool(name: "write_page", about: "Write Markdown onto a day's page: headings, bold, italic, strike, code, links, lists, checkboxes, quotes, tables, code blocks, ```mermaid diagrams (drawn as pictures) and ![pictures](absolute file path or URL). Appends by default.",
         properties: ["day": described("string", dayHelp), "markdown": stringType,
                      "mode": ["type": "string", "enum": ["append", "replace"], "description": "replace rewrites the whole page"],
                      "after": described("string", "Put it after this block id, or \"top\"")],
         required: ["markdown"], request: { try pageRequest($0.merging(["cmd": "page-write"]) { _, new in new }) }),
    Tool(name: "list_pages", about: "Which days have a page (in a range), each with its length and first line.",
         properties: ["from": described("string", dayHelp), "to": described("string", dayHelp)], request: passing("pages")),
    Tool(name: "import_pages", about: "Write many days' pages at once (an imported journal or history): pages is an object of YYYY-MM-DD → Markdown. mode missing (default) writes only days without a page, replace rewrites, append adds below. One undo.",
         properties: ["pages": ["type": "object", "additionalProperties": stringType],
                      "mode": ["type": "string", "enum": ["missing", "replace", "append"]]],
         required: ["pages"], request: passing("page-import")),
    Tool(name: "set_page_block", about: "Replace one block of a day's page with new Markdown. Read the page first for the block ids.",
         properties: ["day": described("string", dayHelp), "block": described("string", "b1, b2, …"), "markdown": stringType],
         required: ["day", "block", "markdown"], request: { try pageRequest($0.merging(["cmd": "page-set"]) { _, new in new }) }),
    Tool(name: "remove_page_blocks", about: "Remove blocks from a day's page.",
         properties: ["day": described("string", dayHelp), "blocks": ["type": "array", "items": stringType]],
         required: ["day", "blocks"], request: passing("page-remove")),
    Tool(name: "routines", about: "The user's repeating items.", properties: [:], request: passing("routines")),
    Tool(name: "add_routine", about: "Add a repeating item.",
         properties: ["title": stringType, "weekdays": described("string", "daily, weekdays, weekends, names like mon,thu, monthly (on the start day) or monthly:15"),
                      "time": stringType, "end": stringType, "from": described("string", "First day; " + dayHelp)],
         required: ["title"], request: passing("routine-add")),
    Tool(name: "mark_routine", about: "Mark a routine done or skipped on one day, or clear the mark.",
         properties: ["id": stringType, "day": described("string", dayHelp), "state": ["type": "string", "enum": ["done", "skip", "clear"]]],
         required: ["id", "state"], request: passing("routine-mark")),
    Tool(name: "stop_routine", about: "End a routine from today on.", properties: ["id": stringType], required: ["id"], request: passing("routine-stop")),
    Tool(name: "important_dates", about: "Birthdays, anniversaries and holidays the user keeps.", properties: [:], request: passing("dates")),
    Tool(name: "add_important_date", about: "Add a birthday, anniversary or holiday that comes back every year.",
         properties: ["title": stringType, "on": described("string", "MM-DD"), "year": described("integer", "The year it first happened, if known"),
                      "kind": ["type": "string", "enum": ["birthday", "anniversary", "holiday"]],
                      "lunar": described("boolean", "The date is in the Chinese lunar calendar")],
         required: ["title", "on"], request: passing("date-add")),
    Tool(name: "remove_important_date", about: "Remove an important date.", properties: ["id": stringType], required: ["id"], request: passing("date-remove")),
    Tool(name: "undo", about: "Take back the last change made through these tools (call again for earlier ones).", properties: [:], request: passing("undo")),
]

func runMCP() -> Never {
    func reply(_ id: Any, result: [String: Any]? = nil, error: (Int, String)? = nil) {
        var message: [String: Any] = ["jsonrpc": "2.0", "id": id]
        if let error { message["error"] = ["code": error.0, "message": error.1] } else { message["result"] = result ?? [:] }
        guard let data = try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes]) else { return }
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    }
    while let line = readLine(strippingNewline: true) {
        guard let message = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let method = message["method"] as? String else { continue }
        // Notifications (no id) get no answer.
        guard let id = message["id"] else { continue }
        let parameters = message["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            reply(id, result: ["protocolVersion": parameters["protocolVersion"] as? String ?? "2025-06-18",
                               "capabilities": ["tools": [String: Any]()],
                               "serverInfo": ["name": "asmo", "title": "逐日 (ASMO)", "version": "1.0"],
                               "instructions": "The user's 逐日 (ASMO) planner on this Mac: to-dos by day, subtasks, routines, important dates, and a free page per day written in Markdown. Read a day before changing it; work out dates and times yourself and pass them explicitly."])
        case "ping":
            reply(id)
        case "tools/list":
            reply(id, result: ["tools": tools.map { tool in
                ["name": tool.name, "description": tool.about,
                 "inputSchema": ["type": "object", "properties": tool.properties, "required": tool.required] as [String: Any]] as [String: Any]
            }])
        case "tools/call":
            guard let tool = tools.first(where: { $0.name == parameters["name"] as? String }) else {
                reply(id, error: (-32602, "Unknown tool."))
                continue
            }
            do {
                let answer = try send(try tool.request(parameters["arguments"] as? [String: Any] ?? [:]))
                reply(id, result: ["content": [["type": "text", "text": text(answer)]], "isError": false])
            } catch {
                reply(id, result: ["content": [["type": "text", "text": (error as? Problem)?.message ?? error.localizedDescription]], "isError": true])
            }
        default:
            reply(id, error: (-32601, "Method not found."))
        }
    }
    exit(0)
}

// MARK: Setup

/// Makes this copy of asmo usable from anywhere: a link in ~/.local/bin (when it runs from inside ASMO.app), the
/// skill for Claude Code and Codex (when they are installed), and the Claude desktop app's MCP entry (when that
/// app is installed). Prints what it did.
func setUp(skill: String?) -> Never {
    let files = FileManager.default
    let home = NSHomeDirectory()
    var done: [String] = []
    let me = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
    let link = home + "/.local/bin/asmo"
    if me.contains(".app/Contents/") && me != URL(fileURLWithPath: link).resolvingSymlinksInPath().path {
        try? files.createDirectory(atPath: home + "/.local/bin", withIntermediateDirectories: true)
        try? files.removeItem(atPath: link)
        do { try files.createSymbolicLink(atPath: link, withDestinationPath: me); done.append("linked \(link) → \(me)") }
        catch { fail("Couldn't create \(link): \(error.localizedDescription)") }
    }
    // The skill: given, or the copy inside ASMO.app (Contents/Resources/asmo-skill.md).
    let bundled = URL(fileURLWithPath: me).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/asmo-skill.md").path
    if let text = files.contents(atPath: skill.map { ($0 as NSString).expandingTildeInPath } ?? bundled) {
        for agent in [".claude", ".codex"] where files.fileExists(atPath: home + "/" + agent) {
            let folder = home + "/" + agent + "/skills/asmo"
            try? files.createDirectory(atPath: folder, withIntermediateDirectories: true)
            if files.createFile(atPath: folder + "/SKILL.md", contents: text) { done.append("skill → ~/\(agent)/skills/asmo") }
        }
    } else {
        done.append("no skill file found (pass --skill FILE)")
    }
    let config = home + "/Library/Application Support/Claude/claude_desktop_config.json"
    if let data = files.contents(atPath: config), var settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        let entry: [String: Any] = ["command": files.fileExists(atPath: link) ? link : me, "args": ["mcp"]]
        var servers = settings["mcpServers"] as? [String: Any] ?? [:]
        let current = servers["asmo"] as? [String: Any]
        if current?["command"] as? String != entry["command"] as? String || current?["args"] as? [String] != ["mcp"] {
            servers["asmo"] = entry
            settings["mcpServers"] = servers
            if let out = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
                files.createFile(atPath: config, contents: out)
                done.append("MCP server added to the Claude desktop app (restart it to load)")
            }
        }
    }
    if !(ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").contains(Substring(home + "/.local/bin")) {
        done.append("add ~/.local/bin to your PATH to run asmo from any terminal")
    }
    print(text(["setup": done]))
    exit(0)
}

// MARK: Arguments

var arguments = Array(CommandLine.arguments.dropFirst())
var flags: [String: String] = [:]
var words: [String] = []
let switches: Set<String> = ["--done", "--open", "--json", "--test", "--help", "--replace", "--append", "--lunar"]
var index = 0
while index < arguments.count {
    let argument = arguments[index]
    if argument == "-h" { flags["--help"] = "" }
    else if switches.contains(argument) { flags[argument] = "" }
    else if argument.hasPrefix("--"), argument.count > 2 {
        guard index + 1 < arguments.count else { fail("\(argument) needs a value. See: asmo help") }
        flags[argument] = arguments[index + 1]
        index += 1
    } else { words.append(argument) }
    index += 1
}
useTestStore = flags["--test"] != nil

func flag(_ name: String) -> String? { flags["--" + name] }
/// "none" clears a field.
func cleared(_ value: String) -> Any { value.lowercased() == "none" ? NSNull() : value }
/// Markdown from --file, or from stdin.
func markdownInput() -> String {
    if let file = flag("file") {
        guard let data = FileManager.default.contents(atPath: (file as NSString).expandingTildeInPath) else { fail("Couldn't read \(file).") }
        return String(decoding: data, as: UTF8.self)
    }
    return String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
}

guard let command = words.first, flags["--help"] == nil, command != "help" else { print(usage); exit(0) }
if command == "mcp" { runMCP() }
if command == "setup" { setUp(skill: flag("skill")) }
let rest = Array(words.dropFirst())
var request: [String: Any] = [:]

func put(_ names: [String: String]) {
    for (name, key) in names { if let value = flag(name) { request[key] = value } }
}

do {
    switch command {
    case "ping": request["cmd"] = "ping"
    case "open": request["cmd"] = "show"
    case "undo": request["cmd"] = "undo"
    case "mirror":
        request["cmd"] = "mirror"
        if rest.first == "on" { request["on"] = true }
        if rest.first == "off" { request["on"] = false }
    case "today", "day":
        request = ["cmd": "day", "day": command == "today" ? "today" : rest.first ?? "today"]
    case "list":
        guard let from = rest.first else { fail("asmo list FROM [TO]") }
        request = ["cmd": "list", "from": from, "to": rest.count > 1 ? rest[1] : from, "done": flags["--open"] == nil]
    case "search":
        request = ["cmd": "search", "query": rest.joined(separator: " ")]
    case "add":
        request["cmd"] = "add"
        put(["day": "day", "under": "parent"])
        if flags["--json"] != nil {
            let input = FileHandle.standardInput.readDataToEndOfFile()
            guard let parsed = try? JSONSerialization.jsonObject(with: input) else { fail("stdin is not JSON.") }
            if let items = parsed as? [[String: Any]] { request["items"] = items }
            else if let body = parsed as? [String: Any] { request.merge(body) { flag, _ in flag } }
            else { fail("stdin has to be a JSON array of items, or an object with \"items\".") }
        } else {
            guard !rest.isEmpty else { fail("asmo add TITLE [--day DAY] [--time HH:MM] …") }
            var item: [String: Any] = ["title": rest.joined(separator: " ")]
            for name in ["time", "end", "note"] { if let value = flag(name) { item[name] = value } }
            if flags["--done"] != nil { item["done"] = true }
            request["items"] = [item]
        }
    case "set":
        guard let id = rest.first else { fail("asmo set ID [--title T] [--day DAY] [--time HH:MM|none] …") }
        request = ["cmd": "update", "id": id]
        put(["title": "title", "day": "day", "note": "note"])
        for (name, key) in ["time": "time", "end": "end", "under": "parent"] { if let value = flag(name) { request[key] = cleared(value) } }
        guard request.count > 2 else { fail("Nothing to change. See: asmo help") }
    case "done", "undone":
        guard !rest.isEmpty else { fail("asmo \(command) ID…") }
        request = ["cmd": "done", "ids": rest, "done": command == "done"]
    case "rm":
        guard !rest.isEmpty else { fail("asmo rm ID…") }
        request = ["cmd": "delete", "ids": rest]
    case "page":
        switch rest.first {
        case "write":
            request = ["cmd": "page-write", "day": rest.count > 1 ? rest[1] : "today", "markdown": markdownInput(),
                       "mode": flags["--replace"] != nil ? "replace" : "append"]
            put(["after": "after"])
            request = try pageRequest(request)
        case "set":
            guard rest.count == 3 else { fail("asmo page set DAY BLOCK   (Markdown on stdin, or --file F)") }
            request = try pageRequest(["cmd": "page-set", "day": rest[1], "block": rest[2], "markdown": markdownInput()])
        case "import":
            // {"YYYY-MM-DD": "Markdown", …} on stdin (or --file).
            guard let data = markdownInput().data(using: .utf8),
                  let pages = (try? JSONSerialization.jsonObject(with: data)) as? [String: String] else {
                fail("asmo page import: a JSON object of day → Markdown on stdin (or --file F)")
            }
            request = ["cmd": "page-import", "pages": pages,
                       "mode": flags["--replace"] != nil ? "replace" : flags["--append"] != nil ? "append" : "missing"]
        case "rm":
            guard rest.count >= 3 else { fail("asmo page rm DAY BLOCK…") }
            request = ["cmd": "page-remove", "day": rest[1], "blocks": Array(rest.dropFirst(2))]
        default:
            request = ["cmd": "page", "day": rest.first ?? "today"]
        }
    case "pages":
        request = ["cmd": "pages"]
        if let from = rest.first { request["from"] = from }
        if rest.count > 1 { request["to"] = rest[1] }
    case "attach":
        guard !rest.isEmpty else { fail("asmo attach FILE… [--day DAY] [--caption TEXT]") }
        let caption = flag("caption") ?? ""
        let lines = rest.map { file -> String in
            let path = URL(fileURLWithPath: (file as NSString).expandingTildeInPath).standardizedFileURL.path
            return "![\(caption)](<\(path)>)"
        }
        request = try pageRequest(["cmd": "page-write", "day": flag("day") ?? "today",
                                   "markdown": lines.joined(separator: "\n\n") + (caption.isEmpty ? "" : "\n\n*\(caption)*")])
    case "routines": request["cmd"] = "routines"
    case "routine":
        switch rest.first {
        case "add":
            guard rest.count > 1 else { fail("asmo routine add TITLE [--on daily|weekdays|mon,thu] [--time HH:MM]") }
            request = ["cmd": "routine-add", "title": rest.dropFirst().joined(separator: " ")]
            put(["on": "weekdays", "time": "time", "end": "end", "from": "from"])
        case "stop":
            guard rest.count > 1 else { fail("asmo routine stop ID") }
            request = ["cmd": "routine-stop", "id": rest[1]]
        case "done", "skip", "clear":
            guard rest.count > 1 else { fail("asmo routine \(rest[0]) ID [--day DAY]") }
            request = ["cmd": "routine-mark", "id": rest[1], "state": rest[0]]
            put(["day": "day"])
        default: fail("asmo routine add|done|skip|clear|stop … See: asmo help")
        }
    case "dates": request["cmd"] = "dates"
    case "date":
        switch rest.first {
        case "add":
            guard rest.count > 1, flag("on") != nil else { fail("asmo date add TITLE --on MM-DD [--year YYYY] [--kind birthday|anniversary|holiday] [--lunar]") }
            request = ["cmd": "date-add", "title": rest.dropFirst().joined(separator: " "), "lunar": flags["--lunar"] != nil]
            put(["on": "on", "year": "year", "kind": "kind"])
        case "rm":
            guard rest.count > 1 else { fail("asmo date rm ID") }
            request = ["cmd": "date-remove", "id": rest[1]]
        default: fail("asmo date add|rm … See: asmo help")
        }
    default: fail("Unknown command \"\(command)\". See: asmo help")
    }
    print(text(try send(request)))
} catch {
    fail("asmo: " + ((error as? Problem)?.message ?? error.localizedDescription))
}
