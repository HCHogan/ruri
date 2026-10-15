import SwiftUI
import AppKit
import RuriCore
import RuriLocalization

/// The worlds and servers one run spent its time in, in play order, each with
/// the icon the player knows it by. A server opens in the server center.
struct PlayedSegmentsSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let session: GameSession
    @State private var worldIcons: [String: NSImage] = [:]
    @State private var servers: [String: GameHistoryView.ServerArt] = [:]
    private var segments: [GameActivitySegment] { session.playedSegments }
    private var artKey: String {
        session.id.uuidString + "|" + segments.map { $0.target.kind + "/" + $0.target.key }.joined(separator: ",") + "|" + (model.state.revision?.uuidString ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(Messages.Servers.history.localized)
            if segments.isEmpty {
                Surface { Text(Messages.Servers.unattributed.localized).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) }
            } else {
                Surface(padding: 0) {
                    VStack(spacing: 0) {
                        ForEach(segments) { segment in
                            row(segment)
                            if segment.id != segments.last?.id { Divider().padding(.leading, 62) }
                        }
                    }
                }
            }
        }
        .task(id: artKey) { await loadArt() }
    }

    @ViewBuilder private func row(_ segment: GameActivitySegment) -> some View {
        switch segment.target {
        case .world(let folder, let name):
            PlayedSegmentRow(segment: segment, title: name.isEmpty ? folder : name, kind: Messages.Servers.world.localized, open: nil) {
                WorldIcon(image: worldIcons[folder], size: 32)
            }
        case .server(let address, let name):
            PlayedSegmentRow(segment: segment, title: servers[address.key]?.name ?? (name.isEmpty ? address.authority : name),
                             kind: Messages.Servers.server.localized, open: { model.showServer(address); dismiss() }) {
                ServerIcon(data: servers[address.key]?.icon, size: 32)
            }
        case .unattributed:
            EmptyView()
        }
    }

    /// Save icons come from the instance's own folder; server names and
    /// favicons from the player's lists, as on the history page.
    private func loadArt() async {
        var folders = Set<String>(), addresses = Set<String>()
        for segment in segments {
            switch segment.target {
            case .world(let folder, _): folders.insert(folder)
            case .server(let address, _): addresses.insert(address.key)
            case .unattributed: break
            }
        }
        guard !folders.isEmpty || !addresses.isEmpty else { return }
        let paths = model.paths, state = model.state, instanceID = session.instanceID
        let loaded = await Task.detached(priority: .utility) { () -> ([String: Data], [ServerLibraryItem]) in
            var icons: [String: Data] = [:]
            for folder in folders { icons[folder] = WorldIcon.data(paths: paths, instanceID: instanceID, folder: folder) }
            let items = addresses.isEmpty ? [] : ServerLibrary.load(paths: paths, state: state).items.filter { addresses.contains($0.id) }
            return (icons, items)
        }.value
        guard !Task.isCancelled else { return }
        for (folder, data) in loaded.0 { worldIcons[folder] = NSImage(data: data) }
        for item in loaded.1 { servers[item.id] = .init(name: item.name, icon: item.icon) }
    }
}

private struct PlayedSegmentRow<Icon: View>: View {
    let segment: GameActivitySegment
    let title: String
    let kind: String
    let open: (() -> Void)?
    @ViewBuilder var icon: Icon
    @State private var hovering = false

    var body: some View {
        if let open {
            Button(action: open) { content }
                .buttonStyle(.plain)
                .background(.primary.opacity(hovering ? 0.045 : 0))
                .onHover { hovering = $0 }
                .help(Messages.Servers.showInServers.localized)
        } else {
            content
        }
    }

    private var content: some View {
        HStack(spacing: 12) {
            icon
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline).lineLimit(1)
                Text(kind + " · " + LocalizedFormat.date(segment.startedAt, date: .omitted)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if segment.quality != .observed {
                HStack(spacing: 3) {
                    Image(systemName: "info.circle")
                    Text(Messages.Servers.estimated.localized)
                }
                .font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .help(Messages.Servers.estimateHint.localized)
            }
            Text(LocalizedFormat.duration(segment.seconds)).font(.callout).foregroundStyle(.secondary).monospacedDigit()
            // Held in place on rows that open nothing, so the times line up.
            Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                .opacity(open == nil ? 0 : 1).accessibilityHidden(true)
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
    }
}
