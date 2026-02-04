//
//  RoomPickerView.swift
//  Child Firearm Safety
//
//  Shared picker UI for selecting stored AR rooms.
//

import SwiftUI

struct RoomPickerView: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let emptyMessage: String
    let rooms: [String]
    var onPick: (String) -> Void
    var onDelete: ((String) -> Void)?

    init(title: String = "Choose Room",
         emptyMessage: String = "Create a room first, then save it to see it here.",
         rooms: [String],
         onPick: @escaping (String) -> Void,
         onDelete: ((String) -> Void)? = nil) {
        self.title = title
        self.emptyMessage = emptyMessage
        self.rooms = rooms
        self.onPick = onPick
        self.onDelete = onDelete
    }

    var body: some View {
        Group {
            if rooms.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "tray")
                        .font(.system(size: 44))
                    Text("No saved rooms yet")
                        .font(.headline)
                    Text(emptyMessage)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(rooms, id: \.self) { name in
                    Button { onPick(name) } label: {
                        HStack {
                            Image(systemName: "cube.transparent")
                            Text(name)
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            onDelete?(name)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                    .contextMenu {
                        Button(role: .destructive) {
                            onDelete?(name)
                        } label: {
                            Label("Delete Room", systemImage: "trash")
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
