; Установщик Voxnica для Windows (Inno Setup 6).
; Собирается скриптом build-installer.ps1: он делает release-сборку
; Flutter и передаёт версию и каталог сборки через /D.
;
; Вручную:
;   ISCC.exe /DAppVersion=1.0.0 voxnica.iss

#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif

#ifndef ReleaseDir
  #define ReleaseDir "..\..\app\build\windows\x64\runner\Release"
#endif

#define AppName "Voxnica"
#define AppExe "voxnica.exe"
#define AppPublisher "Voxnica"

[Setup]
; AppId не меняется между версиями: по нему Windows понимает,
; что это обновление того же приложения, а не второе.
AppId={{8F1F3C52-6C1B-4C2A-9E52-7D0A3B5C1E44}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher={#AppPublisher}
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
; Права администратора не нужны: ставим в профиль пользователя.
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=..\..\dist
OutputBaseFilename=VoxnicaSetup-{#AppVersion}
SetupIconFile=..\..\app\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExe}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
; Закрыть запущенное приложение, иначе файлы не перезаписать.
CloseApplications=yes
RestartApplications=no

[Languages]
Name: "russian"; MessagesFile: "compiler:Languages\Russian.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "{#ReleaseDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExe}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent
