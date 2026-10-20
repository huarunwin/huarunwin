#ifndef RUNNER_PACKAGE_INSTALLER_H_
#define RUNNER_PACKAGE_INSTALLER_H_

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <windows.h>

#include <memory>

// The channel owns its handler for the lifetime of the Flutter engine.
std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
CreatePackageInstaller(flutter::BinaryMessenger* messenger, HWND window);

#endif  // RUNNER_PACKAGE_INSTALLER_H_
