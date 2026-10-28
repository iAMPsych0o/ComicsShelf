; Instalador de ComicShelf para Windows (Inno Setup 6).
; Se genera con installer\build_installer.ps1, que compila la app y copia
; las librerías de Visual C++ a installer\redist antes de llamar a ISCC.

#define AppName "ComicShelf"
#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif
#define AppExe "comics_panini.exe"
#define Release "..\build\windows\x64\runner\Release"

[Setup]
; No cambiar AppId: identifica la app para actualizar y desinstalar.
AppId={{6C2B7E4A-3F1D-4C8B-9A5E-2D7F0B1C4E93}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher=ComicShelf
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
; Por usuario: no pide permisos de administrador y se instala en
; %LOCALAPPDATA%\Programs\ComicShelf.
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=Output
OutputBaseFilename=ComicShelf-Setup-{#AppVersion}
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExe}
UninstallDisplayName={#AppName}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
; Si la app está abierta, la cierra para poder actualizarla.
CloseApplications=yes

[Languages]
Name: "es"; MessagesFile: "compiler:Languages\Spanish.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "{#Release}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
; Librerías de Visual C++ (x64) para PCs que no las tengan.
Source: "redist\*.dll"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExe}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent

; Los datos del usuario (%APPDATA%\mx.coleccion\comics_panini) no se borran
; al desinstalar.
