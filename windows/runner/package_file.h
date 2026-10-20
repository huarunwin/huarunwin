#ifndef RUNNER_PACKAGE_FILE_H_
#define RUNNER_PACKAGE_FILE_H_

#include <windows.h>

#include <cwctype>
#include <string>

// Shell processes do not inherit packaged-app file system redirection. Resolve
// the file through its handle before passing its path outside this process.
inline std::wstring ResolvePackageFile(const std::wstring& path) {
  const auto is_local = [](const std::wstring& value) {
    return value.size() >= 3 && iswalpha(value[0]) && value[1] == L':' &&
           value[2] == L'\\' && value.find(L'"') == std::wstring::npos &&
           value.find(L'\0') == std::wstring::npos;
  };
  if (!is_local(path)) return {};

  const HANDLE file = CreateFileW(
      path.c_str(), FILE_READ_ATTRIBUTES,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
      OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
  if (file == INVALID_HANDLE_VALUE) return {};

  BY_HANDLE_FILE_INFORMATION info{};
  const bool ordinary = GetFileInformationByHandle(file, &info) &&
      !(info.dwFileAttributes &
        (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT));
  std::wstring resolved;
  if (ordinary) {
    const DWORD size = GetFinalPathNameByHandleW(file, nullptr, 0, 0);
    if (size) {
      resolved.resize(size);
      const DWORD written =
          GetFinalPathNameByHandleW(file, resolved.data(), size, 0);
      if (written && written < size) resolved.resize(written);
      else resolved.clear();
    }
  }
  CloseHandle(file);

  // Only translate DOS drive paths. UNC and device paths stay unsupported.
  if (resolved.rfind(L"\\\\?\\", 0) == 0) resolved.erase(0, 4);
  return is_local(resolved) ? resolved : std::wstring{};
}

#endif  // RUNNER_PACKAGE_FILE_H_
