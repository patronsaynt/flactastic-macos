import SwiftUI

/// One plain line under the top bar while a server library needs saying
/// something about: offline, scanning, unreachable, signed out, or busy.
struct ServerStatusLine: View {
    @Environment(ServerSession.self) private var server
    @Environment(NavigationRouter.self) private var router

    var body: some View {
        if let text {
            Button { router.showSettings = true } label: {
                HStack(spacing: 8) {
                    if isBusy { BrandLoader(height: 12) }
                    Text(text)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(isProblem ? Theme.textPrimary : Theme.textSecondary)
                }
                .padding(.horizontal, 12)
                .frame(height: 26)
                .background(Capsule().fill(Theme.textPrimary.opacity(isProblem ? 0.12 : 0.06)))
            }
            .buttonStyle(.plain)
            .help("Open Settings")
            .transition(.opacity)
        }
    }

    private var name: String { server.active?.serverName ?? "the server" }

    private var isProblem: Bool {
        switch server.status {
        case .unreachable, .signedOut, .identityChanged: true
        default: server.library?.state == .offline
        }
    }

    private var isBusy: Bool { !isProblem && text != nil }

    private var text: String? {
        guard server.isActive else { return nil }
        switch server.status {
        case .identityChanged: return "\(name)'s identity changed."
        case .signedOut: return "Signed out of \(name)."
        case .unreachable: return "Can't reach \(name). Playing offline copies."
        default: break
        }
        if server.library?.state == .offline { return "\(name)'s music folder is offline. Browsing still works." }
        if server.library?.state == .scanning { return "\(name) is scanning." }
        let sending = server.uploads.items.filter { $0.status == .sending || $0.status == .hashing || $0.status == .waiting }.count
        if sending > 0 { return "Uploading \(sending) file\(sending == 1 ? "" : "s")" }
        if let p = server.offline.progress { return "Downloading \(p.done + 1) of \(p.total) for offline" }
        return nil
    }
}

/// A playlist save that would replace a copy changed on another device.
struct PlaylistConflictSheet: View {
    let conflict: PlaylistSync.Conflict
    @Environment(ServerSession.self) private var server

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Replace on the server?")
                .font(.system(size: 28, weight: .heavy))
                .tracking(-0.9)
                .foregroundStyle(Theme.textPrimary)
            Text(conflict.server == nil
                 ? "“\(conflict.local.name)” was deleted on another device."
                 : "“\(conflict.local.name)” changed on another device since this Mac read it.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textTertiary)
                .padding(.top, 6)
                .padding(.bottom, 18)
            ForEach(rows, id: \.0) { label, theirs, mine in
                HStack(spacing: 10) {
                    Text(label).foregroundStyle(Theme.textTertiary).frame(width: 110, alignment: .leading)
                    Text(theirs).foregroundStyle(Theme.textSecondary).strikethrough(theirs != mine)
                    Image(systemName: "arrow.right").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.textTertiary)
                    Text(mine).fontWeight(.semibold).foregroundStyle(Theme.textPrimary)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 14))
                .lineLimit(1)
                .frame(height: 40)
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.textPrimary.opacity(0.1)).frame(height: 1) }
            }
            Spacer(minLength: 20)
            HStack(spacing: 10) {
                Spacer()
                Button(conflict.server == nil ? "Delete Here Too" : "Use the Server's") { server.playlistSync.useServers(conflict) }
                    .buttonStyle(SheetPillStyle())
                Button("Replace") { Task { await server.playlistSync.keepMine(conflict) } }
                    .buttonStyle(SheetPillStyle(isPrimary: true))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(30)
        .frame(width: 520, height: 360)
        .background(Theme.surface)
    }

    /// What this Mac's copy would replace: (field, server's, this Mac's).
    private var rows: [(String, String, String)] {
        let mine = conflict.local
        guard let theirs = conflict.server else { return [("Tracks", "Deleted", "\(mine.entries.count) tracks")] }
        let theirIDs = Set(theirs.entries.map { $0.trackID?.uuidString ?? $0.relativePath })
        let myIDs = Set(mine.entries.map { $0.trackID?.uuidString ?? $0.relativePath })
        var out: [(String, String, String)] = []
        if theirs.name != mine.name { out.append(("Name", theirs.name, mine.name)) }
        let added = myIDs.subtracting(theirIDs).count, removed = theirIDs.subtracting(myIDs).count
        var mineTracks = "\(mine.entries.count)"
        if removed > 0 { mineTracks += " · \(removed) fewer" }
        if added > 0 { mineTracks += " · \(added) new" }
        out.append(("Tracks", "\(theirs.entries.count)", mineTracks))
        if (theirs.description ?? "") != (mine.description ?? "") {
            out.append(("Description", theirs.description ?? "None", mine.description ?? "None"))
        }
        if theirs.customArtwork != mine.customArtwork { out.append(("Cover", "Theirs", "This Mac's")) }
        return out
    }
}
