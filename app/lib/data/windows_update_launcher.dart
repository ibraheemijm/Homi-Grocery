// تشغيل منسق تحديث Windows المثبت رسميًا؛ لا يمنح التطبيق نفسه صلاحيات المسؤول.
import 'dart:io';

import 'package:path/path.dart' as p;

class WindowsUpdateLauncher {
  Future<void> launch({
    required File package,
    required String sha256,
  }) async {
    if (!Platform.isWindows) {
      throw UnsupportedError('منسق تحديث Windows متاح على Windows فقط.');
    }
    if (!RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(sha256)) {
      throw const FormatException('بصمة SHA-256 غير صالحة.');
    }
    if (!await package.exists() || await package.length() < 1) {
      throw const FormatException('حزمة تحديث Windows غير موجودة أو فارغة.');
    }

    final executable = File(Platform.resolvedExecutable).absolute;
    final installDirectory = executable.parent;
    if (!await installDirectory.exists()) {
      throw const FileSystemException('مجلد تثبيت Homi غير موجود.');
    }

    final programData = Platform.environment['ProgramData'] ?? r'C:\ProgramData';
    final updaterDirectory = p.join(programData, 'Homi Grocery', 'Updater');
    final launcher = File(p.join(updaterDirectory, 'HomiUpdateLauncher.exe'));
    final updater = File(p.join(updaterDirectory, 'HomiUpdater.exe'));
    if (!await launcher.exists() || !await updater.exists()) {
      throw const FileSystemException(
        'أدوات التحديث غير موجودة. أعد تثبيت Homi باستخدام المثبت الرسمي.',
      );
    }

    final packagePath = p.normalize(package.absolute.path);
    final installPath = p.normalize(installDirectory.path);
    if (p.isWithin(installPath, packagePath)) {
      throw const FileSystemException(
        'يجب أن تكون حزمة التحديث خارج مجلد تثبيت التطبيق.',
      );
    }

    await Process.start(
      launcher.path,
      [
        '--pid',
        pid.toString(),
        '--install-dir',
        installDirectory.path,
        '--package',
        packagePath,
        '--sha256',
        sha256,
        '--updater',
        updater.path,
      ],
      workingDirectory: installDirectory.path,
      mode: ProcessStartMode.detached,
    );
  }
}
