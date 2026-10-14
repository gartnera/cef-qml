#pragma once

#include <Qt>

class QInputEvent;

// Qt::Key -> Windows virtual-key code (ui::KeyboardCode), which is what
// CefKeyEvent::windows_key_code expects on every platform.
int qtKeyToWindowsKeyCode(int qtKey, Qt::KeyboardModifiers modifiers);

// Qt modifiers/buttons -> cef_event_flags_t.
unsigned cefModifiers(Qt::KeyboardModifiers modifiers, Qt::MouseButtons buttons,
                      bool keypad = false);
