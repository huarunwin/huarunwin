// Run with a logical download path, its independently verified physical path,
// and an empty fixture directory. This test never runs an installer.
#include "../windows/runner/package_file.h"

#include <iostream>

namespace {
int checks = 0;
int failures = 0;
void Expect(bool value, const char* label) {
  ++checks;
  if (!value) {
    ++failures;
    std::cerr << "FAIL: " << label << '\n';
  }
}
}  // namespace

int wmain(int argc, wchar_t* argv[]) {
  if (argc != 4) return 2;
  const std::wstring logical = argv[1];
  const std::wstring physical = argv[2];
  const std::wstring folder = argv[3];
  Expect(ResolvePackageFile(logical) == physical,
         "redirected download resolves to the physical shell path");
  Expect(ResolvePackageFile(physical) == physical,
         "physical paths remain usable without redirection");
  Expect(ResolvePackageFile(L"relative.exe").empty(), "relative path rejected");
  Expect(ResolvePackageFile(L"\\\\server\\share\\app.exe").empty(),
         "UNC path rejected");
  Expect(ResolvePackageFile(L"\\\\?\\" + physical).empty(),
         "device path input rejected");
  Expect(ResolvePackageFile(L"\"" + logical + L"\"").empty(),
         "quoted command string rejected");
  Expect(ResolvePackageFile(logical + std::wstring(1, L'\0') + L".exe").empty(),
         "embedded null rejected");
  Expect(ResolvePackageFile(folder).empty(), "directory rejected");
  Expect(ResolvePackageFile(folder + L"\\missing.exe").empty(),
         "missing file rejected");

  const std::wstring fixture = folder + L"\\本地安装包 & spaces.EXE";
  const HANDLE file = CreateFileW(fixture.c_str(), GENERIC_WRITE, 0, nullptr,
                                  CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr);
  Expect(file != INVALID_HANDLE_VALUE, "create Unicode fixture");
  if (file != INVALID_HANDLE_VALUE) {
    CloseHandle(file);
    const auto resolved = ResolvePackageFile(fixture);
    Expect(!resolved.empty(), "Unicode and shell punctuation preserved");
    Expect(resolved.find(L"本地安装包 & spaces.EXE") != std::wstring::npos,
           "resolved file keeps its actual name");
    Expect(resolved.rfind(L"\\\\?\\", 0) != 0,
           "shell receives a DOS path rather than a device path");
    Expect(GetFileAttributesW(resolved.c_str()) != INVALID_FILE_ATTRIBUTES,
           "resolved file exists");
    DeleteFileW(fixture.c_str());
  }
  std::cout << checks << " native path checks, " << failures << " failures\n";
  return failures ? 1 : 0;
}
