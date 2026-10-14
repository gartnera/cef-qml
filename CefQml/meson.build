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
