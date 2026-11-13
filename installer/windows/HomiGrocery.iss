; مثبت Windows الرسمي لتطبيق Homi Grocery.
; تُبنى ملفات التطبيق في Flutter أولًا، ثم يجمعها Inno Setup في ملف EXE.

#ifndef AppVersion
  #define AppVersion "0.1.0"
#endif

#ifndef SourceDir
  #define SourceDir "..\\..\\app\\build\\windows\\x64\\runner\\Release"
#endif

#ifndef UpdaterPath
  #define UpdaterPath "..\\..\\app\\build\\windows\\updater\\HomiUpdater.exe"
#endif

#ifndef LauncherPath
  #define LauncherPath "..\\..\\app\\build\\windows\\updater-launcher\\HomiUpdateLauncher.exe"
#endif

[Setup]
AppId={{B86F2F48-DB42-4B7B-A4B9-8E4E9E31C6D2}
AppName=Homi Grocery
AppVersion={#AppVersion}
AppPublisher=Homi
DefaultDirName={autopf}\\Homi Grocery
DefaultGroupName=Homi Grocery
DisableProgramGroupPage=yes
ArchitecturesAllowed=x64
ArchitecturesInstallIn64BitMode=x64
PrivilegesRequired=admin
OutputDir=..\\..\\app\\build\\windows\\installer
OutputBaseFilename=Homi-Grocery-Setup-x64
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
UninstallDisplayName=Homi Grocery
Uninstallable=yes
CloseApplications=yes
RestartApplications=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "إنشاء اختصار على سطح المكتب"; GroupDescription: "اختصارات إضافية:"; Flags: unchecked

[Files]
Source: "{#SourceDir}\\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
; تُحفظ أدوات التحديث خارج مجلد التطبيق حتى يمكنها استبداله بعد إغلاقه.
Source: "{#UpdaterPath}"; DestDir: "{commonappdata}\\Homi Grocery\\Updater"; DestName: "HomiUpdater.exe"; Flags: ignoreversion
Source: "{#LauncherPath}"; DestDir: "{commonappdata}\\Homi Grocery\\Updater"; DestName: "HomiUpdateLauncher.exe"; Flags: ignoreversion

[Icons]
Name: "{group}\\Homi Grocery"; Filename: "{app}\\homi_grocery.exe"; WorkingDir: "{app}"
Name: "{autodesktop}\\Homi Grocery"; Filename: "{app}\\homi_grocery.exe"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\\homi_grocery.exe"; Description: "تشغيل Homi Grocery"; WorkingDir: "{app}"; Flags: postinstall nowait skipifsilent

[UninstallDelete]
; لا نحذف بيانات المتجر؛ فهي محفوظة خارج مجلد تثبيت البرنامج.
