import SwiftUI

enum Cfg {
    static let url = "https://yozfrjtshivqfaofsbit.supabase.co"   // <- Supabase Project URL
    static let key = "sb_publishable_gcX0v80z8k-sn65XXG76BMg_-xP4Jw4t"                      // <- Supabase anon public key
}

struct Profile: Codable, Identifiable { let id: String; var username: String; var points: Int; var tier: String; var is_owner: Bool }
struct Channel: Codable, Identifiable { let id: Int; let name: String }
struct Msg: Codable, Identifiable { let id: Int; let username: String; let content: String }

@MainActor final class API: ObservableObject {
    @Published var token: String?
    @Published var userId: String?
    @Published var me: Profile?
    @Published var error = ""

    func req(_ path: String, method: String = "GET", body: Data? = nil) async throws -> Data {
        var r = URLRequest(url: URL(string: Cfg.url + path)!)
        r.httpMethod = method
        r.setValue(Cfg.key, forHTTPHeaderField: "apikey")
        if let t = token { r.setValue("Bearer " + t, forHTTPHeaderField: "Authorization") }
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = body
        let (d, resp) = try await URLSession.shared.data(for: r)
        if let h = resp as? HTTPURLResponse, h.statusCode >= 300 {
            let m = (try? JSONSerialization.jsonObject(with: d) as? [String: Any])?["message"] as? String
            throw NSError(domain: "api", code: h.statusCode, userInfo: [NSLocalizedDescriptionKey: m ?? "Error \(h.statusCode)"])
        }
        return d
    }

    func signIn(_ email: String, _ pass: String, _ name: String, signup: Bool) async {
        error = ""
        do {
            var body: [String: Any] = ["email": email, "password": pass]
            if signup { body["data"] = ["username": name] }
            let path = signup ? "/auth/v1/signup" : "/auth/v1/token?grant_type=password"
            let d = try await req(path, method: "POST", body: JSONSerialization.data(withJSONObject: body))
            let j = (try JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
            guard let t = j["access_token"] as? String, let u = (j["user"] as? [String: Any])?["id"] as? String else {
                error = "Confirm your email, then log in."; return
            }
            token = t; userId = u
            await loadMe()
        } catch { self.error = error.localizedDescription }
    }

    func loadMe() async {
        guard let u = userId,
              let d = try? await req("/rest/v1/profiles?id=eq.\(u)&select=*"),
              let p = try? JSONDecoder().decode([Profile].self, from: d) else { return }
        me = p.first
    }

    func rpc(_ name: String, _ args: [String: Any]) async {
        do {
            _ = try await req("/rest/v1/rpc/\(name)", method: "POST", body: JSONSerialization.data(withJSONObject: args))
            error = ""
        } catch { self.error = error.localizedDescription }
        await loadMe()
    }

    func logout() { token = nil; userId = nil; me = nil }
}

@main struct NexusChatApp: App {
    @StateObject var api = API()
    var body: some Scene {
        WindowGroup {
            Group {
                if api.token == nil { AuthView() } else { MainTabs() }
            }.environmentObject(api).preferredColorScheme(.dark)
        }
    }
}

struct AuthView: View {
    @EnvironmentObject var api: API
    @State var email = "", pass = "", name = "", signup = false
    var body: some View {
        VStack(spacing: 14) {
            Text("Nexus Chat").font(.largeTitle.bold())
            if signup { TextField("Username", text: $name).textInputAutocapitalization(.never) }
            TextField("Email", text: $email).textInputAutocapitalization(.never).keyboardType(.emailAddress)
            SecureField("Password", text: $pass)
            Button(signup ? "Create account" : "Log in") {
                Task { await api.signIn(email, pass, name, signup: signup) }
            }.buttonStyle(.borderedProminent)
            Button(signup ? "Have an account? Log in" : "New here? Sign up") { signup.toggle() }
            Text(api.error).foregroundColor(.red).font(.caption)
        }.textFieldStyle(.roundedBorder).padding()
    }
}

struct MainTabs: View {
    @EnvironmentObject var api: API
    var body: some View {
        TabView {
            ChannelsView().tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }
            ShopView().tabItem { Label("Shop", systemImage: "star.circle") }
            if api.me?.is_owner == true {
                OwnerView().tabItem { Label("Owner", systemImage: "crown") }
            }
        }
    }
}

struct ChannelsView: View {
    @EnvironmentObject var api: API
    @State var channels: [Channel] = []
    var body: some View {
        NavigationStack {
            List(channels) { c in
                NavigationLink("# \(c.name)") { ChatView(channel: c) }
            }
            .navigationTitle("Nexus Chat")
            .toolbar { Button("Log out") { api.logout() } }
            .task {
                if let d = try? await api.req("/rest/v1/channels?select=*&order=id"),
                   let c = try? JSONDecoder().decode([Channel].self, from: d) { channels = c }
            }
        }
    }
}

struct ChatView: View {
    @EnvironmentObject var api: API
    let channel: Channel
    @State var msgs: [Msg] = []
    @State var text = ""

    func load() async {
        let p = "/rest/v1/messages?channel_id=eq.\(channel.id)&order=created_at.desc&limit=100&select=id,username,content"
        if let d = try? await api.req(p), let m = try? JSONDecoder().decode([Msg].self, from: d) { msgs = m.reversed() }
    }

    var body: some View {
        VStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(msgs) { m in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(m.username).font(.caption.bold()).foregroundColor(.indigo)
                                Text(m.content)
                            }.id(m.id)
                        }
                    }.padding(.horizontal)
                }
                .onChange(of: msgs.last?.id) { id in if let id { proxy.scrollTo(id, anchor: .bottom) } }
            }
            HStack {
                TextField("Message #\(channel.name)", text: $text).textFieldStyle(.roundedBorder)
                Button("Send") {
                    let t = text.trimmingCharacters(in: .whitespaces)
                    guard !t.isEmpty else { return }
                    text = ""
                    Task {
                        _ = try? await api.req("/rest/v1/messages", method: "POST",
                            body: JSONSerialization.data(withJSONObject: ["channel_id": channel.id, "content": t]))
                        await load(); await api.loadMe()
                    }
                }
            }.padding()
        }
        .navigationTitle("# \(channel.name)").navigationBarTitleDisplayMode(.inline)
        .task { while !Task.isCancelled { await load(); try? await Task.sleep(nanoseconds: 2_000_000_000) } }
    }
}

struct ShopView: View {
    @EnvironmentObject var api: API
    var body: some View {
        VStack(spacing: 16) {
            Text("⭐ \(api.me?.points ?? 0) points").font(.largeTitle.bold())
            Text("Plan: \((api.me?.tier ?? "free").capitalized)")
            Text("Earn 2 points per message (every 10 seconds).").font(.caption).foregroundColor(.secondary)
            Button("Get Basic — 200 pts") { Task { await api.rpc("redeem", ["t": "basic"]) } }.buttonStyle(.borderedProminent)
            Button("Get Super — 600 pts") { Task { await api.rpc("redeem", ["t": "super"]) } }.buttonStyle(.borderedProminent).tint(.purple)
            Text(api.error).foregroundColor(.red).font(.caption)
        }.padding().task { await api.loadMe() }
    }
}

struct OwnerView: View {
    @EnvironmentObject var api: API
    @State var users: [Profile] = []
    @State var newChannel = ""
    func load() async {
        if let d = try? await api.req("/rest/v1/profiles?select=*&order=points.desc"),
           let u = try? JSONDecoder().decode([Profile].self, from: d) { users = u }
    }
    var body: some View {
        NavigationStack {
            List {
                Section("New channel") {
                    HStack {
                        TextField("name", text: $newChannel).textInputAutocapitalization(.never)
                        Button("Create") {
                            Task { await api.rpc("create_channel", ["n": newChannel]); newChannel = "" }
                        }
                    }
                }
                Section("Users (tap +100 to give points)") {
                    ForEach(users) { u in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(u.username + (u.is_owner ? " 👑" : ""))
                                Text("\(u.tier) • \(u.points) pts").font(.caption).foregroundColor(.secondary)
                            }
                            Spacer()
                            Button("+100") { Task { await api.rpc("grant_points", ["uid": u.id, "amt": 100]); await load() } }
                        }
                    }
                }
                if !api.error.isEmpty { Text(api.error).foregroundColor(.red) }
            }
            .navigationTitle("Owner Panel").task { await load() }
        }
    }
}
