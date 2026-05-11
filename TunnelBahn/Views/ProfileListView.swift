import SwiftUI
import AppKit

private let dragType = NSPasteboard.PasteboardType("com.tunnelbahn.profile-id")

private final class ProfileRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { false }
        set {}
    }

    override func drawSelection(in dirtyRect: NSRect) {
        NSColor.controlAccentColor.withAlphaComponent(0.15).setFill()
        NSBezierPath(rect: bounds).fill()
    }
}

struct ProfileListView: NSViewRepresentable {
    let profiles: [WireGuardProfile]
    let selectedProfileID: UUID?
    let onSelect: (UUID) -> Void
    let onMove: (IndexSet, Int) -> Void
    let rowContent: (WireGuardProfile) -> NSView

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let tableView = NSTableView()
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

        context.coordinator.tableView = tableView

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        return scroll
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let tableView = scrollView.documentView as! NSTableView
        context.coordinator.parent = self

        let newIDs = profiles.map(\.id)
        let newNames = profiles.map(\.name)

        if context.coordinator.profileIDs != newIDs || context.coordinator.profileNames != newNames {
            context.coordinator.profileIDs = newIDs
            context.coordinator.profileNames = newNames
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

        init(_ parent: ProfileListView) {
            self.parent = parent
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
