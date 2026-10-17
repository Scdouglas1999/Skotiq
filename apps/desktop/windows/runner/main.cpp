#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Always try to create/attach a console for headless mode
  // This allows the app to show output when run directly
  if (!::AttachConsole(ATTACH_PARENT_PROCESS)) {
    // If no parent console, create one
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  const HRESULT com_result =
      ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"skotiq_desktop", origin, size)) {
    window.Destroy();
    if (SUCCEEDED(com_result)) {
      ::CoUninitialize();
    }
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg{};
  BOOL message_result;
  while ((message_result = ::GetMessage(&msg, nullptr, 0, 0)) > 0) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  // window_manager.destroy() posts WM_QUIT without destroying the HWND. Tear
  // down the controller while the derived window and COM apartment are still
  // alive, not from member/base destructors after CoUninitialize. OnDestroy
  // clears flutter_controller_ before deleting it, so reentrant Windows
  // messages cannot dispatch through a controller whose view is being freed.
  window.Destroy();
  if (SUCCEEDED(com_result)) {
    ::CoUninitialize();
  }
  return message_result == -1 ? EXIT_FAILURE : EXIT_SUCCESS;
}
