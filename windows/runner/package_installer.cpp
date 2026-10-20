#include "package_installer.h"
#include "package_file.h"

#include <shellapi.h>
#include <shlobj.h>

#include <algorithm>
#include <cwctype>
#include <filesystem>
#include <string>

namespace {
using Value = flutter::EncodableValue;
using Result = flutter::MethodResult<Value>;

std::wstring LocalFile(const flutter::MethodCall<Value>& call) {
  const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
  if (!args) return {};
  const auto found = args->find(Value("path"));
  if (found == args->end()) return {};
  const auto* text = std::get_if<std::string>(&found->second);
  if (!text || text->empty() || text->find('\0') != std::string::npos) {
    return {};
  }
  const int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                       text->data(), static_cast<int>(text->size()), nullptr, 0);
  if (!count) return {};
  std::wstring path(count, L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text->data(),
                      static_cast<int>(text->size()), path.data(), count);
  return ResolvePackageFile(path);
}

bool Open(HWND window, const std::wstring& file,
          const std::wstring& parameters = L"") {
  SHELLEXECUTEINFOW info{};
  info.cbSize = sizeof(info);
  info.fMask = SEE_MASK_FLAG_NO_UI | SEE_MASK_NOASYNC;
  info.hwnd = window;
  info.lpVerb = L"open";
  info.lpFile = file.c_str();
  info.lpParameters = parameters.empty() ? nullptr : parameters.c_str();
  info.nShow = SW_SHOWNORMAL;
  return ShellExecuteExW(&info) != FALSE;
}

void Handle(const flutter::MethodCall<Value>& call,
            std::unique_ptr<Result> result, HWND window) {
  if (call.method_name() == "architecture") {
    SYSTEM_INFO info{};
    GetNativeSystemInfo(&info);
    switch (info.wProcessorArchitecture) {
      case PROCESSOR_ARCHITECTURE_ARM64: result->Success(Value("arm64")); return;
      case PROCESSOR_ARCHITECTURE_AMD64: result->Success(Value("x64")); return;
      case PROCESSOR_ARCHITECTURE_INTEL: result->Success(Value("x86")); return;
      default: result->Success(); return;
    }
  }
  if (call.method_name() != "openPackage" && call.method_name() != "reveal") {
    result->NotImplemented();
    return;
  }
  const auto path = LocalFile(call);
  if (path.empty()) {
    result->Error("package_path", "请选择仍在本机的普通安装包文件。");
    return;
  }
  if (call.method_name() == "reveal") {
    PIDLIST_ABSOLUTE item = nullptr;
    HRESULT status = SHParseDisplayName(path.c_str(), nullptr, &item, 0, nullptr);
    if (SUCCEEDED(status)) {
      status = SHOpenFolderAndSelectItems(item, 0, nullptr, 0);
      CoTaskMemFree(item);
    }
    if (FAILED(status)) result->Error("reveal", "无法在资源管理器中定位文件。");
    else result->Success();
    return;
  }
  auto extension = std::filesystem::path(path).extension().wstring();
  std::transform(extension.begin(), extension.end(), extension.begin(),
                 [](wchar_t c) { return static_cast<wchar_t>(towlower(c)); });
  bool opened = false;
  if (extension == L".msi") {
    wchar_t system[MAX_PATH];
    const UINT size = GetSystemDirectoryW(system, MAX_PATH);
    if (size > 0 && size < MAX_PATH) {
      opened = Open(window, std::wstring(system) + L"\\msiexec.exe",
                    L"/i \"" + path + L"\"");
    }
  } else if (extension == L".exe" || extension == L".msix" || extension == L".zip") {
    opened = Open(window, path);
  } else {
    result->Error("package_kind", "仅支持 EXE、MSI、MSIX 或 ZIP，请查看文件后手动处理。");
    return;
  }
  if (!opened) {
    const auto code = GetLastError();
    result->Error("open_package", code == ERROR_CANCELLED
        ? "系统操作已取消，安装包已保留。"
        : "无法打开安装器或解压窗口，请查看文件后手动处理。");
  } else {
    // Shell launch does not establish whether the user installed the package.
    result->Success(Value(true));
  }
}
}  // namespace

std::unique_ptr<flutter::MethodChannel<Value>> CreatePackageInstaller(
    flutter::BinaryMessenger* messenger, HWND window) {
  auto channel = std::make_unique<flutter::MethodChannel<Value>>(
      messenger, "win.huarun/installer", &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler([window](const auto& call, auto result) {
    Handle(call, std::move(result), window);
  });
  return channel;
}
