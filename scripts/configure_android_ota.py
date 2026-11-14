#!/usr/bin/env python3
"""تهيئة ملفات Android التي ينشئها flutter create لإتاحة تثبيت APK بموافقة المستخدم."""
from pathlib import Path
import re

root = Path(__file__).resolve().parents[1] / "app" / "android" / "app" / "src" / "main"
manifest = root / "AndroidManifest.xml"
if not manifest.is_file():
    raise SystemExit("لم يتم العثور على AndroidManifest.xml بعد إنشاء منصة Android.")

xml = manifest.read_text(encoding="utf-8")
if "android.permission.REQUEST_INSTALL_PACKAGES" not in xml:
    match = re.search(r"<manifest\b[^>]*>", xml)
    if match is None:
        raise SystemExit("تعذر تحديد عنصر manifest.")
    xml = (
        xml[:match.end()]
        + '\n    <uses-permission android:name="android.permission.REQUEST_INSTALL_PACKAGES" />'
        + xml[match.end():]
    )

provider = """        <provider
            android:name="androidx.core.content.FileProvider"
            android:authorities="${applicationId}.fileprovider"
            android:exported="false"
            android:grantUriPermissions="true">
            <meta-data
                android:name="android.support.FILE_PROVIDER_PATHS"
                android:resource="@xml/homi_apk_file_paths" />
        </provider>
"""
if "androidx.core.content.FileProvider" not in xml:
    application_close = re.search(r"</application>", xml)
    if application_close is None:
        raise SystemExit("تعذر تحديد نهاية عنصر application.")
    xml = xml[:application_close.start()] + provider + xml[application_close.start():]
manifest.write_text(xml, encoding="utf-8")

xml_dir = root / "res" / "xml"
xml_dir.mkdir(parents=True, exist_ok=True)
paths_file = xml_dir / "homi_apk_file_paths.xml"
paths_file.write_text(
    """<?xml version="1.0" encoding="utf-8"?>
<paths xmlns:android="http://schemas.android.com/apk/res/android">
    <!-- ملفات التحديث المؤقتة محفوظة في cache الخاص بالتطبيق فقط. -->
    <cache-path name="homi_update_cache" path="." />
</paths>
""",
    encoding="utf-8",
)

activity_files = list((root / "kotlin").rglob("MainActivity.kt"))
if not activity_files:
    activity_files = list((root / "java").rglob("MainActivity.java"))
if not activity_files:
    raise SystemExit("لم يتم العثور على MainActivity بعد إنشاء منصة Android.")
activity = activity_files[0]
if activity.suffix != ".kt":
    raise SystemExit("مسار Android الأصلي المتوقع Kotlin، لم يتم تعديل Java تلقائيًا.")

source = activity.read_text(encoding="utf-8")
source = source.replace(
    "import io.flutter.embedding.android.FlutterActivity",
    "import io.flutter.embedding.android.FlutterFragmentActivity",
)
source = re.sub(
    r"class MainActivity\s*:\s*FlutterActivity\(\)",
    "class MainActivity : FlutterFragmentActivity()",
    source,
)
imports = """import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.content.pm.PackageManager
import androidx.core.content.FileProvider
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
"""
if "import io.flutter.embedding.engine.FlutterEngine" not in source:
    package_match = re.search(r"^package [^\n]+\n", source, flags=re.M)
    if package_match is None:
        raise SystemExit("تعذر تحديد package declaration في MainActivity.")
    source = source[:package_match.end()] + "\n" + imports + source[package_match.end():]

if "com.homi.grocery/apk_installer" not in source:
    if "class MainActivity : FlutterFragmentActivity()" not in source:
        raise SystemExit("تعذر تحويل MainActivity إلى FlutterFragmentActivity.")
    handler = """
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.homi.grocery/apk_installer")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "canRequestPackageInstalls" -> {
                        result.success(Build.VERSION.SDK_INT < Build.VERSION_CODES.O ||
                            packageManager.canRequestPackageInstalls())
                    }
                    "openInstallPermissionSettings" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            val intent = Intent(
                                Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                Uri.parse("package:$packageName")
                            )
                            startActivity(intent)
                        }
                        result.success(null)
                    }
                    "installedVersionCode" -> {
                        val info = if (Build.VERSION.SDK_INT >= 33) {
                            packageManager.getPackageInfo(
                                packageName,
                                PackageManager.PackageInfoFlags.of(0)
                            )
                        } else {
                            @Suppress("DEPRECATION")
                            packageManager.getPackageInfo(packageName, 0)
                        }
                        @Suppress("DEPRECATION")
                        val legacyVersionCode = info.versionCode.toLong()
                        result.success(
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P)
                                info.longVersionCode
                            else
                                legacyVersionCode
                        )
                    }
                    "installApk" -> {
                        try {
                            val rawPath = call.argument<String>("path")
                                ?: throw IllegalArgumentException("مسار APK مفقود.")
                            val apk = File(rawPath).canonicalFile
                            val cache = cacheDir.canonicalFile
                            if (!apk.path.startsWith(cache.path + File.separator) ||
                                !apk.isFile || apk.extension.lowercase() != "apk") {
                                throw SecurityException("ملف APK خارج مجلد التحديث المؤقت.")
                            }
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                                !packageManager.canRequestPackageInstalls()) {
                                result.error(
                                    "INSTALL_PERMISSION_REQUIRED",
                                    "اسمح لـ Homi بتثبيت التطبيقات من هذا المصدر أولًا.",
                                    null
                                )
                            } else {
                                val uri = FileProvider.getUriForFile(
                                    this,
                                    "$packageName.fileprovider",
                                    apk
                                )
                                val intent = Intent(Intent.ACTION_VIEW).apply {
                                    setDataAndType(uri, "application/vnd.android.package-archive")
                                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                }
                                startActivity(intent)
                                result.success(null)
                            }
                        } catch (error: Exception) {
                            result.error("APK_INSTALLER_ERROR", error.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }
"""
    closing = source.rfind("}")
    if closing < 0:
        raise SystemExit("تعذر تحديد نهاية MainActivity.")
    source = source[:closing] + handler + "\n" + source[closing:]
activity.write_text(source, encoding="utf-8")
print("تم إعداد Android APK installer bridge.")
