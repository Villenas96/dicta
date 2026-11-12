; Instalador de Dicta para Windows (Inno Setup 6). Lo compila GitHub Actions.
#define AppVersion GetEnv("DICTA_VERSION")
#if AppVersion == ""
  #define AppVersion "0.0.0"
#endif

[Setup]
AppId={{8C4D2F31-6A55-4B1E-9F3A-2D7C1E5B9A10}
AppName=Dicta
AppVersion={#AppVersion}
AppPublisher=Dicta
AppPublisherURL=https://github.com/Villenas96/dicta
DefaultDirName={localappdata}\Programs\Dicta
DisableProgramGroupPage=yes
DisableDirPage=yes
; Instalación por usuario: no pide permisos de administrador.
PrivilegesRequired=lowest
OutputDir=..\out
OutputBaseFilename=Dicta-Setup
Compression=lzma2/max
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
WizardStyle=modern
UninstallDisplayIcon={app}\Dicta.exe
CloseApplications=force

[Languages]
Name: "es"; MessagesFile: "compiler:Languages\Spanish.isl"

[Tasks]
Name: "autostart"; Description: "Abrir Dicta al iniciar Windows"
Name: "desktopicon"; Description: "Crear un acceso directo en el escritorio"; Flags: unchecked

[Files]
Source: "..\publish\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\Dicta"; Filename: "{app}\Dicta.exe"
Name: "{autodesktop}\Dicta"; Filename: "{app}\Dicta.exe"; Tasks: desktopicon

[Registry]
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "Dicta"; ValueData: """{app}\Dicta.exe"""; Tasks: autostart; Flags: uninsdeletevalue

[Run]
Filename: "{app}\Dicta.exe"; Description: "Abrir Dicta ahora"; Flags: nowait postinstall

[UninstallRun]
Filename: "{sys}\taskkill.exe"; Parameters: "/im Dicta.exe /f"; Flags: runhidden; RunOnceId: "KillDicta"
