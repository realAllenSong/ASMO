import SwiftData
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct ArchiveView: View {
    let archives: [ArchiveDocument]
    let localTasks: [TaskRecord]
    let reminders: [SystemTask]
    let dayNotes: [DayNote]
    var initialDocument: ArchiveDocument? = nil
    var initialDate: PlanDate? = nil
    var initialUnplaced = false
    @Environment(\.closePlannerPanel) private var closePanel
    @Environment(\.colorScheme) private var scheme
    @State private var reading: ArchiveDocument?
    @Environment(\.modelContext) private var context
    @Query private var receipts: [ImportReceipt]
    @Query private var importantDates: [ImportantDateRecord]
    @Query private var journalEdits: [JournalArchiveEdit]
    @State private var importing = false
    @State private var exporting = false
    @State private var document = ExportFile(text: "")
    @State private var exportType: UTType = .plainText
    @State private var exportName = "逐日.md"
    @State private var pasted = ""
    @State private var defaultYear = CaptureClock().today.year
    @State private var fileName = ""
    @State private var raw = ""
    @State private var prepared: ArchiveImport?
    @State private var choices: Set<String> = []
    @State private var editingPlans = false
    @State private var editedPlans = ""
    @FocusState private var editingPlanFocused: Bool
    @State private var error: String?
    @State private var notice = ""

    var body: some View {
        PlannerPanel(title: reading?.title ?? (editingPlans ? String(localized: "调整待办清单") : prepared == nil ? String(localized: "石墨归档") : String(localized: "导入预览")),
                     width: 640, height: 490, close: close) {
            if let reading { ArchiveReader(document: reading, initialDate: initialDocument == reading ? initialDate : nil,
                                          initialUnplaced: initialDocument == reading && initialUnplaced).id(reading.persistentModelID) }
            else if let prepared {
                if editingPlans { editPreview(prepared) } else { preview(prepared) }
            }
            else { library }
        } footer: {
            if let prepared {
                importActions(prepared)
            } else if reading != nil {
                Button("返回归档") { reading = nil }.buttonStyle(PlannerActionStyle(theme: theme))
            } else {
                Menu("导出") {
                    Button("Markdown") { export(json: false) }
                    Button("JSON") { export(json: true) }
                }.buttonStyle(PlannerActionStyle(theme: theme))
                Button("完成", action: close).buttonStyle(PlannerActionStyle(theme: theme, primary: true))
            }
        }
        .onAppear { if reading == nil { reading = initialDocument } }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText, .text]) { result in
            do {
                let url = try result.get()
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let contents = try String(contentsOf: url, encoding: .utf8)
                prepare(contents, title: url.deletingPathExtension().lastPathComponent)
            } catch { self.error = error.localizedDescription }
        }
        .fileExporter(isPresented: $exporting, document: document, contentType: exportType, defaultFilename: exportName) {
            if case .failure(let error) = $0 { self.error = error.localizedDescription }
        }
        .alert("归档", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(error ?? "") }
    }

    private var theme: PlannerTheme { PlannerTheme(dark: scheme == .dark) }

    private func close() { closePanel?() }

    private var library: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("导入").font(.headline)
            Stepper(String(localized: "无年份的日期使用 \(String(defaultYear)) 年"), value: $defaultYear, in: 1900...2200)
                .font(.subheadline)
            Button("选择 UTF-8 文本文件…") { importing = true }.buttonStyle(PlannerActionStyle(theme: theme))
            TextField("也可以粘贴带日期的文本", text: $pasted, axis: .vertical).lineLimit(3...7)
                .modifier(PlannerFieldStyle(theme: theme)).accessibilityIdentifier("archivePaste")
            Button("预览粘贴内容") { prepare(pasted, title: "粘贴归档") }
                .buttonStyle(PlannerActionStyle(theme: theme)).disabled(pasted.trimmed.isEmpty)
            if !notice.isEmpty { Text(notice).font(.footnote).foregroundStyle(theme.quiet) }
            Rectangle().fill(theme.line).frame(height: 1)
            Text("原文").font(.headline)
            if archives.isEmpty { Text("归档后，原文会保存在这里。").foregroundStyle(theme.quiet) }
            ForEach(archives, id: \.persistentModelID) { item in
                HStack {
                    Button(item.title) { reading = item }.buttonStyle(.plain)
                    Spacer()
                    Button("选入待办") {
                        defaultYear = item.defaultYear
                        prepare(item.raw, title: item.title)
                    }.buttonStyle(PlannerActionStyle(theme: theme))
                        .accessibilityLabel("选入待办：\(item.title)")
                        .accessibilityIdentifier("archivePromote-\(item.digest)")
                }
            }
        }
    }

    private func preview(_ item: ArchiveImport) -> some View {
        let candidates = candidates(in: item)
        return VStack(alignment: .leading, spacing: 11) {
            Text(fileName).font(.headline)
            Text("\(item.entries.filter { $0.schedule != nil }.count) 个日期段 · \(item.entries.filter { $0.schedule == nil }.count) 段待归位")
                .font(.caption).foregroundStyle(theme.quiet)
            Rectangle().fill(theme.line).frame(height: 1)
            Text("选入待办的未来计划").font(.headline)
            if candidates.isEmpty {
                Text("没有尚未导入的未来计划。").foregroundStyle(theme.quiet)
            } else {
                HStack(spacing: 8) {
                    Button(choices.count == candidates.count ? "取消全选" : "全选") {
                        choices = choices.count == candidates.count ? [] : Set(candidates.map(\.id))
                    }
                    .buttonStyle(PlannerActionStyle(theme: theme))
                    Button("调整清单…") {
                        let selected = candidates.filter { choices.contains($0.id) }
                        editedPlans = ArchivePlanEdits.initialText(for: selected.isEmpty ? candidates : selected)
                        editingPlans = true
                    }
                    .buttonStyle(PlannerActionStyle(theme: theme))
                }
            }
            ForEach(candidates) { entry in
                PlannerToggle(title: entry.body, selected: Binding(get: { choices.contains(entry.id) }, set: {
                    if $0 { choices.insert(entry.id) } else { choices.remove(entry.id) }
                }), theme: theme)
                Text(entry.schedule?.label ?? "").font(.caption).foregroundStyle(theme.quiet).padding(.leading, 28)
            }
        }
    }

    private func candidates(in item: ArchiveImport) -> [ArchiveEntry] {
        let known = Set(receipts.map(\.key))
        let clock = CaptureClock()
        return item.future(from: clock.today).filter { entry in
            guard !known.contains(entry.id), let date = entry.schedule else { return false }
            return !importantDates.contains {
                $0.title.trimmed.caseInsensitiveCompare(entry.body.trimmed) == .orderedSame &&
                $0.rule.matches(date, calendar: clock.calendar)
            }
        }
    }

    private func editPreview(_ item: ArchiveImport) -> some View {
        let result = ArchivePlanEdits.validate(editedPlans, entries: candidates(in: item), clock: CaptureClock())
        return VStack(alignment: .leading, spacing: 11) {
            Text("从原文挑出还要做的事").font(.headline)
            Text("每行一条，保留行首的日期或月份。要拆成多条，就重复同一个日期。")
                .font(.subheadline).foregroundStyle(theme.quiet)
            TextEditor(text: $editedPlans)
                .focused($editingPlanFocused)
                .task {
                    try? await Task.sleep(for: .milliseconds(45))
                    if !Task.isCancelled && editingPlans { editingPlanFocused = true }
                }
                .font(.subheadline)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 230)
                .modifier(PlannerFieldStyle(theme: theme))
                .accessibilityLabel("编辑待办清单")
                .accessibilityIdentifier("archiveEditedPlans")
            if result.invalidLines.isEmpty {
                Text("将新增 \(newCount(result.drafts)) 条待办 · 石墨原文会完整保留")
                    .font(.caption).foregroundStyle(theme.accent)
            } else {
                Text("第 \(result.invalidLines.map(String.init).joined(separator: "、")) 行的日期或内容有误。请保留原清单中的日期。")
                    .font(.caption).foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private func importActions(_ item: ArchiveImport) -> some View {
        let known = archives.contains { $0.digest == item.id && $0.defaultYear == defaultYear }
        if editingPlans {
            let result = ArchivePlanEdits.validate(editedPlans, entries: candidates(in: item), clock: CaptureClock())
            Button("返回预览") { editingPlans = false }.buttonStyle(PlannerActionStyle(theme: theme))
            Button("新增 \(newCount(result.drafts)) 条待办") { commit(item, drafts: result.drafts) }
                .buttonStyle(PlannerActionStyle(theme: theme, primary: true))
                .disabled(!result.invalidLines.isEmpty || result.drafts.isEmpty)
        } else {
            let selected = candidates(in: item).filter { choices.contains($0.id) }
            Button("返回") { prepared = nil }.buttonStyle(PlannerActionStyle(theme: theme))
            Button(selected.isEmpty ? (known ? "完成" : "仅保存原文") : "选入 \(selected.count) 条计划") {
                let clock = CaptureClock()
                let drafts = selected.compactMap { entry -> ArchivePlanDraft? in
                    guard let date = entry.schedule else { return nil }
                    let title = entry.body.components(separatedBy: .newlines).first ?? entry.body
                    return ArchivePlanDraft.make(title: title, date: date, sources: [entry], clock: clock,
                                                 note: title == entry.body ? "" : entry.body)
                }
                commit(item, drafts: drafts)
            }
            .buttonStyle(PlannerActionStyle(theme: theme, primary: true))
        }
    }

    private var knownTaskKeys: Set<String> {
        Set(localTasks.compactMap { task in
            task.schedule.map { ArchivePlanDraft.duplicateKey(title: task.title, schedule: $0, endMinute: task.endMinute) }
        })
    }

    private func newCount(_ drafts: [ArchivePlanDraft]) -> Int {
        let existing = knownTaskKeys
        return Set(drafts.map(\.duplicateKey)).subtracting(existing).count
    }

    private func prepare(_ contents: String, title: String) {
        let item = ArchiveParser.parse(contents, defaultYear: defaultYear, clock: CaptureClock())
        raw = contents
        fileName = title
        choices = []
        editedPlans = ""
        editingPlans = false
        prepared = item
    }

    private func commit(_ item: ArchiveImport, drafts: [ArchivePlanDraft]) {
        var known = Set(receipts.map(\.key))
        var taskKeys = knownTaskKeys
        let existingArchive = archives.contains { $0.digest == item.id && $0.defaultYear == defaultYear }
        if !existingArchive {
            context.insert(ArchiveDocument(digest: item.id, title: fileName, raw: raw, defaultYear: defaultYear))
        }
        let candidateIDs = Set(candidates(in: item).map(\.id))
        var inserted = 0
        var processed = Set<String>()
        for draft in drafts where draft.sourceIDs.allSatisfy(candidateIDs.contains) {
            if taskKeys.insert(draft.duplicateKey).inserted {
                let task = TaskRecord(title: draft.title, note: draft.note, schedule: draft.schedule,
                                      importKey: draft.sourceIDs.first, endMinute: draft.endMinute)
                task.sourceText = draft.sourceText == draft.title ? nil : draft.sourceText
                context.insert(task)
                inserted += 1
            }
            processed.formUnion(draft.sourceIDs)
        }
        for key in processed where known.insert(key).inserted { context.insert(ImportReceipt(key: key)) }
        do {
            try context.save()
            notice = existingArchive && inserted == 0 ? String(localized: "原文已存在，没有新增重复待办。") : String(localized: "已保留原文，新增 \(inserted) 条待办。")
            editingPlans = false
            prepared = nil
            pasted = ""
        } catch {
            context.rollback()
            self.error = error.localizedDescription
        }
    }

    private func export(json: Bool) {
        let tasks = localTasks.map { Snapshot.Task(title: $0.title, note: $0.note, schedule: $0.schedule,
                                                   endMinute: $0.endMinute, complete: $0.completed, reminder: $0.pendingReminder,
                                                   source: $0.sourceText) } +
                    reminders.map { Snapshot.Task(title: $0.title, note: $0.note, schedule: $0.schedule,
                                                   endMinute: $0.endMinute, complete: $0.completed, reminder: $0.alertAt, source: nil) }
        let snapshot = Snapshot(tasks: tasks, notes: dayNotes.map { Snapshot.Note(day: $0.dayKey, body: $0.body) },
                                archives: archives.map { Snapshot.Archive(title: $0.title, year: $0.defaultYear, original: $0.raw) },
                                journalEdits: journalEdits.map { Snapshot.JournalEdit(recordKey: $0.recordKey, body: $0.body) },
                                importantDates: importantDates.map {
                                    Snapshot.Important(title: $0.title, kind: $0.kind, rule: $0.rule, original: $0.original)
                                })
        do {
            if json {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                encoder.dateEncodingStrategy = .iso8601
                document = ExportFile(data: try encoder.encode(snapshot))
                exportType = .json
            } else {
                document = ExportFile(text: snapshot.markdown)
                exportType = UTType(filenameExtension: "md", conformingTo: .plainText) ?? .plainText
            }
            exportName = json ? "逐日.json" : "逐日.md"
            exporting = true
        } catch { self.error = error.localizedDescription }
    }
}

private struct ArchiveReader: View {
    let document: ArchiveDocument
    @State private var search = ""
    @State private var entries: [ArchiveEntry] = []
    @State private var loaded = false
    @State private var original = false
    @State private var orphans = false

    @Environment(\.colorScheme) private var scheme

    init(document: ArchiveDocument, initialDate: PlanDate? = nil, initialUnplaced: Bool = false) {
        self.document = document
        _search = State(initialValue: initialDate?.key ?? "")
        _orphans = State(initialValue: initialUnplaced)
    }

    var body: some View {
        let theme = PlannerTheme(dark: scheme == .dark)
        VStack(alignment: .leading, spacing: 13) {
            Button(original ? "按日期查看" : "查看原文") { original.toggle() }
                .buttonStyle(PlannerActionStyle(theme: theme))
            if original {
                Text(document.raw).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField("搜索日期或原文", text: $search).modifier(PlannerFieldStyle(theme: theme))
                PlannerToggle(title: "显示待归位段落", selected: $orphans, theme: theme)
                let matching = entries.filter { entry in
                    orphans == (entry.schedule == nil) && !entry.body.trimmed.isEmpty &&
                    ArchivePlanEdits.matches(search, entry: entry)
                }
                if !loaded {
                    ProgressView(String(localized: "正在读取归档…"))
                } else if matching.isEmpty {
                    Text("没有符合条件的记录。").font(.subheadline).foregroundStyle(theme.quiet)
                }
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(matching) { entry in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(entry.schedule?.label ?? "待归位").font(.caption).foregroundStyle(theme.quiet)
                            Text(entry.body.isEmpty ? "（空白）" : entry.body).textSelection(.enabled)
                        }
                        Rectangle().fill(theme.line).frame(height: 1)
                    }
                }
            }
        }
        .task {
            let raw = document.raw
            let year = document.defaultYear
            entries = await Task.detached { ArchiveParser.parse(raw, defaultYear: year, clock: CaptureClock()).entries }.value
            loaded = true
        }
    }
}

private struct Snapshot: Encodable {
    struct Task: Encodable {
        let title: String
        let note: String
        let schedule: PlanDate?
        let endMinute: Int?
        let complete: Bool
        let reminder: Date?
        let source: String?
    }
    struct Note: Encodable { let day: String; let body: String }
    struct Archive: Encodable { let title: String; let year: Int; let original: String }
    struct Important: Encodable {
        let title: String
        let kind: ImportantDateKind
        let rule: ImportantDateRule
        let original: String
    }
    struct JournalEdit: Encodable { let recordKey: String; let body: String }
    let tasks: [Task]
    let notes: [Note]
    let archives: [Archive]
    let journalEdits: [JournalEdit]
    let importantDates: [Important]

    var markdown: String {
        let taskLines = tasks.map { task in
            let end = task.endMinute.map { minute in
                String(format: "–%02d:%02d", (minute / 60) % 24, minute % 60) +
                    (minute >= 1440 ? "（+\(minute / 1440) 天）" : "")
            } ?? ""
            let prefix = "- [\(task.complete ? "x" : " ")] \(task.schedule.map { $0.label + end + " · " } ?? "")\(task.title)"
            let alert = task.reminder.map { "\n  提醒：\($0.ISO8601Format())" } ?? ""
            let note = task.note.isEmpty ? "" : "\n  \(task.note.replacingOccurrences(of: "\n", with: "\n  "))"
            return prefix + alert + note
        }
        let noteLines = notes.map { "### \($0.day)\n\n\($0.body)" }
        let archiveLines = archives.map { "### \($0.title)\n\n\($0.original)" }
        let importantLines = importantDates.map { "- \($0.rule.label) · \($0.title)" }
        let sections = ["# 逐日", "## 待办", taskLines.joined(separator: "\n"),
                        "## 日备注", noteLines.joined(separator: "\n\n"),
                        "## 重要日期", importantLines.joined(separator: "\n"),
                        "## 石墨归档", archiveLines.joined(separator: "\n\n")]
        let edits = journalEdits.map { "### \($0.recordKey)\n\n\($0.body)" }
        let adjustment = edits.isEmpty ? [] : ["## 逐日记录修订", edits.joined(separator: "\n\n")]
        return (sections + adjustment).joined(separator: "\n\n") + "\n"
    }
}

private struct ExportFile: FileDocument {
    static let readableContentTypes: [UTType] = [.plainText, .json]
    let data: Data
    init(text: String) { data = Data(text.utf8) }
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
