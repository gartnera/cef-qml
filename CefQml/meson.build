moc_files = qt6.compile_moc(
  headers: [
    '../src/cefwebview.h',
    '../src/cefcontext.h',
    '../src/plugin.h',
    '../src/requests.h',
    '../src/hotreload.h',
    '../src/jsonstore.h',
    '../src/historystore.h',
    '../src/bookmarkstore.h',
    '../src/sitesettings.h',
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
  '../src/hotreload.cpp',
  '../src/jsonstore.cpp',
  '../src/historystore.cpp',
  '../src/bookmarkstore.cpp',
  '../src/contentsettings.cpp',
  '../src/sitesettings.cpp',
  moc_files,
  dependencies: [qt_dep, cef_dep],
  cpp_args: ['-DQT_NO_KEYWORDS'],
  link_args: ['-ldl'],
  build_rpath: runtime_build_dir,
  install_rpath: plugin_install_rpath,
  install: true,
  install_dir: qml_dir / 'CefQml',
)

qmldir_file = fs.copyfile('qmldir', install: true, install_dir: qml_dir / 'CefQml')

# Pure-QML module CefQml.Components, linked into the build tree so
# QML_IMPORT_PATH=<builddir> picks up edits without rebuilding.
foreach m : ['Components']
  install_subdir(m, install_dir: qml_dir / 'CefQml')
  run_command('ln', '-sfn', meson.current_source_dir() / m, meson.current_build_dir() / m,
    check: true)
endforeach
