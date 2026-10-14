# The CEF sub-process executable (renderer, GPU, utility processes). The QML
# plugin cannot hijack the host application's main(), so CEF re-executes this
# small binary instead.
helper = executable('cef-qml-helper',
  '../src/helper.cpp',
  dependencies: cef_dep,
  build_rpath: '$ORIGIN',
  install_rpath: '$ORIGIN',
  install: true,
  install_dir: runtime_dir,
)

# Stage libcef.so and its resources next to the helper so the build tree is
# directly usable (QML_IMPORT_PATH=<builddir>).
stage_runtime = custom_target('cef-runtime',
  output: 'cef-runtime.stamp',
  command: [
    find_program('../scripts/stage-runtime.sh'),
    cef_proj.get_variable('cef_release_dir'),
    cef_proj.get_variable('cef_resources_dir'),
    meson.current_build_dir(),
    '@OUTPUT@',
  ],
  build_by_default: true,
)

install_data(cef_proj.get_variable('cef_runtime_files'),
  install_dir: runtime_dir,
  install_mode: 'rwxr-xr-x',
)
install_subdir(cef_proj.get_variable('cef_locales_dir'),
  install_dir: runtime_dir,
)
