import SwiftUI
import PhotosUI
import QuickLook
import UniformTypeIdentifiers

// MARK: - الثيم (داكن، حسب التصميم)

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 255) / 255,
                  green: Double((hex >> 8) & 255) / 255,
                  blue: Double(hex & 255) / 255)
    }
}

enum Theme {
    static let bg = Color(hex: 0x080D1C)
    static let surface = Color(hex: 0x111A2E)
    static let surface2 = Color(hex: 0x1A2540)
    static let text2 = Color(hex: 0x8A94B3)
    static let accent = Color(hex: 0x3B6BF7)
    static let line = Color.white.opacity(0.07)

    static let brand = LinearGradient(
        colors: [Color(hex: 0x2F8BFF), Color(hex: 0x7A3CF0)],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    static let bubbleMine = LinearGradient(
        colors: [Color(hex: 0x2E6BFF), Color(hex: 0x1F4FE6)],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    private static let avatarPairs: [(Color, Color)] = [
        (Color(hex: 0x56A8FF), Color(hex: 0x2563EB)),
        (Color(hex: 0xA78BFA), Color(hex: 0x6D3FE0)),
        (Color(hex: 0x34D3C0), Color(hex: 0x0E8FA8)),
        (Color(hex: 0xFF8FB1), Color(hex: 0xE0457A)),
        (Color(hex: 0xFFB45C), Color(hex: 0xF07A2A)),
        (Color(hex: 0x4ADE80), Color(hex: 0x16A06A)),
    ]

    static func avatar(_ name: String) -> LinearGradient {
        var h = 0
        for s in name.unicodeScalars { h = (h &* 31 &+ Int(s.value)) & 0xFFFF }
        let p = avatarPairs[h % avatarPairs.count]
        return LinearGradient(colors: [p.0, p.1], startPoint: .top, endPoint: .bottom)
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
                Circle().fill(on ? Color(hex: 0x22C55E) : Color.gray)
                    .frame(width: size * 0.27, height: size * 0.27)
                    .overlay(Circle().stroke(Theme.bg, lineWidth: 2))
            }
        }
    }
}

struct SearchField: View {
    @Binding var text: String
    let prompt: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundColor(Theme.text2)
            TextField("", text: $text, prompt: Text(prompt).foregroundColor(Theme.text2))
                .foregroundColor(.white)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(Theme.text2)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// MARK: - الترحيب

struct WelcomeView: View {
    @EnvironmentObject var app: AppState
    @State private var name = ""
    @State private var error = false

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            GeometryReader { g in
                Circle().fill(Color(hex: 0x2F5BFF).opacity(0.30)).frame(width: g.size.width * 1.1)
                    .blur(radius: 70).offset(x: -g.size.width * 0.5, y: g.size.height * 0.55)
                Circle().fill(Color(hex: 0x7A3CF0).opacity(0.28)).frame(width: g.size.width)
                    .blur(radius: 80).offset(x: g.size.width * 0.4, y: g.size.height * 0.75)
            }
            .ignoresSafeArea()
            VStack(spacing: 16) {
                Spacer()
                Image("Logo")
                    .resizable().scaledToFit().frame(width: 150, height: 150)
                    .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
                    .shadow(color: Color(hex: 0x3B6BF7).opacity(0.5), radius: 30, y: 10)
                Text("TextVast").font(.system(size: 42, weight: .heavy, design: .rounded)).foregroundColor(.white)
                Text("محادثات أفضل، أصدقاء أقرب")
                    .foregroundColor(Theme.text2)
                Spacer()
                VStack(spacing: 12) {
                    HStack {
                        Text("@").foregroundColor(Theme.text2)
                        TextField("", text: $name, prompt: Text("اسم المستخدم").foregroundColor(Theme.text2))
                            .foregroundColor(.white)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .environment(\.layoutDirection, .leftToRight)
                            .onChange(of: name) { v in
                                let f = String(v.lowercased().filter { "abcdefghijklmnopqrstuvwxyz0123456789_".contains($0) }.prefix(20))
                                if f != v { name = f }
                                error = false
                            }
                    }
                    .padding(15)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    Text(error ? "اكتب من 3 إلى 20 حرف إنجليزي أو أرقام" : "اسم ثابت يعرفك فيه أصدقاؤك، ما يحتاج كود")
                        .font(.footnote)
                        .foregroundColor(error ? Color(hex: 0xFFB45C) : Theme.text2)
                    Button {
                        if !app.register(name) { error = true }
                    } label: {
                        Text("ابدأ").font(.headline).foregroundColor(.white)
                            .frame(maxWidth: .infinity).padding(15)
                            .background(Theme.brand, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 34)
            }
        }
    }
}

// MARK: - التبويبات

struct RootTabs: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        TabView {
            ChatsTab()
                .tabItem { Label("المحادثات", systemImage: "bubble.left.and.bubble.right.fill") }
                .badge(app.totalUnread)
            ContactsTab()
                .tabItem { Label("الأصدقاء", systemImage: "person.2.fill") }
            FilesTab()
                .tabItem { Label("الملفات", systemImage: "folder.fill") }
            SettingsTab()
                .tabItem { Label("الإعدادات", systemImage: "gearshape.fill") }
        }
        .tint(Theme.accent)
    }
}

// MARK: - المحادثات

struct ChatsTab: View {
    @EnvironmentObject var app: AppState
    @State private var query = ""
    @State private var filter = 0
    @State private var showAdd = false

    private var rows: [Friend] {
        var list = app.friends.sorted { (app.last($0.id)?.ts ?? $0.addedAt) > (app.last($1.id)?.ts ?? $1.addedAt) }
        if !query.isEmpty { list = list.filter { $0.id.contains(query.lowercased()) } }
        if filter == 1 { list = list.filter { app.unread($0.id) > 0 } }
        if filter == 2 { list = list.filter { app.online[$0.id] == true } }
        return list
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
                if !app.mqttUp {
                    HStack(spacing: 8) {
                        ProgressView().scaleEffect(0.8).tint(.white)
                        Text("جاري الاتصال…").font(.footnote).foregroundColor(.white)
                    }
                    .frame(maxWidth: .infinity).padding(8)
                    .background(Color(hex: 0xF07A2A).opacity(0.25))
                }
                SearchField(text: $query, prompt: "ابحث في المحادثات…").padding(.horizontal, 16)
                chips
                if app.friends.isEmpty {
                    EmptyState(icon: "person.2.fill", title: "ما عندك أصدقاء بعد",
                               text: "اطلب من صديقك اسم المستخدم حقه وضيفه.\nاسمك أنت: @\(app.username)",
                               action: "إضافة صديق") { showAdd = true }
                } else {
                    List {
                        ForEach(rows) { f in
                            NavigationLink(value: f.id) { ChatRow(friend: f) }
                                .listRowBackground(Color.clear)
                                .listRowSeparatorTint(Theme.line)
                                .swipeActions {
                                    Button(role: .destructive) { app.removeFriend(f.id) } label: {
                                        Label("حذف", systemImage: "trash")
                                    }
                                }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("TextVast")
            .navigationDestination(for: String.self) { ChatView(peer: $0) }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showAdd = true } label: {
                        Image(systemName: "plus").font(.system(size: 15, weight: .bold))
                            .frame(width: 32, height: 32).background(Theme.surface2, in: Circle())
                    }
                }
            }
            .sheet(isPresented: $showAdd) {
                AddFriendSheet().environmentObject(app).environment(\.layoutDirection, .rightToLeft)
            }
        }
    }

    private var chips: some View {
        HStack(spacing: 8) {
            chip("الكل", 0)
            let u = app.totalUnread
            chip(u > 0 ? "غير مقروءة \(u)" : "غير مقروءة", 1)
            chip("متصل", 2)
            Spacer()
        }
        .padding(.horizontal, 16)
    }

    private func chip(_ t: String, _ i: Int) -> some View {
        Button { filter = i } label: {
            Text(t).font(.subheadline.weight(.medium))
                .padding(.horizontal, 14).padding(.vertical, 7)
                .foregroundColor(filter == i ? .white : Theme.text2)
                .background(filter == i ? Theme.accent : Theme.surface, in: Capsule())
        }
    }
}

struct EmptyState: View {
    let icon: String
    let title: String
    let text: String
    var action: String? = nil
    var onTap: (() -> Void)? = nil
    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: icon).font(.system(size: 52)).foregroundStyle(Theme.brand)
            Text(title).font(.title3.bold()).foregroundColor(.white)
            Text(text).multilineTextAlignment(.center).foregroundColor(Theme.text2)
            if let a = action {
                Button { onTap?() } label: {
                    Text(a).font(.headline).foregroundColor(.white)
                        .padding(.horizontal, 26).padding(.vertical, 12)
                        .background(Theme.brand, in: Capsule())
                }
            }
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity)
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
                    Text("@" + friend.id).font(.headline).foregroundColor(.white)
                    Spacer()
                    if let l = last { Text(Fmt.time(l.ts)).font(.caption).foregroundColor(Theme.text2) }
                }
                HStack {
                    Text(preview(last)).font(.subheadline).foregroundColor(Theme.text2).lineLimit(1)
                    Spacer()
                    if unread > 0 {
                        Text("\(unread)").font(.caption.bold()).foregroundColor(.white)
                            .frame(minWidth: 22, minHeight: 22)
                            .background(Theme.accent, in: Circle())
                    }
                }
            }
        }
        .padding(.vertical, 5)
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
        VStack(spacing: 18) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark").foregroundColor(.white)
                        .frame(width: 34, height: 34).background(Theme.surface2, in: Circle())
                }
                Spacer()
                Text("إضافة صديق").font(.headline).foregroundColor(.white)
                Spacer()
                Color.clear.frame(width: 34, height: 34)
            }
            HStack {
                Text("@").foregroundColor(Theme.text2)
                TextField("", text: $name, prompt: Text("اسم المستخدم").foregroundColor(Theme.text2))
                    .foregroundColor(.white)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .environment(\.layoutDirection, .leftToRight)
            }
            .padding(15)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            Text(error ? "الاسم غير صحيح" : "اكتب اسم المستخدم اللي أعطاك إياه صديقك.")
                .font(.footnote).foregroundColor(error ? Color(hex: 0xFF6B6B) : Theme.text2)
            Button {
                if app.addFriend(name) { dismiss() } else { error = true }
            } label: {
                Text("إضافة").font(.headline).foregroundColor(.white)
                    .frame(maxWidth: .infinity).padding(15)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            Spacer()
        }
        .padding(20)
        .background(Theme.bg.ignoresSafeArea())
        .presentationDetents([.medium])
    }
}

// MARK: - الأصدقاء

struct ContactsTab: View {
    @EnvironmentObject var app: AppState
    @State private var query = ""
    @State private var showAdd = false

    private var rows: [Friend] {
        let l = app.friends.sorted {
            let a = app.online[$0.id] == true, b = app.online[$1.id] == true
            return a != b ? a : $0.id < $1.id
        }
        return query.isEmpty ? l : l.filter { $0.id.contains(query.lowercased()) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
                SearchField(text: $query, prompt: "ابحث عن صديق…").padding(.horizontal, 16)
                if app.friends.isEmpty {
                    EmptyState(icon: "person.badge.plus", title: "لا أحد هنا",
                               text: "ضيف أصدقاءك باسم المستخدم.", action: "إضافة صديق") { showAdd = true }
                } else {
                    List {
                        ForEach(rows) { f in
                            NavigationLink(value: f.id) {
                                HStack(spacing: 12) {
                                    Avatar(name: f.id, size: 46, online: app.online[f.id] ?? false)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("@" + f.id).font(.headline).foregroundColor(.white)
                                        Text(app.isDirect(f.id) ? "اتصال مباشر ⚡" : (app.online[f.id] == true ? "متصل" : "غير متصل"))
                                            .font(.caption)
                                            .foregroundColor(app.online[f.id] == true ? Color(hex: 0x22C55E) : Theme.text2)
                                    }
                                }
                                .padding(.vertical, 3)
                            }
                            .listRowBackground(Color.clear)
                            .listRowSeparatorTint(Theme.line)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("الأصدقاء")
            .navigationDestination(for: String.self) { ChatView(peer: $0) }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showAdd = true } label: {
                        Image(systemName: "person.badge.plus").font(.system(size: 15, weight: .bold))
                            .frame(width: 32, height: 32).background(Theme.surface2, in: Circle())
                    }
                }
            }
            .sheet(isPresented: $showAdd) {
                AddFriendSheet().environmentObject(app).environment(\.layoutDirection, .rightToLeft)
            }
        }
    }
}

// MARK: - الملفات

struct FilesTab: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 12) {
                    Button {
                        app.openInFiles(Paths.received)
                    } label: {
                        HStack {
                            Image(systemName: "folder.fill").foregroundStyle(Theme.brand)
                            Text("فتح مجلد الملفات المستلمة").foregroundColor(.white)
                            Spacer()
                            Image(systemName: "chevron.left").foregroundColor(Theme.text2).font(.footnote)
                        }
                        .padding(14)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    if app.fileMessages.isEmpty {
                        EmptyState(icon: "tray.and.arrow.down.fill", title: "ما فيه ملفات بعد",
                                   text: "الملفات اللي ترسلها وتستلمها تطلع هنا.")
                            .frame(height: 320)
                    }
                    ForEach(app.fileMessages) { m in
                        if let b = m.batch {
                            VStack(alignment: .leading, spacing: 5) {
                                Text((m.outgoing ? "إلى " : "من ") + "@" + m.peer)
                                    .font(.caption).foregroundColor(Theme.text2)
                                FileCard(m: m, b: b, fill: true)
                            }
                        }
                    }
                }
                .padding(16)
            }
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("الملفات")
        }
    }
}

// MARK: - الإعدادات

struct SettingsTab: View {
    @EnvironmentObject var app: AppState
    @State private var showTurn = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    VStack(spacing: 10) {
                        Avatar(name: app.username, size: 92)
                            .shadow(color: Theme.accent.opacity(0.5), radius: 18)
                        Text("@" + app.username).font(.title3.bold()).foregroundColor(.white)
                        HStack(spacing: 6) {
                            Circle().fill(app.mqttUp ? Color(hex: 0x22C55E) : Color.orange).frame(width: 8, height: 8)
                            Text(app.mqttUp ? "متصل" : "جاري الاتصال…").font(.caption).foregroundColor(Theme.text2)
                        }
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 22)
                    .background(
                        LinearGradient(colors: [Color(hex: 0x16244A), Theme.surface], startPoint: .top, endPoint: .bottom),
                        in: RoundedRectangle(cornerRadius: 22, style: .continuous))

                    VStack(spacing: 0) {
                        ShareLink(item: "ضيفني في TextVast: @\(app.username)") {
                            row("square.and.arrow.up", 0x3B6BF7, "شارك اسمك مع صديق")
                        }
                        divider
                        Button { app.openInFiles(Paths.received) } label: {
                            row("folder.fill", 0xF07A2A, "الملفات المستلمة")
                        }
                        divider
                        HStack {
                            icon("bolt.fill", 0x22C55E)
                            Text("إبقاء التطبيق شغّال بالخلفية").foregroundColor(.white)
                            Spacer()
                            Toggle("", isOn: $app.keepAlive).labelsHidden()
                        }
                        .padding(14)
                    }
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                    Text("iOS يوقف التطبيقات بالخلفية. الخيار يخليك تستقبل وترسل حتى لو طلعت من التطبيق، لكنه يستهلك بطارية أكثر.")
                        .font(.footnote).foregroundColor(Theme.text2).padding(.horizontal, 6)

                    VStack(spacing: 0) {
                        Button { withAnimation { showTurn.toggle() } } label: {
                            HStack {
                                icon("network", 0x7A3CF0)
                                Text("خيارات متقدمة (TURN)").foregroundColor(.white)
                                Spacer()
                                Image(systemName: showTurn ? "chevron.up" : "chevron.down")
                                    .foregroundColor(Theme.text2).font(.footnote)
                            }
                            .padding(14)
                        }
                        if showTurn {
                            VStack(spacing: 10) {
                                field("turn:host:3478", $app.turnURL)
                                field("المستخدم", $app.turnUser)
                                SecureField("", text: $app.turnPass, prompt: Text("كلمة السر").foregroundColor(Theme.text2))
                                    .foregroundColor(.white).padding(12)
                                    .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 12))
                                Text("تحتاجه فقط لو الاتصال المباشر ما اشتغل بين شبكتين.")
                                    .font(.caption).foregroundColor(Theme.text2)
                            }
                            .padding([.horizontal, .bottom], 14)
                        }
                    }
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                    HStack(spacing: 10) {
                        icon("lock.shield.fill", 0x2F8BFF)
                        Text("الرسائل مشفّرة، والملفات تنتقل مباشرة من جوالك لجوال صديقك بدون ما تمر على أي سيرفر.")
                            .font(.footnote).foregroundColor(Theme.text2)
                    }
                    .padding(14)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .padding(16)
            }
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("الإعدادات")
        }
    }

    private var divider: some View {
        Rectangle().fill(Theme.line).frame(height: 1).padding(.leading, 56)
    }

    private func icon(_ name: String, _ hex: UInt32) -> some View {
        Image(systemName: name).font(.system(size: 14, weight: .semibold)).foregroundColor(.white)
            .frame(width: 30, height: 30)
            .background(Color(hex: hex), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func row(_ ic: String, _ hex: UInt32, _ t: String) -> some View {
        HStack {
            icon(ic, hex)
            Text(t).foregroundColor(.white)
            Spacer()
            Image(systemName: "chevron.left").foregroundColor(Theme.text2).font(.footnote)
        }
        .padding(14)
    }

    private func field(_ p: String, _ b: Binding<String>) -> some View {
        TextField("", text: b, prompt: Text(p).foregroundColor(Theme.text2))
            .foregroundColor(.white)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .environment(\.layoutDirection, .leftToRight)
            .padding(12)
            .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - المحادثة

struct ChatView: View {
    let peer: String
    @EnvironmentObject var app: AppState
    @State private var text = ""
    @State private var showAttach = false
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
        .background(Theme.bg.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 8) {
                    Avatar(name: peer, size: 34)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("@" + peer).font(.subheadline.bold()).foregroundColor(.white)
                        Text(statusText).font(.caption2)
                            .foregroundColor(isOnline ? Color(hex: 0x22C55E) : Theme.text2)
                    }
                }
            }
        }
        .onAppear { app.activeChat = peer; app.markRead(peer) }
        .onDisappear { if app.activeChat == peer { app.activeChat = nil } }
        .sheet(isPresented: $showAttach) {
            AttachSheet(photoItems: $photoItems, onFiles: { pick(folder: false) }, onFolder: { pick(folder: true) })
                .environment(\.layoutDirection, .rightToLeft)
        }
        .onChange(of: photoItems) { items in
            guard !items.isEmpty else { return }
            showAttach = false
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

    private func pick(folder: Bool) {
        showAttach = false
        // ننتظر لين تسكّر نافذة الإرفاق عشان ما يتعارض العرضين
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            DocPicker.shared.present(folder: folder) { urls in
                app.startSend(urls: urls, to: peer)
            }
        }
    }

    private var statusText: String {
        if app.isDirect(peer) { return "متصل • اتصال مباشر ⚡" }
        return isOnline ? "متصل" : "غير متصل"
    }

    @ViewBuilder
    private var statusBanner: some View {
        if !isOnline {
            Text("صديقك مو متصل. الرسائل توصله لما يدخل، والملفات تحتاج يكون متصل.")
                .font(.caption).foregroundColor(.white).multilineTextAlignment(.center)
                .frame(maxWidth: .infinity).padding(8)
                .background(Color(hex: 0xF07A2A).opacity(0.28))
        } else if !app.isDirect(peer) {
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.7).tint(.white)
                Text("جاري تجهيز الاتصال المباشر…").font(.caption).foregroundColor(.white)
            }
            .frame(maxWidth: .infinity).padding(6)
            .background(Theme.accent.opacity(0.28))
        }
    }

    private var composer: some View {
        HStack(spacing: 8) {
            Button { showAttach = true } label: {
                Image(systemName: "plus").font(.system(size: 17, weight: .bold)).foregroundColor(.white)
                    .frame(width: 40, height: 40).background(Theme.surface2, in: Circle())
            }
            TextField("", text: $text, prompt: Text("اكتب رسالة…").foregroundColor(Theme.text2), axis: .vertical)
                .foregroundColor(.white)
                .lineLimit(1...5)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            let empty = text.trimmingCharacters(in: .whitespaces).isEmpty
            Button {
                app.sendText(text, to: peer)
                text = ""
            } label: {
                Image(systemName: "paperplane.fill").font(.system(size: 16)).foregroundColor(.white)
                    .frame(width: 40, height: 40)
                    .background(empty ? AnyShapeStyle(Theme.surface2) : AnyShapeStyle(Theme.accent), in: Circle())
            }
            .disabled(empty)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(Theme.bg)
    }
}

// MARK: - نافذة الإرفاق

struct AttachSheet: View {
    @Binding var photoItems: [PhotosPickerItem]
    let onFiles: () -> Void
    let onFolder: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("إرفاق").font(.headline).foregroundColor(.white)
            HStack(spacing: 14) {
                PhotosPicker(selection: $photoItems, matching: .images, preferredItemEncoding: .current) {
                    tile("photo.fill", 0x3B6BF7, "صور")
                }
                PhotosPicker(selection: $photoItems, matching: .videos, preferredItemEncoding: .current) {
                    tile("play.rectangle.fill", 0x7A3CF0, "فيديو")
                }
                Button(action: onFiles) { tile("doc.fill", 0x16A06A, "ملفات") }
                Button(action: onFolder) { tile("folder.fill", 0xF07A2A, "مجلد") }
            }
            Text("الفيديوهات والصور تنرسل بجودتها الأصلية بدون ضغط.")
                .font(.footnote).foregroundColor(Theme.text2)
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.bg.ignoresSafeArea())
        .presentationDetents([.height(260)])
        .presentationDragIndicator(.visible)
    }

    private func tile(_ icon: String, _ hex: UInt32, _ title: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 24)).foregroundColor(Color(hex: hex))
                .frame(width: 64, height: 64)
                .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            Text(title).font(.caption).foregroundColor(.white)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - الفقاعات

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
                .opacity(0.65)
            }
            .padding(.horizontal, 13).padding(.vertical, 9)
            .foregroundColor(.white)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(m.outgoing ? AnyShapeStyle(Theme.bubbleMine) : AnyShapeStyle(Theme.surface2)))
        }
    }
}

// MARK: - بطاقة الملف

struct FileCard: View {
    let m: ChatMessage
    let b: BatchInfo
    var fill = false
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
                    Text(b.name).font(.subheadline.weight(.semibold)).foregroundColor(.white).lineLimit(2)
                    Text(subtitle).font(.caption).foregroundColor(Theme.text2)
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
                .font(.caption2).foregroundColor(Theme.text2)
                if let n = live?.note, !n.isEmpty {
                    Text(n).font(.caption2).foregroundColor(Color(hex: 0xFFB45C))
                }
            } else if failed {
                Text(live?.note.isEmpty == false ? live!.note : "ما اكتمل النقل")
                    .font(.caption).foregroundColor(Color(hex: 0xFF6B6B))
            }
            if done, !m.outgoing, let url = app.fileURL(for: m) {
                actions(url)
            }
            HStack {
                Spacer()
                Text(Fmt.time(m.ts)).font(.system(size: 10)).foregroundColor(Theme.text2)
            }
        }
        .padding(12)
        .frame(maxWidth: fill ? .infinity : 300, alignment: .leading)
        .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .quickLookPreview($preview)
    }

    private var bar: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
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
            .font(.caption).foregroundColor(.white)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.white.opacity(0.10), in: Capsule())
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
