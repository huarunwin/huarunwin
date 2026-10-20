[Setup]
AppId=win.huarun.huarunwin
AppName=HuarunWin
AppVersion={#AppVersion}
AppPublisher=win.huarun
AppPublisherURL=https://huarun.win/
AppSupportURL=https://github.com/huarunwin/huarunwin/issues
AppUpdatesURL=https://github.com/huarunwin/huarunwin/releases
DefaultDirName={localappdata}\Programs\HuarunWin
PrivilegesRequired=lowest
ArchitecturesAllowed={#Architecture}
ArchitecturesInstallIn64BitMode={#Architecture}
MinVersion={#MinimumVersion}
DisableProgramGroupPage=yes
UninstallDisplayIcon={app}\huarunwin.exe
SetupIconFile=..\..\windows\runner\resources\app_icon.ico
LicenseFile={#BundleDir}\LICENSE.txt
OutputDir={#OutputDir}
OutputBaseFilename={#AssetStem}-setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no
VersionInfoVersion={#NativeVersion}
VersionInfoTextVersion={#AppVersion}
VersionInfoProductVersion={#NativeVersion}
VersionInfoProductTextVersion={#AppVersion}
VersionInfoCompany=win.huarun
VersionInfoProductName=huarunwin
VersionInfoDescription=HuarunWin Setup
VersionInfoOriginalFileName=huarunwin-setup.exe

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#BundleDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\HuarunWin"; Filename: "{app}\huarunwin.exe"
Name: "{autodesktop}\HuarunWin"; Filename: "{app}\huarunwin.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\huarunwin.exe"; Description: "{cm:LaunchProgram,HuarunWin}"; Flags: nowait postinstall skipifsilent
