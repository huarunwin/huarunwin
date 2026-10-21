#include "package_installer.h"
#include "package_file.h"

#include <shellapi.h>
#include <shlobj.h>
#include <objbase.h>

#include <algorithm>
#include <cwctype>
#include <filesystem>
#include <iterator>
#include <set>
#include <string>
#include <vector>

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
          const std::wstring& parameters = L"",
          const std::wstring& directory = L"") {
  SHELLEXECUTEINFOW info{};
  info.cbSize = sizeof(info);
  info.fMask = SEE_MASK_FLAG_NO_UI | SEE_MASK_NOASYNC;
  info.hwnd = window;
  info.lpVerb = L"open";
  info.lpFile = file.c_str();
  info.lpParameters = parameters.empty() ? nullptr : parameters.c_str();
  info.lpDirectory = directory.empty() ? nullptr : directory.c_str();
  info.nShow = SW_SHOWNORMAL;
  return ShellExecuteExW(&info) != FALSE;
}

std::string Utf8(const std::wstring& text) {
  if (text.empty()) return {};
  const auto size = static_cast<int>(text.size());
  const int count = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS,
      text.data(), size, nullptr, 0, nullptr, nullptr);
  if (!count) return {};
  std::string value(count, '\0');
  WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, text.data(), size,
      value.data(), count, nullptr, nullptr);
  return value;
}

std::wstring RegistryText(HKEY key, const wchar_t* name) {
  DWORD type = 0, size = 0;
  if (RegQueryValueExW(key, name, nullptr, &type, nullptr, &size) != ERROR_SUCCESS ||
      (type != REG_SZ && type != REG_EXPAND_SZ) ||
      size == 0 || size > 65536 || size % sizeof(wchar_t) != 0) return {};
  std::vector<wchar_t> data(size / sizeof(wchar_t) + 1, L'\0');
  if (RegQueryValueExW(key, name, nullptr, &type,
          reinterpret_cast<BYTE*>(data.data()), &size) != ERROR_SUCCESS) return {};
  std::wstring value(data.data());
  if (type == REG_EXPAND_SZ) {
    const DWORD count = ExpandEnvironmentStringsW(value.c_str(), nullptr, 0);
    if (!count || count > 32768) return {};
    std::vector<wchar_t> expanded(count);
    if (ExpandEnvironmentStringsW(value.c_str(), expanded.data(), count) != count) return {};
    value = expanded.data();
  }
  return value;
}

DWORD RegistryNumber(HKEY key, const wchar_t* name) {
  DWORD value = 0, size = sizeof(value), type = 0;
  return RegQueryValueExW(key, name, nullptr, &type,
      reinterpret_cast<BYTE*>(&value), &size) == ERROR_SUCCESS &&
      type == REG_DWORD && size == sizeof(value) ? value : 0;
}

struct RegisteredApp {
  std::wstring id, key, name, version, command;
  bool msi;
};

bool RegisteredApplications(std::vector<RegisteredApp>* apps) {
  constexpr auto root = L"SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Uninstall";
  std::set<std::wstring> visited;
  for (const auto hive : {HKEY_CURRENT_USER, HKEY_LOCAL_MACHINE}) {
    for (const auto view : {KEY_WOW64_64KEY, KEY_WOW64_32KEY}) {
      HKEY parent = nullptr;
      const auto opened = RegOpenKeyExW(hive, root, 0, KEY_READ | view, &parent);
      if (opened == ERROR_FILE_NOT_FOUND || opened == ERROR_PATH_NOT_FOUND) continue;
      if (opened != ERROR_SUCCESS) return false;
      DWORD index = 0;
      for (;;) {
        wchar_t key_name[256];
        DWORD size = static_cast<DWORD>(std::size(key_name));
        const auto status = RegEnumKeyExW(parent, index++, key_name, &size,
                                          nullptr, nullptr, nullptr, nullptr);
        if (status == ERROR_NO_MORE_ITEMS) break;
        if (status != ERROR_SUCCESS) { RegCloseKey(parent); return false; }
        HKEY key = nullptr;
        if (RegOpenKeyExW(parent, key_name, 0, KEY_READ | view, &key) != ERROR_SUCCESS) {
          RegCloseKey(parent); return false;
        }
        const auto name = RegistryText(key, L"DisplayName");
        const auto version = RegistryText(key, L"DisplayVersion");
        const auto command = RegistryText(key, L"UninstallString");
        const bool hidden = RegistryNumber(key, L"SystemComponent") == 1 ||
                            RegistryNumber(key, L"NoRemove") == 1 ||
                            !RegistryText(key, L"ParentKeyName").empty();
        const bool msi = RegistryNumber(key, L"WindowsInstaller") == 1;
        RegCloseKey(key);
        if (hidden || name.empty()) continue;
        const std::wstring scope = hive == HKEY_CURRENT_USER ? L"HKCU/" : L"HKLM/";
        // Some registry views share the same entry. Preserve distinct installs,
        // but do not present the same registration twice.
        const auto signature = scope + key_name + L"\n" + name + L"\n" + version + L"\n" + command;
        if (!visited.insert(signature).second) continue;
        apps->push_back({scope + (view == KEY_WOW64_64KEY ? L"64/" : L"32/") + key_name,
                         key_name, name, version, command, msi});
      }
      RegCloseKey(parent);
    }
  }
  return true;
}

std::string Argument(const flutter::MethodCall<Value>& call, const char* key) {
  const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
  if (!args) return {};
  const auto found = args->find(Value(key));
  if (found == args->end()) return {};
  const auto* value = std::get_if<std::string>(&found->second);
  return value ? *value : std::string{};
}

bool ApplicationSettings(HWND window) {
  if (Open(window, L"ms-settings:appsfeatures")) return true;
  wchar_t system[MAX_PATH];
  const UINT size = GetSystemDirectoryW(system, MAX_PATH);
  return size > 0 && size < MAX_PATH &&
      Open(window, std::wstring(system) + L"\\control.exe",
           L"/name Microsoft.ProgramsAndFeatures");
}

bool UninstallRegisteredApplication(HWND window, const RegisteredApp& app) {
  GUID product{};
  if (app.msi && app.key.size() == 38 && app.key.front() == L'{' &&
      app.key.back() == L'}' &&
      SUCCEEDED(CLSIDFromString(app.key.c_str(), &product))) {
    wchar_t product_code[40];
    if (!StringFromGUID2(product, product_code, static_cast<int>(std::size(product_code)))) return false;
    wchar_t system[MAX_PATH];
    const UINT size = GetSystemDirectoryW(system, MAX_PATH);
    return size > 0 && size < MAX_PATH &&
        Open(window, std::wstring(system) + L"\\msiexec.exe",
             std::wstring(L"/x ") + product_code);
  }
  // Use the registered interactive uninstaller. QuietUninstallString and shell
  // interpreters are never used. Ambiguous/unsupported commands go to Settings.
  const auto first = app.command.find_first_not_of(L" \t");
  if (first == std::wstring::npos) return ApplicationSettings(window);
  const bool quoted = app.command[first] == L'"';
  const auto end = quoted ? app.command.find(L'"', first + 1)
                          : app.command.find_first_of(L" \t", first);
  if (quoted && end == std::wstring::npos) return ApplicationSettings(window);
  const auto file = app.command.substr(first + (quoted ? 1 : 0),
      end == std::wstring::npos ? end : end - first - (quoted ? 1 : 0));
  const auto resolved = ResolvePackageFile(file);
  auto basename = std::filesystem::path(resolved).filename().wstring();
  std::transform(basename.begin(), basename.end(), basename.begin(),
                 [](wchar_t c) { return static_cast<wchar_t>(towlower(c)); });
  const std::set<std::wstring> interpreters = {
    L"cmd.exe", L"powershell.exe", L"pwsh.exe", L"wscript.exe",
    L"cscript.exe", L"mshta.exe", L"rundll32.exe", L"regsvr32.exe",
    L"msiexec.exe"
  };
  if (resolved.empty() || std::filesystem::path(basename).extension() != L".exe" ||
      interpreters.count(basename)) return ApplicationSettings(window);
  const auto parameters = end == std::wstring::npos ? L"" :
      app.command.substr(end + (quoted ? 1 : 0));
  return Open(window, resolved, parameters,
              std::filesystem::path(resolved).parent_path().wstring());
}

void Handle(const flutter::MethodCall<Value>& call,
            std::unique_ptr<Result> result, HWND window) {
  if (call.method_name() == "openApplicationSettings") {
    if (ApplicationSettings(window)) result->Success();
    else result->Error("uninstall_settings", "无法打开系统应用管理，请从 Windows 设置进入“已安装的应用”。");
    return;
  }
  if (call.method_name() == "installedApplications" ||
      call.method_name() == "uninstallApplication") {
    std::vector<RegisteredApp> apps;
    if (!RegisteredApplications(&apps)) {
      result->Error("installed_apps", "无法读取系统应用注册信息，请刷新后重试。");
      return;
    }
    if (call.method_name() == "installedApplications") {
      flutter::EncodableList values;
      for (const auto& app : apps) {
        values.emplace_back(flutter::EncodableMap{
          {Value("uninstallId"), Value(Utf8(app.id))},
          {Value("version"), Value(Utf8(app.version))},
          {Value("names"), Value(flutter::EncodableList{Value(Utf8(app.name))})}
        });
      }
      result->Success(Value(values));
      return;
    }
    const auto id = Argument(call, "uninstallId");
    const auto name = Argument(call, "name");
    const auto version = Argument(call, "version");
    const auto app = std::find_if(apps.begin(), apps.end(), [&](const auto& entry) {
      return Utf8(entry.id) == id && Utf8(entry.name) == name &&
             Utf8(entry.version) == version;
    });
    if (id.empty() || app == apps.end()) {
      result->Error("changed", "本机应用注册信息已变化，请刷新后重新选择卸载。");
    } else if (UninstallRegisteredApplication(window, *app)) {
      // A launched uninstaller or Settings window is only a handoff.
      result->Success();
    } else {
      result->Error("uninstall", GetLastError() == ERROR_CANCELLED
          ? "系统卸载已取消，下载文件和记录已保留。"
          : "无法打开卸载程序，请从系统“已安装的应用”中卸载。");
    }
    return;
  }
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
