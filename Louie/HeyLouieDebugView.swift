//
//  HeyLouieDebugView.swift
//  Louie
//
//  Read-out of `HeyLouieFakeState` so you can verify tool calls landed
//  while the WebSocket agent narrates over TTS. DEBUG-only.
//

#if DEBUG

    import SwiftUI

    struct HeyLouieDebugView: View {
        @Bindable var state: HeyLouieFakeState

        var body: some View {
            List {
                Section("Music") {
                    LabeledContent("Now playing", value: state.nowPlayingTitle ?? "—")
                    LabeledContent("Id", value: state.nowPlayingId ?? "—")
                    LabeledContent("Playing", value: state.isPlaying ? "yes" : "no")
                    LabeledContent("Volume", value: "\(state.volume)")
                }

                Section("Lights") {
                    ForEach(HeyLouieFakeState.Room.allCases, id: \.self) { room in
                        let isOn = state.lightOn[room] == true
                        let brightness = state.lightBrightness[room] ?? 0
                        LabeledContent(room.displayName) {
                            HStack(spacing: 4) {
                                Text(isOn ? "on" : "off")
                                    .foregroundStyle(isOn ? .primary : .secondary)
                                Text("· \(brightness)%")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section("Climate") {
                    ForEach(HeyLouieFakeState.Room.allCases, id: \.self) { room in
                        LabeledContent(
                            room.displayName,
                            value: String(format: "%.1f°C", state.targetC[room] ?? 0),
                        )
                    }
                }
            }
            .navigationTitle("Hey-Louie state")
        }
    }

    #Preview("Debug view") {
        NavigationStack {
            HeyLouieDebugView(state: {
                let s = HeyLouieFakeState()
                s.nowPlayingId = "$id:genre:jazz"
                s.nowPlayingTitle = "Jazz"
                s.isPlaying = true
                s.lightOn[.kitchen] = true
                s.lightBrightness[.kitchen] = 80
                s.targetC[.bedroom] = 18.5
                return s
            }())
        }
    }

#endif
