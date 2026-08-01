import SwiftUI
import AppKit

private let dragType = NSPasteboard.PasteboardType("com.tunnelbahn.profile-id")

private final class SelectOnRightClickTableView: NSTableView {
    var menuProvider: ((Int) -> NSMenu?)?
    private var hoveredRow: Int = -1
    private var hoverTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = hoverTrackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updateHoveredRow(for: event)
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        updateHoveredRow(for: event)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        setHoveredRow(-1)
    }

    private func updateHoveredRow(for event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        setHoveredRow(row(at: point))
    }

    private func setHoveredRow(_ row: Int) {
        guard row != hoveredRow else { return }
        let old = hoveredRow
        hoveredRow = row
        for r in [old, row] where r >= 0 {
            (rowView(atRow: r, makeIfNecessary: false) as? ProfileRowView)?.isHovered = (r == row)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        guard row >= 0 else { return nil }
        if !selectedRowIndexes.contains(row) {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        return menuProvider?(row)
    }
}

private final class ProfileRowView: NSTableRowView {
    var isHovered: Bool = false {
        didSet { if oldValue != isHovered { setNeedsDisplay(bounds) } }
    }

    override var isEmphasized: Bool {
        get { false }
        set {}
    }

    override func drawBackground(in dirtyRect: NSRect) {
        if isHovered && !isSelected {
            NSColor.controlAccentColor.withAlphaComponent(0.07).setFill()
            NSBezierPath(rect: bounds).fill()
        }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        NSColor.controlAccentColor.withAlphaComponent(0.15).setFill()
        NSBezierPath(rect: bounds).fill()
    }
}

struct ProfileListView: NSViewRepresentable {
    let profiles: [WireGuardProfile]
    let selectedProfileID: UUID?
    let connectedProfileID: UUID?
    let isBusy: Bool
    let onSelect: (UUID) -> Void
    let onDoubleClick: (WireGuardProfile) -> Void
    let onMove: (IndexSet, Int) -> Void
    let rowContent: (WireGuardProfile) -> NSView
    let onContextMenu: (WireGuardProfile) -> NSMenu

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let tableView = SelectOnRightClickTableView()
        tableView.delegate = context.coordinator
        tableView.dataSource = context.coordinator
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.style = .plain

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("profile"))
        column.isEditable = false
        tableView.addTableColumn(column)

        tableView.registerForDraggedTypes([dragType])
        tableView.setDraggingSourceOperationMask(.move, forLocal: true)

        let coordinator = context.coordinator
        tableView.menuProvider = { row in
            coordinator.menuForRow(row)
        }
        tableView.target = coordinator
        tableView.doubleAction = #selector(Coordinator.handleDoubleClick(_:))

        context.coordinator.tableView = tableView

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        return scroll
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let tableView = scrollView.documentView as? NSTableView else { return }
        context.coordinator.parent = self

        let newIDs = profiles.map(\.id)
        let newNames = profiles.map(\.name)
        // Rows render the first peer's endpoint, so it must be part of the reload
        // signature or an endpoint edit leaves the row stale.
        let newEndpoints = profiles.map { $0.peers.first?.endpoint }

        if context.coordinator.profileIDs != newIDs
            || context.coordinator.profileNames != newNames
            || context.coordinator.profileEndpoints != newEndpoints
            || context.coordinator.connectedProfileID != connectedProfileID
            || context.coordinator.isBusy != isBusy {
            context.coordinator.profileIDs = newIDs
            context.coordinator.profileNames = newNames
            context.coordinator.profileEndpoints = newEndpoints
            context.coordinator.connectedProfileID = connectedProfileID
            context.coordinator.isBusy = isBusy
            context.coordinator.cachedViews = profiles.map { rowContent($0) }
            tableView.reloadData()
        }

        // Update selection
        if let selectedID = selectedProfileID,
           let idx = profiles.firstIndex(where: { $0.id == selectedID }) {
            if tableView.selectedRow != idx {
                tableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
            }
        } else {
            tableView.deselectAll(nil)
        }
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: ProfileListView
        weak var tableView: NSTableView?
        var cachedViews: [NSView] = []
        var profileIDs: [UUID] = []
        var profileNames: [String] = []
        var profileEndpoints: [String?] = []
        var connectedProfileID: UUID? = nil
        var isBusy: Bool = false

        init(_ parent: ProfileListView) {
            self.parent = parent
        }

        @objc func handleDoubleClick(_ sender: NSTableView) {
            let row = sender.clickedRow
            guard row >= 0, row < parent.profiles.count else { return }
            parent.onDoubleClick(parent.profiles[row])
        }

        func menuForRow(_ row: Int) -> NSMenu? {
            guard row >= 0, row < parent.profiles.count else { return nil }
            return parent.onContextMenu(parent.profiles[row])
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            parent.profiles.count
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard row < cachedViews.count else { return nil }
            return cachedViews[row]
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            52
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            ProfileRowView()
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
            true
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let tableView = notification.object as? NSTableView else { return }
            let row = tableView.selectedRow
            guard row >= 0, row < parent.profiles.count else { return }
            let id = parent.profiles[row].id
            if id != parent.selectedProfileID {
                parent.onSelect(id)
            }
        }

        // MARK: - Drag source

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            let item = NSPasteboardItem()
            item.setString(parent.profiles[row].id.uuidString, forType: dragType)
            return item
        }

        func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
            session.animatesToStartingPositionsOnCancelOrFail = true
        }

        // MARK: - Drop destination

        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
            guard dropOperation == .above else {
                tableView.setDropRow(row, dropOperation: .above)
                return .move
            }
            return .move
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
            guard let uuidString = info.draggingPasteboard.string(forType: dragType),
                  let draggedID = UUID(uuidString: uuidString),
                  let fromRow = parent.profiles.firstIndex(where: { $0.id == draggedID })
            else { return false }

            parent.onMove(IndexSet(integer: fromRow), row)
            return true
        }
    }
}
