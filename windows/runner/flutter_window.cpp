#include "flutter_window.h"

#include <optional>
#include <string>
#include <thread>
#include <utility>
#include <windowsx.h>

#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Security.Credentials.UI.h>

#include "flutter/generated_plugin_registrant.h"

namespace {

// Windows Hello 走 UserConsentVerifier：它自己弹系统那个 PIN / 指纹 /
// 面容的对话框，我们只等结果。没有可用验证器、被取消、超出重试次数
// 都返回 false，Dart 侧据此退回主密码。
using winrt::Windows::Security::Credentials::UI::UserConsentVerificationResult;
using winrt::Windows::Security::Credentials::UI::UserConsentVerifier;
using winrt::Windows::Security::Credentials::UI::UserConsentVerifierAvailability;

constexpr char kHelloChannel[] = "memonest/hello";

/// 后台线程算完结果后，把「是否通过 + 要回给 Dart 的 result」打包塞进
/// 消息队列，回 UI 线程再 Complete()。MethodResult 不能跨线程调用。
struct HelloResult {
  bool ok = false;
  std::string reason;
  std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result;
};

/// 后台线程要知道往哪个窗口投递消息。
HWND g_hello_window = nullptr;

std::wstring Wide(const std::string& text) {
  if (text.empty()) return {};
  const int size = ::MultiByteToWideChar(CP_UTF8, 0, text.data(),
                                         static_cast<int>(text.size()),
                                         nullptr, 0);
  std::wstring out(static_cast<size_t>(size), L'\0');
  ::MultiByteToWideChar(CP_UTF8, 0, text.data(), static_cast<int>(text.size()),
                        out.data(), size);
  return out;
}

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

  ::g_hello_window = GetHandle();
  RegisterHelloChannel();

  return true;
}

void FlutterWindow::RegisterHelloChannel() {
  auto messenger = flutter_controller_->engine()->messenger();
  hello_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, kHelloChannel,
          &flutter::StandardMethodCodec::GetInstance());
  hello_channel_->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
             result) {
        const HWND hwnd = g_hello_window;
        if (hwnd == nullptr) {
          result->Error("no_window", "窗口还没建好");
          return;
        }
        const std::string method = call.method_name();
        if (method != "available" && method != "authenticate") {
          result->NotImplemented();
          return;
        }
        std::string prompt = "解锁私密笔记库";
        if (const auto* args =
                std::get_if<flutter::EncodableMap>(call.arguments())) {
          const auto it = args->find(flutter::EncodableValue("prompt"));
          if (it != args->end()) {
            if (const auto* text = std::get_if<std::string>(&it->second)) {
              if (!text->empty()) prompt = *text;
            }
          }
        }
        // CheckAvailabilityAsync / RequestVerificationAsync 都会阻塞到有结果，
        // 不能占着 UI 线程，扔到独立线程跑；结果用 PostMessage 送回 UI 线程
        // 再 Complete()（MethodResult 不是线程安全的）。
        std::thread([hwnd, method, prompt, result = std::move(result)]() mutable {
          auto* reply = new HelloResult();
          reply->result = std::move(result);
          try {
            // CheckAvailabilityAsync 返回的是 Availability 枚举
            // （Available / DeviceNotPresent / NotConfiguredForUser /
            // DisabledByPolicy），只有 Available 才算能用。
            const auto availability =
                UserConsentVerifier::CheckAvailabilityAsync().get();
            if (availability != UserConsentVerifierAvailability::Available) {
              reply->reason = "这台设备没有可用的 Windows Hello";
            } else if (method == "available") {
              reply->ok = true;
            } else {
              const auto verify =
                  UserConsentVerifier::RequestVerificationAsync(Wide(prompt))
                      .get();
              reply->ok = verify == UserConsentVerificationResult::Verified;
              if (!reply->ok) reply->reason = "验证未通过或已取消";
            }
          } catch (...) {
            reply->reason = "Windows Hello 调用失败";
          }
          ::PostMessageW(hwnd, FlutterWindow::kHelloDone,
                         reinterpret_cast<WPARAM>(reply), 0);
        }).detach();
      });
}

void FlutterWindow::OnDestroy() {
  ::g_hello_window = nullptr;
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
    case FlutterWindow::kHelloDone: {
      std::unique_ptr<HelloResult> reply(
          reinterpret_cast<HelloResult*>(wparam));
      if (reply && reply->result) {
        if (reply->ok) {
          reply->result->Success(flutter::EncodableValue(true));
        } else {
          reply->result->Success(flutter::EncodableValue(false));
        }
      }
      return 0;
    }
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

