#include "keymap.h"

#include "include/internal/cef_types.h"

int qtKeyToWindowsKeyCode(int key, Qt::KeyboardModifiers modifiers) {
  // Letters and digits map 1:1 to their ASCII upper-case value.
  if (key >= Qt::Key_A && key <= Qt::Key_Z)
    return key;
  if (key >= Qt::Key_0 && key <= Qt::Key_9) {
    if (modifiers & Qt::KeypadModifier)
      return 0x60 + (key - Qt::Key_0);  // VK_NUMPAD0..9
    return key;
  }
  if (key >= Qt::Key_F1 && key <= Qt::Key_F24)
    return 0x70 + (key - Qt::Key_F1);  // VK_F1..F24

  switch (key) {
    case Qt::Key_Backspace: return 0x08;
    case Qt::Key_Tab:
    case Qt::Key_Backtab: return 0x09;
    case Qt::Key_Clear: return 0x0C;
    case Qt::Key_Return:
    case Qt::Key_Enter: return 0x0D;
    case Qt::Key_Shift: return 0x10;
    case Qt::Key_Control: return 0x11;
    case Qt::Key_Alt:
    case Qt::Key_AltGr: return 0x12;
    case Qt::Key_Pause: return 0x13;
    case Qt::Key_CapsLock: return 0x14;
    case Qt::Key_Escape: return 0x1B;
    case Qt::Key_Space: return 0x20;
    case Qt::Key_PageUp: return 0x21;
    case Qt::Key_PageDown: return 0x22;
    case Qt::Key_End: return 0x23;
    case Qt::Key_Home: return 0x24;
    case Qt::Key_Left: return 0x25;
    case Qt::Key_Up: return 0x26;
    case Qt::Key_Right: return 0x27;
    case Qt::Key_Down: return 0x28;
    case Qt::Key_Select: return 0x29;
    case Qt::Key_Print: return 0x2C;
    case Qt::Key_Execute: return 0x2B;
    case Qt::Key_Insert: return 0x2D;
    case Qt::Key_Delete: return 0x2E;
    case Qt::Key_Help: return 0x2F;
    case Qt::Key_Meta:
    case Qt::Key_Super_L: return 0x5B;
    case Qt::Key_Super_R: return 0x5C;
    case Qt::Key_Menu: return 0x5D;
    case Qt::Key_Sleep: return 0x5F;
    case Qt::Key_Asterisk: return (modifiers & Qt::KeypadModifier) ? 0x6A : 0x38;
    case Qt::Key_Plus: return (modifiers & Qt::KeypadModifier) ? 0x6B : 0xBB;
    case Qt::Key_Minus: return (modifiers & Qt::KeypadModifier) ? 0x6D : 0xBD;
    case Qt::Key_Period: return (modifiers & Qt::KeypadModifier) ? 0x6E : 0xBE;
    case Qt::Key_Slash: return (modifiers & Qt::KeypadModifier) ? 0x6F : 0xBF;
    case Qt::Key_NumLock: return 0x90;
    case Qt::Key_ScrollLock: return 0x91;
    case Qt::Key_Back: return 0xA6;
    case Qt::Key_Forward: return 0xA7;
    case Qt::Key_Refresh: return 0xA8;
    case Qt::Key_Stop: return 0xA9;
    case Qt::Key_Search: return 0xAA;
    case Qt::Key_Favorites: return 0xAB;
    case Qt::Key_HomePage: return 0xAC;
    case Qt::Key_VolumeMute: return 0xAD;
    case Qt::Key_VolumeDown: return 0xAE;
    case Qt::Key_VolumeUp: return 0xAF;
    case Qt::Key_MediaNext: return 0xB0;
    case Qt::Key_MediaPrevious: return 0xB1;
    case Qt::Key_MediaStop: return 0xB2;
    case Qt::Key_MediaPlay:
    case Qt::Key_MediaPause:
    case Qt::Key_MediaTogglePlayPause: return 0xB3;
    case Qt::Key_LaunchMail: return 0xB4;
    // OEM keys (US layout positions).
    case Qt::Key_Semicolon:
    case Qt::Key_Colon: return 0xBA;
    case Qt::Key_Equal: return 0xBB;
    case Qt::Key_Comma:
    case Qt::Key_Less: return 0xBC;
    case Qt::Key_Underscore: return 0xBD;
    case Qt::Key_Greater: return 0xBE;
    case Qt::Key_Question: return 0xBF;
    case Qt::Key_QuoteLeft:
    case Qt::Key_AsciiTilde: return 0xC0;
    case Qt::Key_BracketLeft:
    case Qt::Key_BraceLeft: return 0xDB;
    case Qt::Key_Backslash:
    case Qt::Key_Bar: return 0xDC;
    case Qt::Key_BracketRight:
    case Qt::Key_BraceRight: return 0xDD;
    case Qt::Key_Apostrophe:
    case Qt::Key_QuoteDbl: return 0xDE;
    // Shifted digits on a US layout.
    case Qt::Key_Exclam: return '1';
    case Qt::Key_At: return '2';
    case Qt::Key_NumberSign: return '3';
    case Qt::Key_Dollar: return '4';
    case Qt::Key_Percent: return '5';
    case Qt::Key_AsciiCircum: return '6';
    case Qt::Key_Ampersand: return '7';
    case Qt::Key_ParenLeft: return '9';
    case Qt::Key_ParenRight: return '0';
    default: return 0;
  }
}

unsigned cefModifiers(Qt::KeyboardModifiers m, Qt::MouseButtons b, bool keypad) {
  unsigned f = EVENTFLAG_NONE;
  if (m & Qt::ShiftModifier) f |= EVENTFLAG_SHIFT_DOWN;
  if (m & Qt::ControlModifier) f |= EVENTFLAG_CONTROL_DOWN;
  if (m & Qt::AltModifier) f |= EVENTFLAG_ALT_DOWN;
  if (m & Qt::MetaModifier) f |= EVENTFLAG_COMMAND_DOWN;
  if (keypad || (m & Qt::KeypadModifier)) f |= EVENTFLAG_IS_KEY_PAD;
  if (b & Qt::LeftButton) f |= EVENTFLAG_LEFT_MOUSE_BUTTON;
  if (b & Qt::MiddleButton) f |= EVENTFLAG_MIDDLE_MOUSE_BUTTON;
  if (b & Qt::RightButton) f |= EVENTFLAG_RIGHT_MOUSE_BUTTON;
  return f;
}
