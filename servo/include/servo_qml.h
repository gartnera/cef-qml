// C API of libservo_qml: a thin wrapper around the Servo embedding API
// (the `servo` Rust crate), made for ServoWebView (src/servo/).
//
// Threading: everything here must be called on the thread that called
// servo_qml_init (the Qt GUI thread), except the wake callback, which
// Servo calls from any thread. Callbacks run synchronously inside
// servo_qml_spin or a view function; strings passed to them are UTF-8
// and only valid during the call.
//
// Coordinates and sizes are device pixels.
#pragma once

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ServoQmlView ServoQmlView;

typedef struct {
  // Servo wants servo_qml_spin to be called soon, on the init thread.
  // Called from any thread.
  void (*wake)(void* user);
  void* user;
  // Profile directory (cookies, local storage, HTTP cache), or NULL for
  // temporary in-memory storage.
  const char* config_dir;
  // PEM file of extra trusted CA certificates, or NULL.
  const char* certificate_path;
} ServoQmlConfig;

// Starts Servo. Returns false if it is already running or was shut down
// (Servo can be started once per process).
bool servo_qml_init(const ServoQmlConfig* config);
// Runs pending Servo work; call after every wake.
void servo_qml_spin(void);
// Shuts Servo down; blocks until it has. Views must be freed first.
void servo_qml_shutdown(void);
bool servo_qml_running(void);

enum {
  SERVO_QML_LOAD_STARTED = 0,
  SERVO_QML_LOAD_HEAD_PARSED = 1,
  SERVO_QML_LOAD_COMPLETE = 2,
};

typedef struct {
  // A new frame: tightly packed RGBA8, top row first.
  void (*frame)(void* user, const uint8_t* rgba, uint32_t width, uint32_t height);
  void (*url_changed)(void* user, const char* url);
  void (*title_changed)(void* user, const char* title);
  // Link under the pointer, or "" when none.
  void (*status_text_changed)(void* user, const char* text);
  void (*load_status_changed)(void* user, int status);
  void (*history_changed)(void* user, bool can_go_back, bool can_go_forward);
  // A servo::Cursor value (0 None, 1 Default, 2 Pointer, ... see lib.rs).
  void (*cursor_changed)(void* user, int cursor);
  // level: 0 log, 1 debug, 2 info, 3 warn, 4 error, 5 trace.
  void (*console_message)(void* user, int level, const char* message);
  // The page asked to open `url` in a new window (target=_blank,
  // window.open). Servo is told no; the embedder may load it somewhere.
  void (*new_window_requested)(void* user, const char* url);
  void (*crashed)(void* user, const char* reason);
} ServoQmlViewCallbacks;

// Creates a view rendering into its own software (CPU) GL context.
// `url` may be NULL (about:blank). Returns NULL on failure.
ServoQmlView* servo_qml_view_new(uint32_t width, uint32_t height, float scale,
                                 const char* url, const ServoQmlViewCallbacks* callbacks,
                                 void* user);
// No callbacks are made for the view once this returns.
void servo_qml_view_free(ServoQmlView* view);

// Returns false if `url` does not parse.
bool servo_qml_view_load(ServoQmlView* view, const char* url);
void servo_qml_view_reload(ServoQmlView* view);
void servo_qml_view_go_back(ServoQmlView* view);
void servo_qml_view_go_forward(ServoQmlView* view);

void servo_qml_view_resize(ServoQmlView* view, uint32_t width, uint32_t height);
void servo_qml_view_set_scale(ServoQmlView* view, float scale);
void servo_qml_view_set_zoom(ServoQmlView* view, float zoom);
void servo_qml_view_set_visible(ServoQmlView* view, bool visible);
void servo_qml_view_set_focused(ServoQmlView* view, bool focused);

void servo_qml_view_mouse_move(ServoQmlView* view, float x, float y);
void servo_qml_view_mouse_leave(ServoQmlView* view);
// button: DOM MouseEvent.button (0 primary, 1 middle, 2 secondary, 3 back,
// 4 forward).
void servo_qml_view_mouse_button(ServoQmlView* view, bool down, int button, float x, float y);

enum {
  SERVO_QML_WHEEL_PIXEL = 0,
  SERVO_QML_WHEEL_LINE = 1,
  SERVO_QML_WHEEL_PAGE = 2,
};
// Servo's WheelDelta convention (as Qt's angleDelta): positive y scrolls
// up, revealing content above.
void servo_qml_view_wheel(ServoQmlView* view, double dx, double dy, int mode, float x, float y);

enum {
  SERVO_QML_MOD_SHIFT = 1,
  SERVO_QML_MOD_CONTROL = 2,
  SERVO_QML_MOD_ALT = 4,
  SERVO_QML_MOD_META = 8,
};
// `key` and `code` are DOM KeyboardEvent.key / .code strings ("a", "Enter";
// "KeyA", "Enter"). location: DOM KeyboardEvent.location.
void servo_qml_view_key(ServoQmlView* view, bool down, const char* key, const char* code,
                        int location, uint32_t modifiers, bool repeat);

// Evaluates `script` in the page and calls `done` once with the result as
// JSON, or with result NULL and an error message.
typedef void (*ServoQmlJsCallback)(void* user, const char* json, const char* error);
void servo_qml_view_evaluate_javascript(ServoQmlView* view, const char* script,
                                        ServoQmlJsCallback done, void* user);

#ifdef __cplusplus
}
#endif
