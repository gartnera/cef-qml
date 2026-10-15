/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

//! libservo_qml: the C API in `include/servo_qml.h` over Servo's Rust
//! embedding API. Servo objects are `Rc`s that live on the thread that
//! called `servo_qml_init`; the C side calls everything from that thread.

use std::cell::{Cell, RefCell};
use std::ffi::{CStr, CString, c_char, c_void};
use std::path::PathBuf;
use std::rc::{Rc, Weak};
use std::str::FromStr;

use euclid::Scale;
use servo::{
    Code, ConsoleLogLevel, CreateNewWebViewRequest, Cursor, DeviceIntRect, DevicePoint,
    EventLoopWaker, InputEvent, JSValue, JavaScriptEvaluationError, Key, KeyState, KeyboardEvent,
    LoadStatus, Location, Modifiers, MouseButton, MouseButtonAction, MouseButtonEvent,
    MouseLeftViewportEvent, MouseMoveEvent, NavigationRequest, Opts, Preferences, RenderingContext,
    Servo, ServoBuilder, SoftwareRenderingContext, WebView, WebViewBuilder, WebViewDelegate,
    WheelDelta, WheelEvent, WheelMode,
};
use url::Url;

type Size = dpi::PhysicalSize<u32>;

#[repr(C)]
pub struct ServoQmlConfig {
    wake: Option<extern "C" fn(*mut c_void)>,
    user: *mut c_void,
    config_dir: *const c_char,
    certificate_path: *const c_char,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct ServoQmlViewCallbacks {
    frame: Option<extern "C" fn(*mut c_void, *const u8, u32, u32)>,
    url_changed: Option<extern "C" fn(*mut c_void, *const c_char)>,
    title_changed: Option<extern "C" fn(*mut c_void, *const c_char)>,
    status_text_changed: Option<extern "C" fn(*mut c_void, *const c_char)>,
    load_status_changed: Option<extern "C" fn(*mut c_void, i32)>,
    history_changed: Option<extern "C" fn(*mut c_void, bool, bool)>,
    cursor_changed: Option<extern "C" fn(*mut c_void, i32)>,
    console_message: Option<extern "C" fn(*mut c_void, i32, *const c_char)>,
    new_window_requested: Option<extern "C" fn(*mut c_void, *const c_char)>,
    crashed: Option<extern "C" fn(*mut c_void, *const c_char)>,
}

#[derive(Clone)]
struct Waker {
    wake: extern "C" fn(*mut c_void),
    user: usize,
}

impl EventLoopWaker for Waker {
    fn clone_box(&self) -> Box<dyn EventLoopWaker> {
        Box::new(self.clone())
    }

    fn wake(&self) {
        (self.wake)(self.user as *mut c_void)
    }
}

enum EngineState {
    NotStarted,
    Running(Servo),
    ShutDown,
}

thread_local! {
    static ENGINE: RefCell<EngineState> = const { RefCell::new(EngineState::NotStarted) };
    // WebViews to drop on the next spin rather than inside one of their own
    // delegate calls.
    static GARBAGE: RefCell<Vec<WebView>> = const { RefCell::new(Vec::new()) };
}

fn engine() -> Option<Servo> {
    ENGINE.with_borrow(|state| match state {
        EngineState::Running(servo) => Some(servo.clone()),
        _ => None,
    })
}

unsafe fn opt_str<'a>(s: *const c_char) -> Option<&'a str> {
    if s.is_null() {
        None
    } else {
        unsafe { CStr::from_ptr(s) }.to_str().ok()
    }
}

fn cstring(s: &str) -> CString {
    CString::new(s.replace('\0', "")).unwrap_or_default()
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn servo_qml_init(config: *const ServoQmlConfig) -> bool {
    if !ENGINE.with_borrow(|s| matches!(s, EngineState::NotStarted)) {
        return false;
    }
    let config = unsafe { &*config };
    let Some(wake) = config.wake else {
        return false;
    };

    let mut opts = Opts::default();
    opts.config_dir = unsafe { opt_str(config.config_dir) }.map(PathBuf::from);
    opts.temporary_storage = opts.config_dir.is_none();
    opts.certificate_path = unsafe { opt_str(config.certificate_path) }.map(String::from);

    // Defaults include the http(s)_proxy / no_proxy environment.
    let preferences = Preferences::default();

    let servo = ServoBuilder::default()
        .opts(opts)
        .preferences(preferences)
        .event_loop_waker(Box::new(Waker {
            wake,
            user: config.user as usize,
        }))
        .build();
    servo.setup_logging();
    ENGINE.set(EngineState::Running(servo));
    true
}

#[unsafe(no_mangle)]
pub extern "C" fn servo_qml_spin() {
    GARBAGE.take();
    if let Some(servo) = engine() {
        servo.spin_event_loop();
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn servo_qml_shutdown() {
    GARBAGE.take();
    // Dropping the last handle shuts Servo down and blocks until it has.
    let state = ENGINE.replace(EngineState::ShutDown);
    drop(state);
}

#[unsafe(no_mangle)]
pub extern "C" fn servo_qml_running() -> bool {
    engine().is_some()
}

struct ViewDelegate {
    callbacks: ServoQmlViewCallbacks,
    user: *mut c_void,
    /// Cleared by servo_qml_view_free: no callbacks after that.
    alive: Cell<bool>,
    rendering_context: Rc<SoftwareRenderingContext>,
    /// Hidden WebViews created for new-window requests; see PopupDelegate.
    popups: RefCell<Vec<WebView>>,
    this: Weak<ViewDelegate>,
}

impl ViewDelegate {
    fn call_str(&self, f: Option<extern "C" fn(*mut c_void, *const c_char)>, s: &str) {
        if let Some(f) = f.filter(|_| self.alive.get()) {
            let s = cstring(s);
            f(self.user, s.as_ptr());
        }
    }

    fn send_frame(&self, webview: &WebView) {
        let Some(frame) = self.callbacks.frame.filter(|_| self.alive.get()) else {
            return;
        };
        let size = self.rendering_context.size();
        let rect =
            DeviceIntRect::from_size(euclid::Size2D::new(size.width as i32, size.height as i32));
        let _ = self.rendering_context.make_current();
        webview.paint();
        if let Some(image) = self.rendering_context.read_to_image(rect) {
            frame(self.user, image.as_ptr(), image.width(), image.height());
        }
    }
}

impl WebViewDelegate for ViewDelegate {
    fn notify_new_frame_ready(&self, webview: WebView) {
        self.send_frame(&webview);
    }

    fn notify_url_changed(&self, _webview: WebView, url: Url) {
        self.call_str(self.callbacks.url_changed, url.as_str());
    }

    fn notify_page_title_changed(&self, _webview: WebView, title: Option<String>) {
        self.call_str(self.callbacks.title_changed, title.as_deref().unwrap_or(""));
    }

    fn notify_status_text_changed(&self, _webview: WebView, status: Option<String>) {
        self.call_str(
            self.callbacks.status_text_changed,
            status.as_deref().unwrap_or(""),
        );
    }

    fn notify_load_status_changed(&self, _webview: WebView, status: LoadStatus) {
        if let Some(f) = self
            .callbacks
            .load_status_changed
            .filter(|_| self.alive.get())
        {
            let status = match status {
                LoadStatus::Started => 0,
                LoadStatus::HeadParsed => 1,
                LoadStatus::Complete => 2,
            };
            f(self.user, status);
        }
    }

    fn notify_history_changed(&self, _webview: WebView, entries: Vec<Url>, current: usize) {
        if let Some(f) = self.callbacks.history_changed.filter(|_| self.alive.get()) {
            f(self.user, current > 0, current + 1 < entries.len());
        }
    }

    fn notify_cursor_changed(&self, _webview: WebView, cursor: Cursor) {
        if let Some(f) = self.callbacks.cursor_changed.filter(|_| self.alive.get()) {
            f(self.user, cursor as i32);
        }
    }

    fn show_console_message(&self, _webview: WebView, level: ConsoleLogLevel, message: String) {
        if let Some(f) = self.callbacks.console_message.filter(|_| self.alive.get()) {
            let level = match level {
                ConsoleLogLevel::Log | ConsoleLogLevel::Dir => 0,
                ConsoleLogLevel::Debug => 1,
                ConsoleLogLevel::Info => 2,
                ConsoleLogLevel::Warn => 3,
                ConsoleLogLevel::Error => 4,
                ConsoleLogLevel::Trace => 5,
            };
            let message = cstring(&message);
            f(self.user, level, message.as_ptr());
        }
    }

    fn notify_crashed(&self, _webview: WebView, reason: String, _backtrace: Option<String>) {
        self.call_str(self.callbacks.crashed, &reason);
    }

    // Servo only creates the new WebView here; the URL it is for arrives
    // later as its first navigation. A hidden WebView with a 1x1 context
    // catches that navigation, reports it and is dropped.
    fn request_create_new(&self, _parent: WebView, request: CreateNewWebViewRequest) {
        if self.callbacks.new_window_requested.is_none() {
            return; // dropping the request denies it
        }
        let Ok(context) = SoftwareRenderingContext::new(Size::new(1, 1)) else {
            return;
        };
        let popup = request
            .builder(Rc::new(context))
            .delegate(Rc::new(PopupDelegate {
                parent: self.this.clone(),
                reported: Cell::new(false),
            }))
            .build();
        self.popups.borrow_mut().push(popup);
    }
}

struct PopupDelegate {
    parent: Weak<ViewDelegate>,
    reported: Cell<bool>,
}

impl PopupDelegate {
    fn finish(&self, popup: &WebView, url: &Url) {
        if self.reported.replace(true) {
            return;
        }
        let Some(parent) = self.parent.upgrade() else {
            return;
        };
        parent.call_str(parent.callbacks.new_window_requested, url.as_str());
        let mut popups = parent.popups.borrow_mut();
        if let Some(index) = popups.iter().position(|p| p.id() == popup.id()) {
            let popup = popups.remove(index);
            GARBAGE.with_borrow_mut(|g| g.push(popup));
        }
    }
}

impl WebViewDelegate for PopupDelegate {
    fn request_navigation(&self, webview: WebView, request: NavigationRequest) {
        if request.url.as_str() == "about:blank" {
            request.allow();
            return;
        }
        let url = request.url.clone();
        request.deny();
        self.finish(&webview, &url);
    }

    fn notify_url_changed(&self, webview: WebView, url: Url) {
        if url.as_str() != "about:blank" {
            self.finish(&webview, &url);
        }
    }
}

pub struct ServoQmlView {
    webview: WebView,
    delegate: Rc<ViewDelegate>,
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn servo_qml_view_new(
    width: u32,
    height: u32,
    scale: f32,
    url: *const c_char,
    callbacks: *const ServoQmlViewCallbacks,
    user: *mut c_void,
) -> *mut ServoQmlView {
    let Some(servo) = engine() else {
        return std::ptr::null_mut();
    };
    let Ok(context) = SoftwareRenderingContext::new(Size::new(width.max(1), height.max(1))) else {
        return std::ptr::null_mut();
    };
    let rendering_context = Rc::new(context);
    let callbacks = unsafe { *callbacks };
    let delegate = Rc::new_cyclic(|this| ViewDelegate {
        callbacks,
        user,
        alive: Cell::new(true),
        rendering_context: rendering_context.clone(),
        popups: RefCell::default(),
        this: this.clone(),
    });
    let url = unsafe { opt_str(url) }
        .and_then(|u| Url::parse(u).ok())
        .unwrap_or_else(|| Url::parse("about:blank").unwrap());
    let webview = WebViewBuilder::new(&servo, rendering_context)
        .url(url)
        .hidpi_scale_factor(Scale::new(if scale > 0.0 { scale } else { 1.0 }))
        .delegate(delegate.clone())
        .build();
    Box::into_raw(Box::new(ServoQmlView { webview, delegate }))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn servo_qml_view_free(view: *mut ServoQmlView) {
    if view.is_null() {
        return;
    }
    let view = unsafe { Box::from_raw(view) };
    view.delegate.alive.set(false);
    let popups = view.delegate.popups.take();
    GARBAGE.with_borrow_mut(|g| {
        g.extend(popups);
        g.push(view.webview.clone());
    });
}

unsafe fn view<'a>(view: *mut ServoQmlView) -> Option<&'a ServoQmlView> {
    unsafe { view.as_ref() }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn servo_qml_view_load(v: *mut ServoQmlView, url: *const c_char) -> bool {
    let (Some(v), Some(url)) = (unsafe { view(v) }, unsafe { opt_str(url) }) else {
        return false;
    };
    match Url::parse(url) {
        Ok(url) => {
            v.webview.load(url);
            true
        }
        Err(_) => false,
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn servo_qml_view_reload(v: *mut ServoQmlView) {
    if let Some(v) = unsafe { view(v) } {
        v.webview.reload();
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn servo_qml_view_go_back(v: *mut ServoQmlView) {
    if let Some(v) = unsafe { view(v) }.filter(|v| v.webview.can_go_back()) {
        v.webview.go_back(1);
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn servo_qml_view_go_forward(v: *mut ServoQmlView) {
    if let Some(v) = unsafe { view(v) }.filter(|v| v.webview.can_go_forward()) {
        v.webview.go_forward(1);
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn servo_qml_view_resize(v: *mut ServoQmlView, width: u32, height: u32) {
    if let Some(v) = unsafe { view(v) } {
        v.webview.resize(Size::new(width.max(1), height.max(1)));
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn servo_qml_view_set_scale(v: *mut ServoQmlView, scale: f32) {
    if let Some(v) = unsafe { view(v) }.filter(|_| scale > 0.0) {
        v.webview.set_hidpi_scale_factor(Scale::new(scale));
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn servo_qml_view_set_zoom(v: *mut ServoQmlView, zoom: f32) {
    if let Some(v) = unsafe { view(v) }.filter(|_| zoom > 0.0) {
        v.webview.set_page_zoom(zoom);
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn servo_qml_view_set_visible(v: *mut ServoQmlView, visible: bool) {
    if let Some(v) = unsafe { view(v) } {
        if visible {
            v.webview.show();
        } else {
            v.webview.hide();
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn servo_qml_view_set_focused(v: *mut ServoQmlView, focused: bool) {
    if let Some(v) = unsafe { view(v) } {
        v.webview.set_focused(focused);
    }
}

fn point(x: f32, y: f32) -> servo::WebViewPoint {
    DevicePoint::new(x, y).into()
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn servo_qml_view_mouse_move(v: *mut ServoQmlView, x: f32, y: f32) {
    if let Some(v) = unsafe { view(v) } {
        v.webview
            .notify_input_event(InputEvent::MouseMove(MouseMoveEvent::new(point(x, y))));
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn servo_qml_view_mouse_leave(v: *mut ServoQmlView) {
    if let Some(v) = unsafe { view(v) } {
        v.webview.notify_input_event(InputEvent::MouseLeftViewport(
            MouseLeftViewportEvent::default(),
        ));
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn servo_qml_view_mouse_button(
    v: *mut ServoQmlView,
    down: bool,
    button: i32,
    x: f32,
    y: f32,
) {
    if let Some(v) = unsafe { view(v) } {
        let action = if down {
            MouseButtonAction::Down
        } else {
            MouseButtonAction::Up
        };
        v.webview
            .notify_input_event(InputEvent::MouseButton(MouseButtonEvent::new(
                action,
                MouseButton::from(button),
                point(x, y),
            )));
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn servo_qml_view_wheel(
    v: *mut ServoQmlView,
    dx: f64,
    dy: f64,
    mode: i32,
    x: f32,
    y: f32,
) {
    if let Some(v) = unsafe { view(v) } {
        let mode = match mode {
            1 => WheelMode::DeltaLine,
            2 => WheelMode::DeltaPage,
            _ => WheelMode::DeltaPixel,
        };
        let delta = WheelDelta {
            x: dx,
            y: dy,
            z: 0.0,
            mode,
        };
        v.webview
            .notify_input_event(InputEvent::Wheel(WheelEvent::new(delta, point(x, y))));
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn servo_qml_view_key(
    v: *mut ServoQmlView,
    down: bool,
    key: *const c_char,
    code: *const c_char,
    location: i32,
    modifiers: u32,
    repeat: bool,
) {
    let Some(v) = (unsafe { view(v) }) else {
        return;
    };
    let key = unsafe { opt_str(key) }
        .and_then(|k| Key::from_str(k).ok())
        .unwrap_or(Key::Named(servo::NamedKey::Unidentified));
    let code = unsafe { opt_str(code) }
        .and_then(|c| Code::from_str(c).ok())
        .unwrap_or(Code::Unidentified);
    let location = match location {
        1 => Location::Left,
        2 => Location::Right,
        3 => Location::Numpad,
        _ => Location::Standard,
    };
    let mut mods = Modifiers::empty();
    mods.set(Modifiers::SHIFT, modifiers & 1 != 0);
    mods.set(Modifiers::CONTROL, modifiers & 2 != 0);
    mods.set(Modifiers::ALT, modifiers & 4 != 0);
    mods.set(Modifiers::META, modifiers & 8 != 0);
    let state = if down { KeyState::Down } else { KeyState::Up };
    v.webview
        .notify_input_event(InputEvent::Keyboard(KeyboardEvent::new_without_event(
            state, key, code, location, mods, repeat, false,
        )));
}

fn to_json(value: &JSValue) -> serde_json::Value {
    use serde_json::Value;
    match value {
        JSValue::Undefined | JSValue::Null => Value::Null,
        JSValue::Boolean(b) => Value::Bool(*b),
        JSValue::Number(n) => serde_json::Number::from_f64(*n)
            .map(Value::Number)
            .unwrap_or(Value::Null),
        JSValue::String(s) => Value::String(s.clone()),
        // Node and window references have no JSON form; report them as
        // what they are.
        JSValue::Element(_) => Value::String("[object Element]".into()),
        JSValue::ShadowRoot(_) => Value::String("[object ShadowRoot]".into()),
        JSValue::Frame(_) | JSValue::Window(_) => Value::String("[object Window]".into()),
        JSValue::Array(items) => Value::Array(items.iter().map(to_json).collect()),
        JSValue::Object(map) => Value::Object(
            map.iter()
                .map(|(k, v)| (k.clone(), to_json(v)))
                .collect::<serde_json::Map<_, _>>(),
        ),
    }
}

fn js_error_message(error: &JavaScriptEvaluationError) -> String {
    match error {
        JavaScriptEvaluationError::DocumentNotFound => "document not found".into(),
        JavaScriptEvaluationError::CompilationFailure => "compilation failed".into(),
        JavaScriptEvaluationError::EvaluationFailure(Some(info)) => info.message.clone(),
        JavaScriptEvaluationError::EvaluationFailure(None) => "evaluation failed".into(),
        JavaScriptEvaluationError::WebViewNotReady => "view not ready".into(),
        other => format!("{other:?}"),
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn servo_qml_view_evaluate_javascript(
    v: *mut ServoQmlView,
    script: *const c_char,
    done: Option<extern "C" fn(*mut c_void, *const c_char, *const c_char)>,
    user: *mut c_void,
) {
    let user = user as usize;
    let report = move |result: Result<String, String>| {
        if let Some(done) = done {
            match result {
                Ok(json) => {
                    let json = cstring(&json);
                    done(user as *mut c_void, json.as_ptr(), std::ptr::null());
                }
                Err(error) => {
                    let error = cstring(&error);
                    done(user as *mut c_void, std::ptr::null(), error.as_ptr());
                }
            }
        }
    };
    let (Some(v), Some(script)) = (unsafe { view(v) }, unsafe { opt_str(script) }) else {
        report(Err("no view or script".into()));
        return;
    };
    v.webview
        .evaluate_javascript(script, move |result| match result {
            Ok(value) => report(Ok(to_json(&value).to_string())),
            Err(error) => report(Err(js_error_message(&error))),
        });
}
