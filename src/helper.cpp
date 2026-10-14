// CEF sub-process entry point (renderer, GPU, network/utility processes).
//
// The browser process lives inside the host application (your Qt application),
// whose main() we do not control, so CefSettings.browser_subprocess_path points
// here instead.

#include "include/base/cef_compiler_specific.h"
#include "include/cef_app.h"

// Chromium's zygote re-randomizes the stack canary in forked children
// (--change-stack-guard-on-fork), so frames that are live across the fork must
// not carry a stack protector or they abort with "stack smashing detected".
NO_STACK_PROTECTOR int main(int argc, char* argv[]) {
  CefMainArgs args(argc, argv);
  return CefExecuteProcess(args, nullptr, nullptr);
}
