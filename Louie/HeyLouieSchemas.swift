//
//  HeyLouieSchemas.swift
//  Louie
//
//  Tool catalog sent to the Hey-Louie backend in the `hello` frame. The
//  backend does not hardcode tool definitions — whatever the iPad sends is
//  what the model sees. Descriptions are load-bearing (the model picks
//  tools off them); keep them verbatim with the backend's reference impl in
//  `backend/evals/fake_louie.py:LOUIE_TOOL_SCHEMAS`. Encoded as nested
//  dictionaries because (a) it mirrors the Python source-of-truth shape and
//  (b) it's pure static data built once on the main actor before encoding
//  into the `hello` payload, so there is no Sendable boundary crossed.
//

import Foundation

enum HeyLouieSchemas {
    static let all: [[String: Any]] = [
        [
            "name": "search_music",
            "description": """
                Find a playable music id for a user's request before calling play_music. \
                Use this for any phrase that names a genre, artist, album, song, or playlist \
                (e.g. 'jazz', 'Queen', 'Thriller', 'something ambient'). Returns a JSON array \
                of hits, each shaped {id, type, title}. The `id` is opaque — pass it verbatim \
                to play_music. If the array is empty, tell the user you couldn't find it; do \
                not invent ids. If multiple hits come back: pick the one whose `type` and \
                `title` clearly match what the user said (e.g. 'play the Thriller album' → \
                the type='album' hit; 'play Queen' → the type='artist' hit). Only ask for \
                clarification (via ask_user) when the request is genuinely ambiguous and no \
                hit is a confident match — never silently pick the first hit as a fallback.
                """,
            "input_schema": [
                "type": "object",
                "properties": [
                    "query": [
                        "type": "string",
                        "description": "The user's phrasing, lightly normalized. E.g. 'jazz', 'Thriller', 'Queen'.",
                    ],
                    "type": [
                        "type": "string",
                        "enum": ["artist", "album", "genre", "playlist", "track"],
                        "description": "Optional filter when the user was explicit (e.g. 'the Thriller album' → type='album'). Omit when the user was vague.",
                    ],
                ],
                "required": ["query"],
            ],
        ],
        [
            "name": "play_music",
            "description": """
                Start playback of a specific item. The `id` argument MUST be a value returned \
                from a prior search_music call in this turn — do not synthesize ids, do not pass \
                raw queries like 'jazz'. If you don't have an id yet, call search_music first.
                """,
            "input_schema": [
                "type": "object",
                "properties": [
                    "id": [
                        "type": "string",
                        "description": "An opaque id from search_music, shaped like '$id:<type>:<slug>'.",
                    ],
                ],
                "required": ["id"],
            ],
        ],
        [
            "name": "control_lights",
            "description": """
                Turn a room's lights on or off, set brightness, or both. At least one of `on` \
                or `brightness` is required. Passing brightness > 0 without `on` is treated as \
                'turn it on at that level'. To change brightness without turning the light on, \
                pass on=false explicitly (the brightness value is stored for the next time it's \
                turned on). Available rooms: living_room, kitchen, bedroom.
                """,
            "input_schema": [
                "type": "object",
                "properties": [
                    "room": [
                        "type": "string",
                        "enum": ["living_room", "kitchen", "bedroom"],
                        "description": "The room whose lights to control.",
                    ],
                    "on": ["type": "boolean", "description": "True to turn on, false to turn off. Optional."],
                    "brightness": [
                        "type": "integer",
                        "minimum": 0,
                        "maximum": 100,
                        "description": "Brightness percentage, 0-100. Optional.",
                    ],
                ],
                "required": ["room"],
            ],
        ],
        [
            "name": "set_climate",
            "description": """
                Set a room's target temperature in degrees Celsius. The user may say the unit \
                or not; assume Celsius unless they explicitly say Fahrenheit (in which case \
                convert before calling). Reasonable range is 5-35°C.
                """,
            "input_schema": [
                "type": "object",
                "properties": [
                    "room": [
                        "type": "string",
                        "enum": ["living_room", "kitchen", "bedroom"],
                        "description": "The room whose climate to set.",
                    ],
                    "target_c": [
                        "type": "number",
                        "minimum": 5.0,
                        "maximum": 35.0,
                        "description": "Target temperature in Celsius.",
                    ],
                ],
                "required": ["room", "target_c"],
            ],
        ],
        [
            "name": "query_state",
            "description": """
                Read the current state of the house. Use this before answering questions like \
                'what's playing?', 'is the kitchen light on?', 'what's the bedroom set to?'. \
                Returns a JSON snapshot. Prefer the narrowest `subsystem` for the question; \
                use 'all' only when the user asked for a broad status.
                """,
            "input_schema": [
                "type": "object",
                "properties": [
                    "subsystem": [
                        "type": "string",
                        "enum": ["music", "lights", "climate", "all"],
                        "description": "Which subsystem to read. Default 'all'.",
                    ],
                ],
            ],
        ],
        [
            "name": "ask_user",
            "description": """
                Ask the user to disambiguate between concrete options when their request is \
                genuinely ambiguous AND picking the wrong default would noticeably annoy them. \
                The user sees a tap popover (not a re-record) with the choices you provide; the \
                tool_result is the picked {id, label}. USE SPARINGLY — prefer confident action \
                with a one-sentence narration over asking. Never ask about which room or what \
                temperature; pick a sensible default and say what you did. Only call this when \
                (a) two or more plausible interpretations exist (e.g. 'play Thriller' → song or \
                album?) AND (b) no prior tool result already resolves the ambiguity. The `id` \
                strings you supply MUST be tokens that make sense for your follow-up action — \
                typically values returned from a previous tool call (e.g. search_music hit ids), \
                not free-form strings.
                """,
            "input_schema": [
                "type": "object",
                "properties": [
                    "question": [
                        "type": "string",
                        "description": "Short, spoken-aloud-friendly question. No markdown, no preamble like 'sure!'. Examples: 'The song or the album?', 'Which Coldplay album?'.",
                    ],
                    "choices": [
                        "type": "array",
                        "minItems": 2,
                        "maxItems": 5,
                        "description": "2-5 distinct options the user can tap.",
                        "items": [
                            "type": "object",
                            "properties": [
                                "id": [
                                    "type": "string",
                                    "description": "Opaque token to act on after the tap (e.g. a search_music id).",
                                ],
                                "label": [
                                    "type": "string",
                                    "description": "Short human-facing label, 1-4 words.",
                                ],
                            ],
                            "required": ["id", "label"],
                        ],
                    ],
                ],
                "required": ["question", "choices"],
            ],
        ],
    ]
}
