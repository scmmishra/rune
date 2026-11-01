//
//  TerminalHardwareKeyRouter.swift
//  libghostty-spm
//

import Foundation
import GhosttyKit

nonisolated enum TerminalHardwareKeyRouter {
    // Every key on every backend travels through `ghostty_surface_key`, so
    // the core's key encoder owns the bytes: DECCKM application-cursor
    // sequences, kitty keyboard protocol, and modifier-aware escapes all
    // stay correct.

    static func ghosttyKey(forAppKitKeyCode keyCode: UInt16) -> ghostty_input_key_e {
        appKitMap[keyCode] ?? GHOSTTY_KEY_UNIDENTIFIED
    }

    /// Sentinel `keycode` value for keys that have no macOS AppKit
    /// equivalent in the pinned Ghostty keycode table (e.g. CUT/COPY/PASTE,
    /// media keys, HELP, FN, NUMPAD_CLEAR). Any value outside the 8-bit
    /// AppKit virtual keycode range falls out of libghostty's native-keycode
    /// lookup and resolves to `.unidentified`. The pinned Ghostty keycode
    /// table uses 8-bit macOS keycodes, so `0x1_0000` stays safely outside
    /// the native range. Using plain `0` would instead collide with AppKit's
    /// keycode for the `A` key.
    static let unidentifiedAppKitKeyCode: UInt32 = 0x10000

    /// Translate a Ghostty key enum to the macOS AppKit virtual keycode
    /// for the same physical key. This is used by synthetic key events
    /// that already know the logical Ghostty key but still need to
    /// satisfy libghostty's native-keycode contract.
    static func appKitKeyCode(for ghosttyKey: ghostty_input_key_e) -> UInt32 {
        guard let macKeyCode = ghosttyKeyToAppKitCode[ghosttyKey.rawValue]
        else { return unidentifiedAppKitKeyCode }
        return UInt32(macKeyCode)
    }

    private static let ghosttyKeyToAppKitCode: [UInt32: UInt16] = {
        var result: [UInt32: UInt16] = [:]
        for (code, key) in appKitMap {
            result[key.rawValue] = code
        }
        return result
    }()

    private typealias Pair = (UInt16, ghostty_input_key_e)

    /// The mac column of libghostty's `src/input/keycodes.zig` for every
    /// code its `code_to_key` names. A row absent there (Help, Fn,
    /// NumpadClear, IntlBackslash, IntlYen, IntlRo) stays absent here, or
    /// `hasPlatformKeycode` would promise a key libghostty resolves to
    /// `.unidentified`.
    private static let appKitMap = buildMap(
        literalPairs: [
            (0x00, GHOSTTY_KEY_A), (0x01, GHOSTTY_KEY_S), (0x02, GHOSTTY_KEY_D),
            (0x03, GHOSTTY_KEY_F), (0x04, GHOSTTY_KEY_H), (0x05, GHOSTTY_KEY_G),
            (0x06, GHOSTTY_KEY_Z), (0x07, GHOSTTY_KEY_X), (0x08, GHOSTTY_KEY_C),
            (0x09, GHOSTTY_KEY_V),
            (0x0B, GHOSTTY_KEY_B), (0x0C, GHOSTTY_KEY_Q),
            (0x0D, GHOSTTY_KEY_W), (0x0E, GHOSTTY_KEY_E), (0x0F, GHOSTTY_KEY_R),
            (0x10, GHOSTTY_KEY_Y), (0x11, GHOSTTY_KEY_T), (0x12, GHOSTTY_KEY_DIGIT_1),
            (0x13, GHOSTTY_KEY_DIGIT_2), (0x14, GHOSTTY_KEY_DIGIT_3), (0x15, GHOSTTY_KEY_DIGIT_4),
            (0x16, GHOSTTY_KEY_DIGIT_6), (0x17, GHOSTTY_KEY_DIGIT_5), (0x18, GHOSTTY_KEY_EQUAL),
            (0x19, GHOSTTY_KEY_DIGIT_9), (0x1A, GHOSTTY_KEY_DIGIT_7), (0x1B, GHOSTTY_KEY_MINUS),
            (0x1C, GHOSTTY_KEY_DIGIT_8), (0x1D, GHOSTTY_KEY_DIGIT_0), (0x1E, GHOSTTY_KEY_BRACKET_RIGHT),
            (0x1F, GHOSTTY_KEY_O), (0x20, GHOSTTY_KEY_U), (0x21, GHOSTTY_KEY_BRACKET_LEFT),
            (0x22, GHOSTTY_KEY_I), (0x23, GHOSTTY_KEY_P), (0x24, GHOSTTY_KEY_ENTER),
            (0x25, GHOSTTY_KEY_L), (0x26, GHOSTTY_KEY_J), (0x27, GHOSTTY_KEY_QUOTE),
            (0x28, GHOSTTY_KEY_K), (0x29, GHOSTTY_KEY_SEMICOLON), (0x2A, GHOSTTY_KEY_BACKSLASH),
            (0x2B, GHOSTTY_KEY_COMMA), (0x2C, GHOSTTY_KEY_SLASH), (0x2D, GHOSTTY_KEY_N),
            (0x2E, GHOSTTY_KEY_M), (0x2F, GHOSTTY_KEY_PERIOD), (0x30, GHOSTTY_KEY_TAB),
            (0x31, GHOSTTY_KEY_SPACE), (0x32, GHOSTTY_KEY_BACKQUOTE), (0x33, GHOSTTY_KEY_BACKSPACE),
            (0x35, GHOSTTY_KEY_ESCAPE), (0x36, GHOSTTY_KEY_META_RIGHT), (0x37, GHOSTTY_KEY_META_LEFT),
            (0x38, GHOSTTY_KEY_SHIFT_LEFT), (0x39, GHOSTTY_KEY_CAPS_LOCK), (0x3A, GHOSTTY_KEY_ALT_LEFT),
            (0x3B, GHOSTTY_KEY_CONTROL_LEFT), (0x3C, GHOSTTY_KEY_SHIFT_RIGHT), (0x3D, GHOSTTY_KEY_ALT_RIGHT),
            (0x3E, GHOSTTY_KEY_CONTROL_RIGHT), (0x40, GHOSTTY_KEY_F17),
            (0x41, GHOSTTY_KEY_NUMPAD_DECIMAL),
            (0x43, GHOSTTY_KEY_NUMPAD_MULTIPLY), (0x45, GHOSTTY_KEY_NUMPAD_ADD), (0x47, GHOSTTY_KEY_NUM_LOCK),
            (0x48, GHOSTTY_KEY_AUDIO_VOLUME_UP), (0x49, GHOSTTY_KEY_AUDIO_VOLUME_DOWN),
            (0x4A, GHOSTTY_KEY_AUDIO_VOLUME_MUTE), (0x4B, GHOSTTY_KEY_NUMPAD_DIVIDE),
            (0x4C, GHOSTTY_KEY_NUMPAD_ENTER), (0x4E, GHOSTTY_KEY_NUMPAD_SUBTRACT),
            (0x4F, GHOSTTY_KEY_F18), (0x50, GHOSTTY_KEY_F19), (0x51, GHOSTTY_KEY_NUMPAD_EQUAL),
            (0x52, GHOSTTY_KEY_NUMPAD_0), (0x53, GHOSTTY_KEY_NUMPAD_1),
            (0x54, GHOSTTY_KEY_NUMPAD_2), (0x55, GHOSTTY_KEY_NUMPAD_3), (0x56, GHOSTTY_KEY_NUMPAD_4),
            (0x57, GHOSTTY_KEY_NUMPAD_5), (0x58, GHOSTTY_KEY_NUMPAD_6), (0x59, GHOSTTY_KEY_NUMPAD_7),
            (0x5A, GHOSTTY_KEY_F20),
            (0x5B, GHOSTTY_KEY_NUMPAD_8), (0x5C, GHOSTTY_KEY_NUMPAD_9), (0x60, GHOSTTY_KEY_F5),
            (0x61, GHOSTTY_KEY_F6), (0x62, GHOSTTY_KEY_F7), (0x63, GHOSTTY_KEY_F3),
            (0x64, GHOSTTY_KEY_F8), (0x65, GHOSTTY_KEY_F9), (0x67, GHOSTTY_KEY_F11),
            (0x69, GHOSTTY_KEY_F13), (0x6A, GHOSTTY_KEY_F16), (0x6B, GHOSTTY_KEY_F14),
            (0x6D, GHOSTTY_KEY_F10), (0x6E, GHOSTTY_KEY_CONTEXT_MENU), (0x6F, GHOSTTY_KEY_F12),
            (0x71, GHOSTTY_KEY_F15),
            (0x72, GHOSTTY_KEY_INSERT), (0x73, GHOSTTY_KEY_HOME), (0x74, GHOSTTY_KEY_PAGE_UP),
            (0x75, GHOSTTY_KEY_DELETE), (0x76, GHOSTTY_KEY_F4), (0x77, GHOSTTY_KEY_END),
            (0x78, GHOSTTY_KEY_F2), (0x79, GHOSTTY_KEY_PAGE_DOWN), (0x7A, GHOSTTY_KEY_F1),
            (0x7B, GHOSTTY_KEY_ARROW_LEFT), (0x7C, GHOSTTY_KEY_ARROW_RIGHT),
            (0x7D, GHOSTTY_KEY_ARROW_DOWN), (0x7E, GHOSTTY_KEY_ARROW_UP),
        ],
        groupedPairs: []
    )

    private static func buildMap(
        literalPairs: [Pair],
        groupedPairs: [[Pair]]
    ) -> [UInt16: ghostty_input_key_e] {
        var map: [UInt16: ghostty_input_key_e] = [:]
        for (code, key) in literalPairs {
            map[code] = key
        }
        for group in groupedPairs {
            for (code, key) in group {
                map[code] = key
            }
        }
        return map
    }
}
