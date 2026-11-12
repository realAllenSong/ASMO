import SwiftData
import SwiftUI

@MainActor
struct ImportantDatesView: View {
    var initialRecord: ImportantDateRecord? = nil
    @Query(sort: \ImportantDateRecord.month) private var items: [ImportantDateRecord]
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.closePlannerPanel) private var closePanel
    @Environment(\.colorScheme) private var scheme
    @State private var editing: ImportantEdit?
    @State private var mode: ImportMode = .library
    @State private var pasted = ""
    @State private var batch: ImportantDateImport?
    @State private var excluded: Set<String> = []
    @State private var useGregorian: Set<String> = []
    @State private var error: String?

    private enum ImportMode { case library, paste, preview }

    var body: some View {
        ZStack {
            PlannerPanel(title: mode == .library ? String(localized: "重要日期") : String(localized: "导入重要日期"), width: 540, height: 450, close: close) {
                switch mode {
                case .library: library
                case .paste: pasteView
                case .preview: preview
                }
            } footer: {
                Button(mode == .library ? "完成" : "返回") { back() }
                    .buttonStyle(PlannerActionStyle(theme: theme))
                switch mode {
                case .library:
                    Button { editing = ImportantEdit() } label: {
                        HStack(spacing: 6) { ASMOIcon(mark: .plus, size: 14); Text("新增") }
                    }.buttonStyle(PlannerActionStyle(theme: theme, primary: true))
                case .paste:
                    Button("预览") { prepare() }.buttonStyle(PlannerActionStyle(theme: theme, primary: true))
                        .disabled(pasted.trimmed.isEmpty)
                case .preview:
                    Button("导入") { importSelected() }.buttonStyle(PlannerActionStyle(theme: theme, primary: true))
                        .disabled((batch?.entries ?? []).allSatisfy { excluded.contains($0.id) })
                }
            }
            .accessibilityHidden(editing != nil)
            if let editing {
                Color.black.opacity(0.35).ignoresSafeArea()
                ImportantDateEditor(edit: editing, save: save, delete: remove) { self.editing = nil }
            }
        }
        .onAppear {
            if let initialRecord, editing == nil { editing = ImportantEdit(record: initialRecord) }
        }
        .alert("无法保存", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(error ?? "") }
    }

    private var theme: PlannerTheme { PlannerTheme(dark: scheme == .dark) }

    private var library: some View {
        VStack(alignment: .leading, spacing: 13) {
            Button("粘贴生日或纪念日归档") { mode = .paste }
                .buttonStyle(PlannerActionStyle(theme: theme))
            Rectangle().fill(theme.line).frame(height: 1)
            Text("我的重要日期").font(.headline)
            if items.isEmpty {
                Text("生日、纪念日和你关心的节日会出现在对应日期的标题下。")
                    .font(.subheadline).foregroundStyle(theme.quiet)
            }
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(items.sorted { ($0.month, $0.day, $0.title) < ($1.month, $1.day, $1.title) }, id: \.id) { item in
                    Button {
                        editing = ImportantEdit(record: item)
                    } label: {
                        HStack(spacing: 10) {
                            ASMOIcon(mark: .calendar, size: 16).foregroundStyle(theme.accent)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.title).font(.subheadline.weight(.medium))
                                Text(item.rule.label).font(.caption).foregroundStyle(theme.quiet)
                            }
                            Spacer()
                            ASMOIcon(mark: .right, size: 12).foregroundStyle(theme.quiet)
                        }
                        .frame(minHeight: 48).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Rectangle().fill(theme.line).frame(height: 1)
                }
            }
        }
    }

    private var pasteView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("每行一条，例如「3.4: 生日」或「纪念日 2023.1.6」。")
                .font(.subheadline).foregroundStyle(theme.quiet)
            TextEditor(text: $pasted)
                .font(.body)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 200)
                .modifier(PlannerFieldStyle(theme: theme))
                .accessibilityLabel("归档原文")
                .accessibilityIdentifier("importantDatePaste")
        }
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let batch {
                Text("\(batch.entries.count) 个可导入日期").font(.headline)
                ForEach(batch.entries) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        PlannerToggle(title: entry.title, selected: Binding(get: { !excluded.contains(entry.id) }, set: { enabled in
                            if enabled { excluded.remove(entry.id) } else { excluded.insert(entry.id) }
                        }), theme: theme)
                        Text(rule(for: entry).label).font(.caption).foregroundStyle(theme.quiet).padding(.leading, 28)
                        if let alternate = entry.gregorianAlternative {
                            Menu("切换重复规则") {
                                Button(entry.rule.label) { useGregorian.remove(entry.id) }
                                Button(alternate.label) { useGregorian.insert(entry.id) }
                            }.menuIndicator(.hidden).buttonStyle(.plain).foregroundStyle(theme.accent)
                                .font(.caption).padding(.leading, 28).padding(.top, 4)
                        }
                        Rectangle().fill(theme.line).frame(height: 1)
                    }
                }
                if !batch.unparsed.isEmpty {
                    Text("未识别的原文").font(.headline)
                    Text(batch.unparsed.joined(separator: "\n")).textSelection(.enabled)
                }
            }
        }
    }

    private func close() {
        if let closePanel { closePanel() } else { dismiss() }
    }

    private func back() {
        switch mode {
        case .library: close()
        case .paste: mode = .library
        case .preview: mode = .paste
        }
    }

    private func prepare() {
        let result = ImportantDateImport.parse(pasted, calendar: CaptureClock().calendar)
        var seen = Set<String>()
        batch = ImportantDateImport(entries: result.entries.filter { seen.insert($0.id).inserted }, unparsed: result.unparsed)
        excluded = Set(items.compactMap(\.importKey))
        useGregorian = []
        mode = .preview
    }

    private func rule(for entry: ImportantDateDraft) -> ImportantDateRule {
        let rule = useGregorian.contains(entry.id) ? entry.gregorianAlternative ?? entry.rule : entry.rule
        return rule.withDefaultTimeZone(for: entry.kind)
    }

    private func importSelected() {
        guard let batch else { return }
        let storedKeys = Set(items.compactMap(\.importKey))
        for entry in batch.entries where !excluded.contains(entry.id) && !storedKeys.contains(entry.id) {
            context.insert(ImportantDateRecord(title: entry.title, kind: entry.kind, rule: rule(for: entry),
                                               original: entry.original, importKey: entry.id, alternative: entry.gregorianAlternative))
        }
        do {
            try context.save()
            pasted = ""
            mode = .library
        } catch {
            context.rollback()
            self.error = error.localizedDescription
        }
    }

    private func save(_ edit: ImportantEdit) throws {
        let record = edit.record ?? ImportantDateRecord(title: edit.title, kind: edit.kind, rule: edit.rule)
        record.title = edit.title.trimmed
        record.kind = edit.kind
        record.rule = edit.rule.withDefaultTimeZone(for: edit.kind)
        if record.modelContext == nil { context.insert(record) }
        do { try context.save() }
        catch { context.rollback(); throw error }
    }

    private func remove(_ record: ImportantDateRecord) throws {
        context.delete(record)
        do { try context.save() }
        catch { context.rollback(); throw error }
    }
}

private struct ImportantEdit: Identifiable {
    let id = UUID()
    var title = ""
    var kind: ImportantDateKind = .birthday
    var rule = ImportantDateRule(month: CaptureClock().today.month, day: CaptureClock().today.day ?? 1)
    var record: ImportantDateRecord?

    init(record: ImportantDateRecord? = nil) {
        self.record = record
        if let record {
            title = record.title
            kind = record.kind
            rule = record.rule
        }
    }
}

@MainActor
private struct ImportantDateEditor: View {
    @State var edit: ImportantEdit
    let save: (ImportantEdit) throws -> Void
    let delete: (ImportantDateRecord) throws -> Void
    let close: () -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var confirming = false
    @State private var error: String?

    var body: some View {
        PlannerPanel(title: edit.record == nil ? String(localized: "新增重要日期") : String(localized: "编辑重要日期"),
                     width: 455, height: 390, close: close) {
            VStack(alignment: .leading, spacing: 12) {
                TextField("名称", text: $edit.title).modifier(PlannerFieldStyle(theme: theme))
                HStack {
                    Menu(edit.kind.label) {
                        ForEach(ImportantDateKind.allCases, id: \.self) { kind in Button(kind.label) { edit.kind = kind } }
                    }.buttonStyle(PlannerActionStyle(theme: theme))
                    Menu(edit.rule.system.label) {
                        ForEach(ImportantDateSystem.allCases, id: \.self) { system in
                            Button(system.label) { edit.rule.system = system }
                        }
                    }.buttonStyle(PlannerActionStyle(theme: theme))
                }
                if edit.rule.system == .gregorian {
                    PlannerToggle(title: "每年重复", selected: Binding(get: { edit.rule.year == nil }, set: { repeats in
                        edit.rule.year = repeats ? nil : CaptureClock().today.year
                    }), theme: theme)
                    if edit.rule.year != nil {
                        Stepper(String(localized: "\(String(edit.rule.year ?? 2026)) 年"), value: Binding(get: { edit.rule.year ?? 2026 },
                                                                                     set: { edit.rule.year = $0 }), in: 1900...2200)
                    }
                }
                HStack(spacing: 14) {
                    Stepper(String(localized: "\(edit.rule.month) 月"), value: $edit.rule.month, in: 1...12)
                    Stepper(String(localized: "\(edit.rule.day) 日"), value: $edit.rule.day, in: 1...(edit.rule.system == .lunar ? 30 : 31))
                }
                DesktopOccasionZonePicker(selection: $edit.rule.timeZoneID, theme: theme, isBirthday: edit.kind == .birthday)
                if let record = edit.record, !record.original.isEmpty {
                    Text("原文").font(.caption).foregroundStyle(theme.quiet)
                    Text(record.original).font(.subheadline).textSelection(.enabled)
                    if let month = record.alternativeMonth, let day = record.alternativeDay, edit.rule.system == .lunar {
                        Button("使用原文中的公历 \(month) 月 \(day) 日") {
                            edit.rule = ImportantDateRule(month: month, day: day, timeZoneID: edit.rule.timeZoneID)
                        }.buttonStyle(.plain).foregroundStyle(theme.accent)
                    }
                }
                if edit.record != nil {
                    Button("删除重要日期", role: .destructive) { confirming = true }
                        .buttonStyle(.plain).foregroundStyle(.red)
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
        } footer: {
            Button("取消", action: close).buttonStyle(PlannerActionStyle(theme: theme))
            Button("保存") { perform { try save(edit) } }.buttonStyle(PlannerActionStyle(theme: theme, primary: true))
                .disabled(edit.title.trimmed.isEmpty || !edit.rule.isValid(calendar: CaptureClock().calendar))
        }
        .onChange(of: edit.rule.system) { _, system in
            if system == .lunar {
                edit.rule.year = nil
                edit.rule.day = min(edit.rule.day, 30)
            }
        }
        .confirmationDialog("删除这个重要日期？", isPresented: $confirming, titleVisibility: .visible) {
            if let record = edit.record { Button("删除", role: .destructive) { perform { try delete(record) } } }
        }
    }

    private var theme: PlannerTheme { PlannerTheme(dark: scheme == .dark) }

    private func perform(_ action: () throws -> Void) {
        do { try action(); close() }
        catch { self.error = error.localizedDescription }
    }
}
