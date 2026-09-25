import Foundation
import Testing

@testable import Louie

struct RealtimeVoiceControlClientTests {
    @Test func derivesAgentVoiceURLFromDefaultAgentPath() throws {
        let url = try #require(URL(string: "wss://example.modal.run/agent"))

        #expect(RealtimeVoiceControlClient.agentVoiceURL(from: url).absoluteString == "wss://example.modal.run/agent-voice")
    }

    @Test func derivesAgentVoiceURLFromNestedAgentPath() throws {
        let url = try #require(URL(string: "ws://localhost:8000/dev/agent?token=abc"))

        #expect(RealtimeVoiceControlClient.agentVoiceURL(from: url).absoluteString == "ws://localhost:8000/dev/agent-voice?token=abc")
    }

    @Test func decodesSDPAnswer() throws {
        let message = try RealtimeVoiceControlClient.decode(
            #"{"type":"sdp_answer","sdp":"v=0\r\n","call_id":"rtc_123"}"#
        )

        #expect(message == .sdpAnswer(sdp: "v=0\r\n", callId: "rtc_123"))
    }

    @Test func decodesToolCallInputAsJSONData() throws {
        let message = try RealtimeVoiceControlClient.decode(
            #"{"type":"tool_call","tool_use_id":"call_123","name":"control_lights","input":{"room":"kitchen","on":true}}"#
        )

        guard case let .toolCall(id, name, inputJSON) = message else {
            Issue.record("Expected tool_call")
            return
        }
        #expect(id == "call_123")
        #expect(name == "control_lights")

        let object = try JSONSerialization.jsonObject(with: inputJSON) as? [String: Any]
        #expect(object?["room"] as? String == "kitchen")
        #expect(object?["on"] as? Bool == true)
    }

    @Test func decodesError() throws {
        let message = try RealtimeVoiceControlClient.decode(
            #"{"type":"error","message":"backend unavailable"}"#
        )

        #expect(message == .error("backend unavailable"))
    }

    @Test func decodesDoneAsTerminal() throws {
        let message = try RealtimeVoiceControlClient.decode(#"{"type":"done"}"#)

        #expect(message == .done)
        #expect(message.isTerminal)
    }

    @Test func malformedJSONThrowsDecodeError() {
        #expect(throws: RealtimeVoiceControlClientError.self) {
            try RealtimeVoiceControlClient.decode(#"{"type":"sdp_answer"}"#)
        }
    }
}
