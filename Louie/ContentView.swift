//
//  ContentView.swift
//  Louie
//
//  Created by Timm Preetz on 12.05.26.
//

import Linn
import SwiftData
import SwiftUI

struct ContentView: View {
    @State private var linn = Linn()

    var body: some View {
        ContentViewBody(linn: linn)
    }
}

private struct ContentViewBody: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var items: [Item]

    var linn: Linn

    var body: some View {
        NavigationSplitView {
            List {
                ForEach(items) { item in
                    NavigationLink {
                        Text("Item at \(item.timestamp, format: Date.FormatStyle(date: .numeric, time: .standard))")
                    } label: {
                        Text(item.timestamp, format: Date.FormatStyle(date: .numeric, time: .standard))
                    }
                }
                .onDelete(perform: deleteItems)
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    EditButton()
                }
                ToolbarItem {
                    Button(action: addItem) {
                        Label("Add Item", systemImage: "plus")
                    }
                }
            }
        } detail: {
            Text("Select an item")
        }
        .safeAreaInset(edge: .bottom) {
            PlayerBar(state: linn)
                .padding(.horizontal, 50)
        }
        .task {
            linn.start()
        }
        .onDisappear {
            linn.stop()
        }
    }

    private func addItem() {
        withAnimation {
            let newItem = Item(timestamp: Date())
            modelContext.insert(newItem)
        }
    }

    private func deleteItems(offsets: IndexSet) {
        withAnimation {
            for index in offsets {
                modelContext.delete(items[index])
            }
        }
    }
}

#if DEBUG
    private struct ContentViewPreview: View {
        @State private var linn = Linn(
            mockRoom: "Main Room",
            currentSong: Linn.Song(
                id: "chainsmoking",
                title: "Chainsmoking",
                artist: "Jacob Banks",
                artworkURL: URL(string: "https://static.qobuz.com/images/covers/mb/x1/brogg6xqdx1mb_230.jpg")
            ),
            playState: .playing,
            hasNext: true
        )

        var body: some View {
            ContentViewBody(linn: linn)
        }
    }

    #Preview {
        ContentViewPreview()
            .modelContainer(for: Item.self, inMemory: true)
    }
#endif
