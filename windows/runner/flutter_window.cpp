#include "flutter_window.h"

#include <optional>
#include <windowsx.h>

#include "flutter/generated_plugin_registrant.h"

namespace {

// 自绘标题栏的高度，必须和 Dart 侧 MainWindow.titleBarHeight 一致。
constexpr int kTitleBarHeight = 34;
// 标题栏右侧窗口按钮（− □ ✕）占的宽度：3 个 × 44。
constexpr int kCaptionButtonsWidth = 132;
// 再加上 header 行右侧三个胶囊按钮大致占的宽度和留白。
constexpr int kTitleButtonsWidth = 220;
// 无边框窗口在四条边留出的缩放热区宽度。
constexpr int kResizeBorder = 6;

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

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
    case WM_NCHITTEST: {
      // 窗口是 frameless（titleBarStyle: hidden）的，Dart 侧再伪造拖动会把
      // 渲染线程冻住，所以拖动热区、双击最大化、右键系统菜单全部交回系统：
      // 把客户区顶边那一条报成 HTCAPTION，系统就会自己处理拖窗与双击。
      const LRESULT hit = Win32Window::MessageHandler(hwnd, message, wparam, lparam);
      if (hit != HTCLIENT) {
        return hit;
      }
      POINT point = {GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
      ScreenToClient(hwnd, &point);
      RECT client{};
      GetClientRect(hwnd, &client);
      const LONG width = client.right - client.left;
      const LONG height = client.bottom - client.top;

      // 四条边先给缩放热区，避免和标题栏抢。
      if (point.y < kResizeBorder) {
        if (point.x < kResizeBorder) return HTTOPLEFT;
        if (point.x >= width - kResizeBorder) return HTTOPRIGHT;
        return HTTOP;
      }
      if (point.y >= height - kResizeBorder) {
        if (point.x < kResizeBorder) return HTBOTTOMLEFT;
        if (point.x >= width - kResizeBorder) return HTBOTTOMRIGHT;
        return HTBOTTOM;
      }
      if (point.x < kResizeBorder) return HTLEFT;
      if (point.x >= width - kResizeBorder) return HTRIGHT;

      if (point.y < kTitleBarHeight) {
        // 标题栏里只有左侧的品牌区是拖动区。右侧的「预览/备份/⋯」和窗口
        // 按钮都在这一行，报成 HTCAPTION 的话点一下会被系统当成标题栏
        // 双击直接最大化，所以整行右侧一律 HTCLIENT 交给 Flutter。
        if (point.x < width - kCaptionButtonsWidth - kTitleButtonsWidth) {
          return HTCAPTION;
        }
        return HTCLIENT;
      }
      return HTCLIENT;
    }
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

