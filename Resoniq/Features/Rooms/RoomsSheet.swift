import ResoniqDesign
import ResoniqStore
import SwiftData
import SwiftUI

/// The rooms and systems sheet behind every tab's switcher (no mockup; built from design/DESIGN_SYSTEM.md): the
/// rooms, each with its sound systems, the selected one marked. Tapping a system selects it and closes the sheet, so
/// every tab's switcher shows it. Rooms and systems can be added, renamed and deleted; the last room, and the last
/// system of a room, cannot be deleted, and the sheet says so.
///
/// Reads and writes the store in the environment (`\.resoniqStore`); the lists are live with `@Query`. It is
/// meant to be presented with `.sheet`; it asks for the medium and large detents itself.
struct RoomsSheet: View {
    var onClose: () -> Void

    @Environment(\.resoniqStore) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query(sort: \Room.createdAt) private var rooms: [Room]
    @Query private var states: [StoreState]

    @State private var isEditing = false
    @State private var naming: Naming?
    @State private var draft = ""
    @State private var addingSystemTo: Room?
    @State private var deleting: Deletion?
    @State private var blocked: Block?
    @State private var failed = false

    fileprivate enum Naming: Identifiable {
        case newRoom
        case room(Room)
        case system(SoundSystem)

        var id: String {
            switch self {
            case .newRoom: "new"
            case .room(let room): "room-\(room.persistentModelID.hashValue)"
            case .system(let system): "system-\(system.persistentModelID.hashValue)"
            }
        }
    }

    fileprivate enum Deletion: Identifiable {
        case room(Room)
        case system(SoundSystem)

        var id: String {
            switch self {
            case .room(let room): "room-\(room.persistentModelID.hashValue)"
            case .system(let system): "system-\(system.persistentModelID.hashValue)"
            }
        }
    }

    fileprivate enum Block: Identifiable {
        case lastRoom
        case lastSystem
        var id: Self { self }
    }

    /// The selected system, else the first one of the oldest room that has one: the same rule as the switchers.
    private var selected: SoundSystem? {
        states.first?.selectedSystem ?? rooms.lazy.compactMap { $0.orderedSystems.first }.first
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            list
        }
        .background(ResoniqColor.ink)
        .tint(ResoniqColor.ivory)
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(ResoniqColor.ink)
        .presentationCornerRadius(ResoniqRadius.sheet)
        .modifier(
            RoomsDialogs(
                naming: $naming, draft: $draft, addingSystemTo: $addingSystemTo, deleting: $deleting,
                blocked: $blocked, failed: $failed, rooms: rooms,
                performNaming: performNaming, addSystem: addSystem, performDelete: performDelete
            )
        )
    }

    // MARK: The header

    /// Edit at the left and Done at the right, as a sheet's bar has them (HIG), drawn with the design system's text
    /// links; the title under them, as Settings has it.
    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button(isEditing ? RoomsText.stopEditing : RoomsText.edit) {
                    withAnimation(reduceMotion ? nil : ResoniqMotion.sheet) { isEditing.toggle() }
                }
                .buttonStyle(ResoniqTextLinkStyle())
                Spacer(minLength: ResoniqSpace.s3)
                Button(RoomsText.done, action: onClose)
                    .buttonStyle(ResoniqTextLinkStyle())
            }
            Text(RoomsText.title)
                .resoniqTitle(.small)
                .accessibilityAddTraits(.isHeader)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, ResoniqSpace.screenInset)
        .padding(.top, ResoniqSpace.s2)
        .padding(.bottom, ResoniqSpace.s2)
    }

    // MARK: The list

    private var list: some View {
        List {
            Text(RoomsText.intro)
                .font(ResoniqFont.body)
                .foregroundStyle(ResoniqColor.muted)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(Metrics.rowInsets)
            ForEach(rooms) { room in
                Section {
                    ForEach(room.orderedSystems) { system in
                        SystemRow(
                            system: system, room: room, isSelected: system.persistentModelID == selected?.persistentModelID,
                            isEditing: isEditing,
                            onSelect: { select(system) },
                            onRename: { beginRenaming(system) },
                            onDelete: { requestDeletion(of: system) }
                        )
                    }
                    Button(RoomsText.addSystem) { addingSystemTo = room }
                        .buttonStyle(ResoniqInlineLinkStyle())
                        .listRowBackground(ResoniqColor.panel)
                        .listRowInsets(Metrics.rowInsets)
                } header: {
                    RoomHeader(
                        room: room, isEditing: isEditing,
                        onRename: { beginRenaming(room) }, onDelete: { requestDeletion(of: room) }
                    )
                    .padding(.horizontal, ResoniqSpace.screenInset)
                    .background(ResoniqColor.ink)
                }
                .listSectionSeparator(.hidden)
            }
            Section {
                Button(RoomsText.addRoom) {
                    draft = StoreText.newRoomName(existing: rooms.count)
                    naming = .newRoom
                }
                .buttonStyle(ResoniqInlineLinkStyle())
                .listRowBackground(ResoniqColor.panel)
                .listRowInsets(Metrics.rowInsets)
            }
            .listSectionSeparator(.hidden)
        }
        // The app's own look: panel rows edge to edge with hairlines between them, on the app background.
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .listRowSeparatorTint(ResoniqColor.line)
        .background(ResoniqColor.ink)
    }

    private enum Metrics {
        /// Rows and the intro line start at the screen inset, like every other screen.
        static let rowInsets = EdgeInsets(
            top: 0, leading: ResoniqSpace.screenInset, bottom: 0, trailing: ResoniqSpace.screenInset
        )
    }

    // MARK: Actions

    private func select(_ system: SoundSystem) {
        attempt { try store?.select(system) }
        onClose()
    }

    private func beginRenaming(_ room: Room) {
        draft = room.name
        naming = .room(room)
    }

    private func beginRenaming(_ system: SoundSystem) {
        draft = system.name
        naming = .system(system)
    }

    private func requestDeletion(of room: Room) {
        guard (try? store?.canDelete(room)) ?? false else {
            blocked = .lastRoom
            return
        }
        deleting = .room(room)
    }

    private func requestDeletion(of system: SoundSystem) {
        guard store?.canDelete(system) ?? false else {
            blocked = .lastSystem
            return
        }
        deleting = .system(system)
    }

    private func performNaming(_ naming: Naming) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        attempt {
            switch naming {
            case .newRoom:
                guard let store else { return }
                let room = try store.addRoom(name: text.isEmpty ? StoreText.newRoomName(existing: rooms.count) : text)
                try store.addSystem(name: StoreText.defaultSystemName, kind: .stereoPair, to: room)
            case .room(let room):
                if !text.isEmpty { try store?.rename(room, to: text) }
            case .system(let system):
                if !text.isEmpty { try store?.rename(system, to: text) }
            }
        }
    }

    private func addSystem(to room: Room, name: String, kind: SoundSystemKind) {
        let text = name.trimmingCharacters(in: .whitespacesAndNewlines)
        attempt {
            try store?.addSystem(
                name: text.isEmpty ? StoreText.newSystemName(existing: room.systems.count) : text, kind: kind, to: room
            )
        }
    }

    private func performDelete(_ deletion: Deletion) {
        attempt {
            switch deletion {
            case .room(let room): try store?.delete(room)
            case .system(let system): try store?.delete(system)
            }
        }
    }

    private func attempt(_ work: () throws -> Void) {
        do { try work() } catch { failed = true }
    }

    // MARK: Dialogs

    /// The alerts, the confirmation and the new-system form, kept apart so the body stays readable.
    private struct RoomsDialogs: ViewModifier {
        @Binding var naming: Naming?
        @Binding var draft: String
        @Binding var addingSystemTo: Room?
        @Binding var deleting: Deletion?
        @Binding var blocked: Block?
        @Binding var failed: Bool
        let rooms: [Room]
        let performNaming: (Naming) -> Void
        let addSystem: (Room, String, SoundSystemKind) -> Void
        let performDelete: (Deletion) -> Void

        func body(content: Content) -> some View {
            content
                .alert(namingTitle, isPresented: isPresented($naming), presenting: naming) { naming in
                    TextField(namingField(naming), text: $draft)
                    Button(naming.isNew ? RoomsText.add : RoomsText.save) { performNaming(naming) }
                    Button(RoomsText.cancel, role: .cancel) {}
                } message: { naming in
                    if naming.isNew { Text(RoomsText.newRoomMessage) }
                }
                .confirmationDialog(
                    deletionTitle, isPresented: isPresented($deleting), titleVisibility: .visible, presenting: deleting
                ) { deletion in
                    Button(deletion.confirmLabel, role: .destructive) { performDelete(deletion) }
                    Button(RoomsText.cancel, role: .cancel) {}
                } message: { deletion in
                    Text(deletion.message)
                }
                .alert(
                    blocked == .lastRoom ? RoomsText.lastRoomTitle : RoomsText.lastSystemTitle,
                    isPresented: isPresented($blocked)
                ) {
                    Button(RoomsText.ok, role: .cancel) {}
                } message: {
                    Text(blocked == .lastRoom ? RoomsText.lastRoomMessage : RoomsText.lastSystemMessage)
                }
                .alert(RoomsText.failureTitle, isPresented: $failed) {
                    Button(RoomsText.ok, role: .cancel) {}
                } message: {
                    Text(RoomsText.failureMessage)
                }
                .sheet(item: $addingSystemTo) { room in
                    NewSystemForm(
                        defaultName: StoreText.newSystemName(existing: room.systems.count),
                        onAdd: { name, kind in addSystem(room, name, kind) }
                    )
                }
        }

        private func isPresented<Item>(_ item: Binding<Item?>) -> Binding<Bool> {
            Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })
        }

        private var namingTitle: String {
            switch naming {
            case .newRoom: RoomsText.newRoomTitle
            case .room: RoomsText.renameRoomTitle
            case .system: RoomsText.renameSystemTitle
            case nil: ""
            }
        }

        private func namingField(_ naming: Naming) -> String {
            if case .system = naming { RoomsText.systemNameField } else { RoomsText.roomNameField }
        }

        private var deletionTitle: String {
            switch deleting {
            case .room(let room): RoomsText.deleteRoomTitle(room.name)
            case .system(let system): RoomsText.deleteSystemTitle(system.name)
            case nil: ""
            }
        }
    }
}

private extension RoomsSheet.Naming {
    var isNew: Bool { if case .newRoom = self { true } else { false } }
}

private extension RoomsSheet.Deletion {
    var confirmLabel: String {
        switch self {
        case .room: RoomsText.deleteRoomConfirm
        case .system: RoomsText.deleteSystemConfirm
        }
    }

    /// Says what goes with it.
    var message: String {
        switch self {
        case .room(let room): RoomsText.deleteRoomMessage(StoreCounts(room: room))
        case .system(let system): RoomsText.deleteSystemMessage(StoreCounts(system: system))
        }
    }
}

// MARK: - Rows

/// A room's name above its systems; in edit mode, with Rename and Delete.
private struct RoomHeader: View {
    let room: Room
    let isEditing: Bool
    let onRename: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: ResoniqSpace.s3) {
            Text(room.name)
                .font(ResoniqFont.rowTitle)
                .foregroundStyle(ResoniqColor.ivory)
                .textCase(nil)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            if isEditing {
                Button(RoomsText.rename, action: onRename)
                    .buttonStyle(ResoniqInlineLinkStyle())
                    .accessibilityLabel("\(RoomsText.rename) \(room.name)")
                Button(RoomsText.delete, action: onDelete)
                    .buttonStyle(ResoniqInlineLinkStyle(.deviation))
                    .accessibilityLabel("\(RoomsText.delete) \(room.name)")
            }
        }
        .frame(minHeight: ResoniqSize.touchMin)
        .contextMenu {
            Button(RoomsText.rename, action: onRename)
            Button(RoomsText.delete, role: .destructive, action: onDelete)
        }
        .accessibilityAction(named: RoomsText.rename, onRename)
        .accessibilityAction(named: RoomsText.delete, onDelete)
    }
}

/// A sound system: its name and kind, marked when selected (with a tick and the word, not by colour alone).
/// Swipe left for Rename and Delete; VoiceOver gets the same as actions.
private struct SystemRow: View {
    let system: SoundSystem
    let room: Room
    let isSelected: Bool
    let isEditing: Bool
    let onSelect: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Group {
            if isEditing {
                HStack(spacing: ResoniqSpace.s3) {
                    label
                    Button(RoomsText.rename, action: onRename)
                        .buttonStyle(ResoniqInlineLinkStyle())
                        .accessibilityLabel("\(RoomsText.rename) \(system.name)")
                    Button(RoomsText.delete, action: onDelete)
                        .buttonStyle(ResoniqInlineLinkStyle(.deviation))
                        .accessibilityLabel("\(RoomsText.delete) \(system.name)")
                }
            } else {
                Button(action: onSelect) {
                    HStack(spacing: ResoniqSpace.s3) {
                        label
                        if isSelected {
                            HStack(spacing: ResoniqSpace.s1) {
                                ResoniqIconView(.check)
                                Text(RoomsText.selected).font(ResoniqFont.caption)
                            }
                            .foregroundStyle(ResoniqColor.lime)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    RoomsText.systemLabel(name: system.name, kind: system.kind.displayName, room: room.name)
                )
                .accessibilityValue(isSelected ? RoomsText.selected : "")
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .frame(minHeight: ResoniqSize.touchMin)
        .listRowBackground(ResoniqColor.panel)
        .listRowInsets(EdgeInsets(top: 0, leading: ResoniqSpace.screenInset, bottom: 0, trailing: ResoniqSpace.screenInset))
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(RoomsText.delete, role: .destructive, action: onDelete)
            Button(RoomsText.rename, action: onRename).tint(ResoniqColor.guide)
        }
        .accessibilityAction(named: RoomsText.rename, onRename)
        .accessibilityAction(named: RoomsText.delete, onDelete)
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: ResoniqSpace.s1) {
            Text(system.name).font(ResoniqFont.bodyMedium).foregroundStyle(ResoniqColor.ivory)
            Text(system.kind.displayName).font(ResoniqFont.caption).foregroundStyle(ResoniqColor.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - New system

/// Name and kind of a new sound system. Nothing about make or model.
private struct NewSystemForm: View {
    let defaultName: String
    let onAdd: (String, SoundSystemKind) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var kind = SoundSystemKind.stereoPair

    var body: some View {
        NavigationStack {
            Form {
                Section(RoomsText.nameHeader) {
                    TextField(defaultName, text: $name)
                        .font(ResoniqFont.body)
                        .accessibilityLabel(RoomsText.systemNameField)
                }
                .listRowBackground(ResoniqColor.panel)
                Section {
                    Picker(RoomsText.kindHeader, selection: $kind) {
                        ForEach(SoundSystemKind.allCases, id: \.self) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text(RoomsText.kindHeader)
                } footer: {
                    Text(RoomsText.kindFootnote)
                }
                .listRowBackground(ResoniqColor.panel)
            }
            .scrollContentBackground(.hidden)
            .background(ResoniqColor.ink)
            .navigationTitle(RoomsText.newSystemTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(RoomsText.cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(RoomsText.add) {
                        onAdd(name, kind)
                        dismiss()
                    }
                }
            }
        }
        .tint(ResoniqColor.ivory)
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large])
        .presentationBackground(ResoniqColor.ink)
        .presentationCornerRadius(ResoniqRadius.sheet)
    }
}

// MARK: - Previews

#if DEBUG
/// A store with the default room and system, and optionally a second room and more systems.
@MainActor
func roomsPreviewStore(seeded: Bool) -> ResoniqStore {
    guard let store = try? ResoniqStore(inMemory: true) else { fatalError("In-memory store failed") }
    guard let (living, stereo) = try? store.defaultContext() else { return store }
    guard seeded else { return store }
    _ = try? store.rename(living, to: "Living room")
    _ = try? store.addSystem(name: "Soundbar", kind: .soundbar, to: living)
    if let study = try? store.addRoom(name: "Study") {
        _ = try? store.addSystem(name: "Desk speakers", kind: .stereoPair, to: study)
    }
    try? store.select(stereo)
    return store
}

#Preview("Rooms and systems") {
    let store = roomsPreviewStore(seeded: true)
    Color.clear.sheet(isPresented: .constant(true)) {
        RoomsSheet(onClose: {})
            .environment(\.resoniqStore, store)
            .modelContainer(store.container)
    }
}

#Preview("Only the default") {
    let store = roomsPreviewStore(seeded: false)
    Color.clear.sheet(isPresented: .constant(true)) {
        RoomsSheet(onClose: {})
            .environment(\.resoniqStore, store)
            .modelContainer(store.container)
    }
}

#Preview("Largest text") {
    let store = roomsPreviewStore(seeded: true)
    Color.clear.sheet(isPresented: .constant(true)) {
        RoomsSheet(onClose: {})
            .environment(\.resoniqStore, store)
            .modelContainer(store.container)
            .dynamicTypeSize(.accessibility2)
    }
}
#endif
