#include "flutter_window.h"

#include <memory>
#include <optional>
#include <string>
#include <variant>
#include <windows.h>

#include "flutter/generated_plugin_registrant.h"
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

namespace {

constexpr wchar_t kRunKey[] = L"Software\\Microsoft\\Windows\\CurrentVersion\\Run";
constexpr wchar_t kRunValueName[] = L"FoggedVPN";

bool SetAutoStart(bool enabled) {
  HKEY hKey = nullptr;
  LONG status = RegOpenKeyExW(HKEY_CURRENT_USER, kRunKey, 0, KEY_SET_VALUE, &hKey);
  if (status != ERROR_SUCCESS) return false;

  bool ok = false;
  if (enabled) {
    wchar_t exePath[MAX_PATH] = {0};
    DWORD len = GetModuleFileNameW(nullptr, exePath, MAX_PATH);
    if (len > 0 && len < MAX_PATH) {
      std::wstring quoted = L"\"";
      quoted.append(exePath).append(L"\"");
      status = RegSetValueExW(
          hKey, kRunValueName, 0, REG_SZ,
          reinterpret_cast<const BYTE*>(quoted.c_str()),
          static_cast<DWORD>((quoted.size() + 1) * sizeof(wchar_t)));
      ok = (status == ERROR_SUCCESS);
    }
  } else {
    status = RegDeleteValueW(hKey, kRunValueName);
    ok = (status == ERROR_SUCCESS || status == ERROR_FILE_NOT_FOUND);
  }
  RegCloseKey(hKey);
  return ok;
}

}  // namespace

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter::MethodChannel<flutter::EncodableValue> channel(
      flutter_controller_->engine()->messenger(),
      "com.fogged.vpn/windows",
      &flutter::StandardMethodCodec::GetInstance());
  channel.SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() == "setAutoStart") {
          const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
          bool enabled = false;
          if (args) {
            auto it = args->find(flutter::EncodableValue("enabled"));
            if (it != args->end()) {
              const auto* b = std::get_if<bool>(&it->second);
              if (b) enabled = *b;
            }
          }
          result->Success(flutter::EncodableValue(SetAutoStart(enabled)));
        } else {
          result->NotImplemented();
        }
      });

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
