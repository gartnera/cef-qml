moc_files = qt6.compile_moc(
  headers: [
    '../src/cefwebview.h',
    '../src/cefcontext.h',
    '../src/plugin.h',
    '../src/requests.h',
  ],
  dependencies: qt_dep,
)

plugin = shared_module('cefqmlplugin',
  '../src/plugin.cpp',
  '../src/cefcontext.cpp',
  '../src/cefwebview.cpp',
  '../src/cefclient.cpp',
  '../src/keymap.cpp',
  '../src/requests.cpp',
  moc_files,
  dependencies: [qt_dep, cef_dep],
  cpp_args: ['-DQT_NO_KEYWORDS'],
  link_args: ['-ldl'],
  build_rpath: runtime_build_dir,
  install_rpath: runtime_install_dir,
  install: true,
  install_dir: qml_dir / 'CefQml',
)

configure_file(input: 'qmldir', output: 'qmldir', copy: true,
  install: true, install_dir: qml_dir / 'CefQml')

# Pure-QML modules: CefQml.Components (any Qt Quick app) and CefQml.Quickshell
# (needs Quickshell). Linked into the build tree so QML_IMPORT_PATH=<builddir>
# picks up edits without rebuilding.
foreach m : ['Components', 'Quickshell']
  install_subdir(m, install_dir: qml_dir / 'CefQml')
  run_command('ln', '-sfn', meson.current_source_dir() / m, meson.current_build_dir() / m,
    check: true)
endforeach
