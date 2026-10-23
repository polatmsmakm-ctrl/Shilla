import SwiftUI
import PhotosUI
import QuickLook
import UniformTypeIdentifiers

// MARK: - الثيم

enum Theme {
    static let brand = LinearGradient(
        colors: [Color(red: 0.30, green: 0.42, blue: 1.0), Color(red: 0.60, green: 0.30, blue: 0.96)],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    static func avatar(_ name: String) -> LinearGradient {
        var h = 0
        for s in name.unicodeScalars { h = (h &* 31 &+ Int(s.value)) & 0xFFFF }
        let hue = Double(h % 360) / 360
        return LinearGradient(
            colors: [Color(hue: hue, saturation: 0.55, brightness: 0.96),
                     Color(hue: (hue + 0.08).truncatingRemainder(dividingBy: 1), saturation: 0.75, brightness: 0.78)],
            startPoint: .top, endPoint: .bottom)
    }
}

struct Avatar: View {
    let name: String
    var size: CGFloat = 48
    var online: Bool? = nil
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Circle().fill(Theme.avatar(name))
                .frame(width: size, height: size)
                .overlay(
                    Text(String(name.prefix(1)).uppercased())
                        .font(.system(size: size * 0.42, weight: .bold, design: .rounded))
                        .foregroundColor(.white))
            if let on = online {
                Circle().fill(on ? Color.green : Color.gray)
                    .frame(width: size * 0.28, height: size * 0.28)
                    .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
            }
        }
    }
}

// MARK: - الترحيب

struct WelcomeView: View {
    @EnvironmentObject var app: AppState
    @State private var name = ""
    @State private var error = false

    var body: some View {
        ZStack {
            Theme.brand.ignoresSafeArea()
            VStack(spacing: 22) {
                Spacer()
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(.white)
                    .frame(width: 96, height: 96)
                    .overlay(
                        Image(systemName: "paperplane.fill")
                            .font(.system(size: 42))
                            .foregroundStyle(Theme.brand))
                    .shadow(color: .black.opacity(0.2), radius: 16, y: 8)
                Text("الشلّة").font(.system(size: 40, weight: .heavy, design: .rounded)).foregroundColor(.white)
                Text("رسائل وملفات ضخمة بأقصى سرعة\nمباشرة بينك وبين أصدقائك")
                    .multilineTextAlignment(.center)
                    .foregroundColor(.white.opacity(0.9))
                Spacer()
                VStack(spacing: 12) {
                    HStack {
                        Text("@").foregroundColor(.secondary)
                        TextField("اسم المستخدم", text: $name)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .environment(\.layoutDirection, .leftToRight)
                            .onChange(of: name) { v in
                                let f = String(v.lowercased().filter { "abcdefghijklmnopqrstuvwxyz0123456789_".contains($0) }.prefix(20))
                                if f != v { name = f }
                                error = false
                            }
                    }
                    .padding(14)
                    .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 14))
                    Text(error ? "اكتب من 3 إلى 20 حرف إنجليزي أو أرقام" : "اسم ثابت يعرفك فيه أصدقاؤك، ما يحتاج كود")
                        .font(.footnote)
                        .foregroundColor(error ? Color.yellow : Color.white.opacity(0.85))
                    Button {
                        if !app.register(name) { error = true }
                    } label: {
                        Text("ابدأ").font(.headline).frame(maxWidth: .infinity).padding(14)
                            .background(Color.white, in: RoundedRectangle(cornerRadius: 14))
                            .foregroundStyle(Theme.brand)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 30)
            }
        }
    }
}

// MARK: - القائمة الرئيسية

struct HomeView: View {
    @EnvironmentObject var app: AppState
    @State private var showAdd = false
    @State private var showSettings = false

    private var sorted: [Friend] {
        app.friends.sorted { (app.last($0.id)?.ts ?? $0.addedAt) > (app.last($1.id)?.ts ?? $1.addedAt) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !app.mqttUp {
                    HStack(spacing: 8) {
                        ProgressView().scaleEffect(0.8)
                        Text("جاري الاتصال…").font(.footnote)
                    }
                    .frame(maxWidth: .infinity).padding(8)
                    .background(Color.orange.opacity(0.18))
                }
                if app.friends.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(sorted) { f in
                            NavigationLink(value: f.id) { ChatRow(friend: f) }
                                .swipeActions {
                                    Button(role: .destructive) { app.removeFriend(f.id) } label: {
                                        Label("حذف", systemImage: "trash")
                                    }
                                }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("الشلّة")
            .navigationDestination(for: String.self) { ChatView(peer: $0) }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape.fill") }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showAdd = true } label: { Image(systemName: "person.badge.plus") }
                }
            }
            .sheet(isPresented: $showAdd) { AddFriendSheet().environmentObject(app).environment(\.layoutDirection, .rightToLeft) }
            .sheet(isPresented: $showSettings) { SettingsView().environmentObject(app).environment(\.layoutDirection, .rightToLeft) }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "person.2.fill").font(.system(size: 54)).foregroundStyle(Theme.brand)
            Text("ما عندك أصدقاء بعد").font(.title3.bold())
            Text("اطلب من صديقك اسم المستخدم حقه وضيفه.\nاسمك أنت: @\(app.username)")
                .multilineTextAlignment(.center).foregroundColor(.secondary)
            Button { showAdd = true } label: {
                Label("إضافة صديق", systemImage: "person.badge.plus")
                    .padding(.horizontal, 22).padding(.vertical, 12)
                    .background(Theme.brand, in: Capsule()).foregroundColor(.white)
            }
            Spacer()
        }
        .padding()
    }
}

struct ChatRow: View {
    let friend: Friend
    @EnvironmentObject var app: AppState

    var body: some View {
        let last = app.last(friend.id)
        let unread = app.unread(friend.id)
        HStack(spacing: 12) {
            Avatar(name: friend.id, size: 52, online: app.online[friend.id] ?? false)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("@" + friend.id).font(.headline)
                    Spacer()
                    if let l = last { Text(Fmt.time(l.ts)).font(.caption).foregroundColor(.secondary) }
                }
                HStack {
                    Text(preview(last)).font(.subheadline).foregroundColor(.secondary).lineLimit(1)
                    Spacer()
                    if unread > 0 {
                        Text("\(unread)").font(.caption.bold()).foregroundColor(.white)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Theme.brand, in: Capsule())
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func preview(_ m: ChatMessage?) -> String {
        guard let m else { return "ابدأ المحادثة" }
        if let b = m.batch { return "📎 " + b.name }
        return m.text ?? ""
    }
}

struct AddFriendSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var error = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text("@").foregroundColor(.secondary)
                        TextField("اسم المستخدم", text: $name)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .environment(\.layoutDirection, .leftToRight)
                    }
                } footer: {
                    Text(error ? "الاسم غير صحيح" : "اكتب اسم المستخدم اللي أعطاك إياه صديقك.")
                        .foregroundColor(error ? .red : .secondary)
                }
                Section {
                    Button("إضافة") {
                        if app.addFriend(name) { dismiss() } else { error = true }
                    }
                }
            }
            .navigationTitle("إضافة صديق")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium])
    }
}

// MARK: - المحادثة

struct ChatView: View {
    let peer: String
    @EnvironmentObject var app: AppState
    @State private var text = ""
    @State private var showImporter = false
    @State private var importFolder = false
    @State private var photoItems: [PhotosPickerItem] = []

    private var msgs: [ChatMessage] { app.chat(peer) }
    private var isOnline: Bool { app.online[peer] ?? false }

    var body: some View {
        VStack(spacing: 0) {
            statusBanner
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(msgs) { m in
                            Bubble(m: m).id(m.id)
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: msgs.count) { _ in
                    app.markRead(peer)
                    if let last = msgs.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
                .onAppear {
                    if let last = msgs.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            composer
        }
        .background(Color(.systemGroupedBackground))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 8) {
                    Avatar(name: peer, size: 32)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("@" + peer).font(.subheadline.bold())
                        Text(statusText).font(.caption2).foregroundColor(app.isDirect(peer) ? .green : .secondary)
                    }
                }
            }
        }
        .onAppear { app.activeChat = peer; app.markRead(peer) }
        .onDisappear { if app.activeChat == peer { app.activeChat = nil } }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: importFolder ? [.folder] : [.item],
                      allowsMultipleSelection: true) { r in
            if case .success(let urls) = r { app.startSend(urls: urls, to: peer) }
        }
        .onChange(of: photoItems) { items in
            guard !items.isEmpty else { return }
            Task {
                var urls: [URL] = []
                for it in items {
                    if let f = try? await it.loadTransferable(type: PickedMedia.self) { urls.append(f.url) }
                }
                photoItems = []
                app.startSend(urls: urls, to: peer)
            }
        }
    }

    private var statusText: String {
        if app.isDirect(peer) { return "اتصال مباشر ⚡" }
        return isOnline ? "متصل" : "غير متصل"
    }

    @ViewBuilder
    private var statusBanner: some View {
        if !isOnline {
            Text("صديقك مو متصل. الرسائل توصله لما يدخل، والملفات تحتاج يكون متصل.")
                .font(.caption).multilineTextAlignment(.center)
                .frame(maxWidth: .infinity).padding(8)
                .background(Color.orange.opacity(0.18))
        } else if !app.isDirect(peer) {
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.7)
                Text("جاري تجهيز الاتصال المباشر…").font(.caption)
            }
            .frame(maxWidth: .infinity).padding(6)
            .background(Color.blue.opacity(0.12))
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
                Image(systemName: "plus.circle.fill").font(.system(size: 34)).foregroundStyle(Theme.brand)
            }
            TextField("رسالة", text: $text, axis: .vertical)
                .lineLimit(1...5)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
            Button {
                app.sendText(text, to: peer)
                text = ""
            } label: {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 34))
                    .foregroundStyle(text.trimmingCharacters(in: .whitespaces).isEmpty ? AnyShapeStyle(Color.gray.opacity(0.4)) : AnyShapeStyle(Theme.brand))
            }
            .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(.bar)
    }
}

struct Bubble: View {
    let m: ChatMessage
    var body: some View {
        let mine = m.outgoing
        HStack {
            if mine { content; Spacer(minLength: 44) } else { Spacer(minLength: 44); content }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let b = m.batch {
            FileCard(m: m, b: b)
        } else {
            VStack(alignment: .trailing, spacing: 3) {
                Text(m.text ?? "").textSelection(.enabled)
                HStack(spacing: 4) {
                    Text(Fmt.time(m.ts)).font(.system(size: 10))
                    if m.outgoing {
                        Image(systemName: m.delivered == true ? "checkmark.circle.fill" : "checkmark.circle")
                            .font(.system(size: 10))
                    }
                }
                .opacity(0.7)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .foregroundColor(m.outgoing ? Color.white : Color.primary)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(m.outgoing ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(Color(.systemBackground))))
        }
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
        case "video": return "film.fill"
        case "image": return "photo.fill"
        case "folder": return "folder.fill"
        default: return "doc.fill"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Theme.brand).frame(width: 46, height: 46)
                    .overlay(Image(systemName: icon).foregroundColor(.white).font(.title3))
                VStack(alignment: .leading, spacing: 2) {
                    Text(b.name).font(.subheadline.weight(.semibold)).lineLimit(2)
                    Text(subtitle).font(.caption).foregroundColor(.secondary)
                }
            }
            if !done && !failed {
                bar
                HStack {
                    Text("\(Int(fraction * 100))%").bold()
                    if let s = live?.speed, s > 0 {
                        Text("• " + Fmt.speed(s))
                        let remain = Double(b.size - (live?.bytes ?? 0)) / s
                        let e = Fmt.eta(remain)
                        if !e.isEmpty { Text("• باقي " + e) }
                    }
                    Spacer()
                }
                .font(.caption2).foregroundColor(.secondary)
                if let n = live?.note, !n.isEmpty {
                    Text(n).font(.caption2).foregroundColor(.orange)
                }
            } else if failed {
                Text(live?.note.isEmpty == false ? live!.note : "ما اكتمل النقل")
                    .font(.caption).foregroundColor(.red)
            }
            if done, !m.outgoing, let url = app.fileURL(for: m) {
                actions(url)
            }
            HStack {
                Spacer()
                Text(Fmt.time(m.ts)).font(.system(size: 10)).foregroundColor(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: 300, alignment: .leading)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .quickLookPreview($preview)
    }

    private var bar: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule().fill(Theme.brand).frame(width: max(8, g.size.width * fraction))
            }
        }
        .frame(height: 8)
    }

    private var subtitle: String {
        var s = Fmt.size(b.size)
        if b.isFolder { s += " • \(b.count) ملف" }
        if done { s += m.outgoing ? " • أُرسل ✓" : " • وصل ✓" }
        return s
    }

    @ViewBuilder
    private func actions(_ url: URL) -> some View {
        HStack(spacing: 8) {
            if !b.isFolder {
                ShareLink(item: url) { pill("مشاركة", "square.and.arrow.up") }
                Button { preview = url } label: { pill("فتح", "eye") }
            }
            if b.kind == "video" || b.kind == "image" {
                Button { app.saveToPhotos(url, video: b.kind == "video") } label: { pill("للصور", "photo.badge.plus") }
            }
            Button { app.openInFiles(url) } label: { pill("الملفات", "folder") }
        }
    }

    private func pill(_ t: String, _ icon: String) -> some View {
        Label(t, systemImage: icon)
            .font(.caption)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color(.secondarySystemBackground), in: Capsule())
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
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var showTurn = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        Avatar(name: app.username, size: 48)
                        VStack(alignment: .leading) {
                            Text("@" + app.username).font(.headline)
                            Text(app.mqttUp ? "متصل" : "جاري الاتصال…").font(.caption).foregroundColor(.secondary)
                        }
                    }
                    ShareLink(item: "ضيفني في الشلّة: @\(app.username)") {
                        Label("شارك اسمك مع صديق", systemImage: "square.and.arrow.up")
                    }
                }
                Section {
                    Toggle("إبقاء التطبيق شغّال بالخلفية", isOn: $app.keepAlive)
                } footer: {
                    Text("iOS يوقف التطبيقات بالخلفية. هذا الخيار يخليك تستقبل وترسل حتى لو طلعت من التطبيق. يستهلك بطارية أكثر.")
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
                    Text("تحتاجه فقط لو الاتصال المباشر ما اشتغل بين شبكتين.")
                }
                Section {
                    Text("الرسائل مشفّرة، والملفات تنتقل مباشرة من جوالك لجوال صديقك بدون ما تمر على أي سيرفر.")
                        .font(.footnote).foregroundColor(.secondary)
                }
            }
            .navigationTitle("الإعدادات")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("تم") { dismiss() } }
            }
        }
    }
}
