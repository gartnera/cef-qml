project('cef-qml', 'cpp',
  version: '0.1.0',
  meson_version: '>=1.3.0',
  default_options: [
    'cpp_std=c++20',
    'buildtype=release',
    'b_ndebug=if-release',
    'warning_level=2',
  ],
)

qt6 = import('qt6')
qt_dep = dependency('qt6', modules: ['Core', 'Gui', 'Qml', 'Quick'])

cef_proj = subproject('cef')
cef_dep = cef_proj.get_variable('cef_dep')

prefix = get_option('prefix')

qml_dir = get_option('qml_dir')
if qml_dir == ''
  qml_dir = get_option('libdir') / 'qt6' / 'qml'
endif

runtime_dir = get_option('runtime_dir')
if runtime_dir == ''
  runtime_dir = get_option('libdir') / 'cef-qml'
endif

# The plugin finds libcef.so via RPATH and then locates the helper and
# resources next to whichever libcef.so was actually loaded, so the build tree
# and the installed tree both work without environment variables.
runtime_build_dir = meson.current_build_dir() / 'runtime'
runtime_install_dir = prefix / runtime_dir
plugin_install_dir = prefix / qml_dir / 'CefQml'

# When the QML module and the runtime are both installed under the prefix,
# the installed plugin's RPATH is relative to the plugin itself
# ($ORIGIN/../../lib/cef-qml by default), so the prefix can be moved as a whole
# (the prebuilt release tarball relies on this). If either one was pointed
# outside the prefix (e.g. qml_dir set to the system Qt's import directory)
# the two do not move together, and the absolute path is the robust choice.
fs = import('fs')
prefix_slash = prefix.endswith('/') ? prefix : prefix + '/'
if plugin_install_dir.startswith(prefix_slash) and runtime_install_dir.startswith(prefix_slash)
  plugin_install_rpath = '$ORIGIN' / fs.relative_to(runtime_install_dir, plugin_install_dir)
else
  plugin_install_rpath = runtime_install_dir
endif

subdir('runtime')
subdir('CefQml')
if get_option('servo').enabled()
  subdir('ServoQml')
endif

if get_option('examples')
  install_subdir('examples', install_dir: get_option('datadir') / 'cef-qml')
endif

run_tests = find_program('tests/run.sh')
test('offscreen', run_tests,
  args: [meson.project_build_root(), 'offscreen'],
  depends: [plugin, qmldir_file, helper, stage_runtime],
  timeout: 300, is_parallel: false)
# Headless weston has no seat, so windows never become active and window
# shortcuts never fire; the browser suite (shortcut driven) runs offscreen.
test('wayland', run_tests,
  args: [meson.project_build_root(), 'wayland'],
  env: ['TEST_INPUT=' + meson.current_source_dir() / 'tests' / 'tst_webview.qml'],
  depends: [plugin, qmldir_file, helper, stage_runtime],
  timeout: 300, is_parallel: false)

# Drives the reference browser from outside over the remote-debugging port
# (CEF_QML_REMOTE_DEBUGGING_PORT) and checks it exits cleanly on SIGTERM.
python3 = find_program('python3', required: false)
if python3.found()
  test('cdp-remote', python3,
    args: [meson.current_source_dir() / 'tests' / 'cdp_remote.py',
           meson.project_build_root(),
           meson.current_source_dir() / 'examples' / 'browser' / 'main.qml'],
    depends: [plugin, qmldir_file, helper, stage_runtime],
    timeout: 120, is_parallel: false)
endif
