import SwiftUI
import PhotosUI
import QuickLook
import UniformTypeIdentifiers

// MARK: - الدردشة

struct ChatView: View {
    @EnvironmentObject var app: AppState
    @State private var text = ""
    @State private var showImporter = false
    @State private var importFolder = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                PeersBar()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(app.messages) { m in
                                MessageRow(m: m).id(m.id)
                            }
                        }
                        .padding(12)
                    }
                    .onChange(of: app.messages.count) { _ in
                        if let last = app.messages.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }
                composer
            }
            .navigationTitle("الشلّة")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(firstRun: false).environmentObject(app)
                    .environment(\.layoutDirection, .rightToLeft)
            }
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: importFolder ? [.folder] : [.item],
                          allowsMultipleSelection: true) { r in
                if case .success(let urls) = r { app.startSend(urls: urls) }
            }
            .onChange(of: photoItems) { items in
                guard !items.isEmpty else { return }
                Task {
                    var urls: [URL] = []
                    for it in items {
                        if let f = try? await it.loadTransferable(type: PickedMedia.self) { urls.append(f.url) }
                    }
                    photoItems = []
                    app.startSend(urls: urls)
                }
            }
            .overlay(alignment: .top) {
                if let t = app.toast {
                    Text(t).font(.footnote).padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.easeInOut, value: app.toast)
        }
    }

    private var composer: some View {
        HStack(spacing: 8) {
            Menu {
                PhotosPicker(selection: $photoItems, matching: .any(of: [.videos, .images]),
                             preferredItemEncoding: .current) {
                    Label("صور وفيديوهات", systemImage: "photo.on.rectangle")
                }
                Button { importFolder = false; showImporter = true } label: {
                    Label("ملفات", systemImage: "doc")
                }
                Button { importFolder = true; showImporter = true } label: {
                    Label("مجلد", systemImage: "folder")
                }
            } label: {
                Image(systemName: "paperclip.circle.fill").font(.system(size: 32))
            }
            TextField("اكتب رسالة", text: $text, axis: .vertical)
                .lineLimit(1...4)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
            Button {
                app.sendText(text)
                text = ""
            } label: {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 32))
            }
            .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(.bar)
    }
}

struct PeersBar: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("السيرفر", app.serverUp ? .green : .red)
                ForEach(app.peers.values.sorted { $0.name < $1.name }) { p in
                    chip(p.name, color(p.state))
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
        .background(Color(.systemBackground))
    }
    private func color(_ s: String) -> Color {
        switch s {
        case "connected": return .green
        case "failed", "closed": return .red
        default: return .orange
        }
    }
    private func chip(_ t: String, _ c: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(c).frame(width: 8, height: 8)
            Text(t).font(.caption)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Color(.secondarySystemBackground), in: Capsule())
    }
}

struct MessageRow: View {
    let m: ChatMessage
    var body: some View {
        // الواجهة RTL: leading = اليمين، ورسائلي تكون يمين
        let mine = m.outgoing
        VStack(alignment: mine ? .leading : .trailing, spacing: 3) {
            if !mine {
                Text(m.name).font(.caption2).foregroundColor(.secondary)
            }
            if let b = m.batch {
                FileCard(m: m, b: b)
            } else {
                Text(m.text ?? "")
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(mine ? Color.accentColor : Color(.secondarySystemBackground))
                    .foregroundColor(mine ? Color.white : Color.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: mine ? .leading : .trailing)
    }
}

// MARK: - بطاقة الملف

struct FileCard: View {
    let m: ChatMessage
    let b: BatchInfo
    @EnvironmentObject var app: AppState
    @State private var preview: URL?

    private var live: TransferState? { app.progress[m.id] }
    private var done: Bool { live?.finished ?? (m.status == "done") }
    private var failed: Bool { live?.failed ?? (m.status == "failed") }
    private var fraction: Double {
        if let l = live { return min(1, Double(l.bytes) / Double(max(1, b.size))) }
        return done ? 1 : 0
    }

    private var icon: String {
        switch b.kind {
        case "video": return "film"
        case "image": return "photo"
        case "folder": return "folder.fill"
        default: return "doc.fill"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.title2).foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(b.name).font(.subheadline.weight(.semibold)).lineLimit(2)
                    Text(subtitle).font(.caption).foregroundColor(.secondary)
                }
            }
            if !done && !failed {
                ProgressView(value: fraction)
                HStack {
                    Text("\(Int(fraction * 100))%")
                    Spacer()
                    if let s = live?.speed, s > 0 { Text(Fmt.size(Int64(s)) + "/ث") }
                }
                .font(.caption2).foregroundColor(.secondary)
            } else if failed {
                Text(live?.note.isEmpty == false ? live!.note : "ما اكتمل النقل").font(.caption).foregroundColor(.red)
            } else if let n = live?.note, !n.isEmpty {
                Text(n).font(.caption).foregroundColor(.orange)
            }
            if done, !m.outgoing, let url = app.fileURL(for: m) {
                actions(url)
            }
        }
        .padding(12)
        .frame(maxWidth: 300, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
        .quickLookPreview($preview)
    }

    private var subtitle: String {
        var s = Fmt.size(b.size)
        if b.isFolder { s += " • \(b.count) ملف" }
        if m.outgoing { s += done ? " • أُرسل" : "" } else { s += done ? " • وصل" : "" }
        return s
    }

    @ViewBuilder
    private func actions(_ url: URL) -> some View {
        HStack(spacing: 14) {
            if !b.isFolder {
                ShareLink(item: url) { Label("مشاركة", systemImage: "square.and.arrow.up") }
                Button { preview = url } label: { Label("فتح", systemImage: "eye") }
            }
            if b.kind == "video" || b.kind == "image" {
                Button { app.saveToPhotos(url, video: b.kind == "video") } label: {
                    Label("للصور", systemImage: "photo.badge.plus")
                }
            }
            Button { app.openInFiles(url) } label: { Label("الملفات", systemImage: "folder") }
        }
        .font(.caption)
        .labelStyle(.titleAndIcon)
    }
}

// MARK: - اختيار الصور والفيديوهات بالجودة الأصلية

struct PickedMedia: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { m in
            SentTransferredFile(m.url)
        } importing: { r in
            PickedMedia(url: try Self.copy(r.file))
        }
        FileRepresentation(contentType: .image) { m in
            SentTransferredFile(m.url)
        } importing: { r in
            PickedMedia(url: try Self.copy(r.file))
        }
    }
    static func copy(_ src: URL) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dst = dir.appendingPathComponent(src.lastPathComponent)
        try FileManager.default.copyItem(at: src, to: dst)
        return dst
    }
}

// MARK: - الإعدادات

struct SettingsView: View {
    let firstRun: Bool
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var showTurn = false

    var body: some View {
        NavigationStack {
            Form {
                Section("أنت") {
                    TextField("اسمك", text: $app.myName)
                }
                Section {
                    TextField("رابط السيرفر (workers.dev)", text: $app.server)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .environment(\.layoutDirection, .leftToRight)
                    HStack {
                        TextField("كود الغرفة", text: $app.room)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .environment(\.layoutDirection, .leftToRight)
                        Button("توليد") { app.room = Self.randomCode() }
                    }
                } header: {
                    Text("الغرفة")
                } footer: {
                    Text("كل أصدقائك يكتبون نفس الرابط ونفس الكود.")
                }
                if !app.room.isEmpty && !app.server.isEmpty {
                    Section {
                        ShareLink(item: "الشلّة\nالسيرفر: \(app.server)\nالكود: \(app.room)") {
                            Label("شارك بيانات الدعوة", systemImage: "person.badge.plus")
                        }
                    }
                }
                Section {
                    Toggle("إبقاء التطبيق شغّال بالخلفية", isOn: $app.keepAlive)
                } footer: {
                    Text("iOS يوقف التطبيقات بالخلفية. هذا الخيار يخليه يستقبل ويرسل حتى لو طلعت منه. يستهلك بطارية أكثر.")
                }
                Section {
                    DisclosureGroup("خيارات متقدمة (TURN)", isExpanded: $showTurn) {
                        TextField("turn:host:3478", text: $app.turnURL)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .environment(\.layoutDirection, .leftToRight)
                        TextField("المستخدم", text: $app.turnUser)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        SecureField("كلمة السر", text: $app.turnPass)
                    }
                } footer: {
                    Text("تحتاجه فقط لو الاتصال المباشر ما اشتغل بين شبكتين (بعض شبكات الجوال).")
                }
                Section {
                    Button(firstRun ? "حفظ وابدأ" : "حفظ وإعادة الاتصال") {
                        app.reconnect()
                        if !firstRun { dismiss() }
                    }
                    .disabled(app.myName.isEmpty || app.room.count < 6 || app.server.isEmpty)
                }
            }
            .navigationTitle(firstRun ? "إعداد الشلّة" : "الإعدادات")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    static func randomCode() -> String {
        let chars = Array("abcdefghijkmnpqrstuvwxyz23456789")
        return String((0..<14).map { _ in chars.randomElement()! })
    }
}
