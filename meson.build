project('cef-qml', 'cpp',
  version: '0.1.0',
  meson_version: '>=1.1.0',
  default_options: [
    'cpp_std=c++20',
    'buildtype=release',
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

subdir('runtime')
subdir('CefQml')

if get_option('examples')
  install_subdir('examples', install_dir: get_option('datadir') / 'cef-qml')
endif

run_tests = find_program('tests/run.sh')
test('webview-offscreen', run_tests,
  args: [meson.project_build_root(), 'offscreen'],
  depends: [plugin, helper, stage_runtime],
  timeout: 300, is_parallel: false)
test('webview-wayland', run_tests,
  args: [meson.project_build_root(), 'wayland'],
  depends: [plugin, helper, stage_runtime],
  timeout: 300, is_parallel: false)
