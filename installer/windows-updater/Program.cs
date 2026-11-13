using System.Buffers.Binary;
using System.Diagnostics;
using System.IO.Compression;
using System.IO.Pipes;
using Microsoft.Win32;
using System.Security;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace HomiUpdater;

internal static class Program
{
    private const long MaxArchiveBytes = 1024L * 1024 * 1024;
    private const int MaxEntries = 20_000;
    private const long MaxExpandedBytes = 3L * 1024 * 1024 * 1024;
    private const int AppExitTimeoutMilliseconds = 120_000;

    private static async Task<int> Main(string[] args)
    {
        try
        {
            var options = ParseArgs(args);
            var update = Apply(options);
            if (options.ContainsKey("pipe-name"))
                await NotifyLauncherAsync(options["pipe-name"], options["nonce"], update);
            Console.WriteLine("Homi Grocery update applied successfully.");
            return 0;
        }
        catch (Exception error)
        {
            Console.Error.WriteLine($"Homi updater failed: {error.Message}");
            return 1;
        }
    }

    private static Dictionary<string, string> ParseArgs(string[] args)
    {
        var values = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        for (var i = 0; i < args.Length; i++)
        {
            if (!args[i].StartsWith("--", StringComparison.Ordinal) || i + 1 >= args.Length)
                throw new ArgumentException("Invalid updater arguments.");
            if (!values.TryAdd(args[i][2..], args[++i]))
                throw new ArgumentException("Duplicate updater argument.");
        }

        foreach (var required in new[] { "pid", "install-dir", "package", "sha256" })
            if (!values.ContainsKey(required))
                throw new ArgumentException($"Missing argument: {required}");

        var allowed = new HashSet<string>(
            ["pid", "install-dir", "package", "sha256", "pipe-name", "nonce"],
            StringComparer.OrdinalIgnoreCase);
        if (values.Keys.Any(key => !allowed.Contains(key)))
            throw new ArgumentException("Unknown updater argument.");

        if (values.ContainsKey("pipe-name") != values.ContainsKey("nonce"))
            throw new ArgumentException("Launcher pipe name and nonce must be supplied together.");
        if (values.TryGetValue("pipe-name", out var pipeName) &&
            !System.Text.RegularExpressions.Regex.IsMatch(pipeName, "^homi-update-[0-9a-f]{32}$"))
            throw new ArgumentException("Invalid launcher pipe name.");
        if (values.TryGetValue("nonce", out var nonce) &&
            !System.Text.RegularExpressions.Regex.IsMatch(nonce, "^[0-9A-F]{64}$"))
            throw new ArgumentException("Invalid launcher nonce.");

        return values;
    }

    private static UpdateResult Apply(IReadOnlyDictionary<string, string> options)
    {
        if (!int.TryParse(options["pid"], out var processId) || processId <= 0)
            throw new ArgumentException("Invalid application process ID.");

        var installDir = Path.TrimEndingDirectorySeparator(Path.GetFullPath(options["install-dir"]));
        var packagePath = Path.GetFullPath(options["package"]);
        var installRoot = Path.GetPathRoot(installDir);
        if (string.IsNullOrWhiteSpace(installRoot) ||
            string.Equals(installDir, Path.TrimEndingDirectorySeparator(installRoot), StringComparison.OrdinalIgnoreCase) ||
            !Directory.Exists(installDir))
            throw new SecurityException("The installation directory is unsafe or missing.");

        // لا نسمح للمساعد المرتفع باستهداف مجلد يمرره المستدعي عشوائيًا؛
        // يجب أن يطابق المسار المسجل في HKLM بواسطة مثبت Homi الرسمي.
        EnsureRegisteredInstallDirectory(installDir);

        var installInfo = new DirectoryInfo(installDir);
        if ((installInfo.Attributes & FileAttributes.ReparsePoint) != 0)
            throw new SecurityException("The installation directory cannot be a symbolic link or junction.");

        var installPrefix = installDir + Path.DirectorySeparatorChar;
        if (packagePath.StartsWith(installPrefix, StringComparison.OrdinalIgnoreCase))
            throw new SecurityException("The update package must be outside the installation directory.");

        if (!File.Exists(packagePath))
            throw new FileNotFoundException("Update package was not found.", packagePath);

        // افحص الحجم قبل قراءة الملف وحساب البصمة لتجنب استهلاك غير محدود للذاكرة أو الوقت.
        var archiveInfo = new FileInfo(packagePath);
        if (archiveInfo.Length is <= 0 or > MaxArchiveBytes)
            throw new InvalidDataException("Update archive size is invalid.");

        if (!System.Text.RegularExpressions.Regex.IsMatch(options["sha256"], "^[0-9a-fA-F]{64}$"))
            throw new ArgumentException("Invalid package SHA-256.");
        using (var stream = File.OpenRead(packagePath))
        {
            var digest = Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(stream));
            if (!digest.Equals(options["sha256"], StringComparison.OrdinalIgnoreCase))
                throw new SecurityException("Update package SHA-256 verification failed.");
        }

        try
        {
            using var process = Process.GetProcessById(processId);
            if (!process.HasExited)
            {
                if (!process.ProcessName.Equals("homi_grocery", StringComparison.OrdinalIgnoreCase))
                    throw new SecurityException("The supplied process ID is not Homi Grocery.");

                // تحقق من أن PID يعود إلى نسخة Homi الموجودة في مجلد التثبيت نفسه،
                // وليس إلى عملية أخرى تحمل الاسم ذاته.
                var runningExecutable = process.MainModule?.FileName;
                var expectedExecutable = Path.Combine(installDir, "homi_grocery.exe");
                if (string.IsNullOrWhiteSpace(runningExecutable) ||
                    !Path.GetFullPath(runningExecutable).Equals(
                        Path.GetFullPath(expectedExecutable),
                        StringComparison.OrdinalIgnoreCase))
                    throw new SecurityException("The supplied process is not running from the target installation.");

                if (!process.WaitForExit(AppExitTimeoutMilliseconds))
                    throw new TimeoutException("Homi Grocery did not close within the allowed update window.");
            }
        }
        catch (ArgumentException)
        {
            // التطبيق قد يكون أغلق قبل بدء المساعد؛ لا توجد عملية لانتظارها.
        }

        var parent = Directory.GetParent(installDir)?.FullName
            ?? throw new SecurityException("Installation parent directory is invalid.");
        var leaf = Path.GetFileName(installDir);
        var token = Guid.NewGuid().ToString("N");
        var stageDir = Path.Combine(parent, $".{leaf}.homi-stage-{token}");
        var backupDir = Path.Combine(parent, $".{leaf}.homi-backup-{DateTime.UtcNow:yyyyMMddHHmmss}-{token}");

        try
        {
            ExtractAndValidate(packagePath, stageDir);
            if (!File.Exists(Path.Combine(stageDir, "homi_grocery.exe")))
                throw new InvalidDataException("Update archive does not contain homi_grocery.exe.");

            Directory.Move(installDir, backupDir);
            try
            {
                Directory.Move(stageDir, installDir);
            }
            catch
            {
                if (!Directory.Exists(installDir) && Directory.Exists(backupDir))
                    Directory.Move(backupDir, installDir);
                throw;
            }

            // لا نحذف النسخة السابقة؛ يقرر المنسق اعتماد التحديث أو استرجاعها بعد فحص صحة التطبيق.
            return new UpdateResult(installDir, backupDir);
        }
        finally
        {
            if (Directory.Exists(stageDir))
                Directory.Delete(stageDir, recursive: true);
        }
    }

    private static async Task NotifyLauncherAsync(
        string pipeName,
        string nonce,
        UpdateResult update)
    {
        var rollbackAttempted = false;
        try
        {
            await using var pipe = new NamedPipeClientStream(
                ".",
                pipeName,
                PipeDirection.InOut,
                PipeOptions.Asynchronous);

            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(150));
            await pipe.ConnectAsync(timeout.Token);

            await WriteMessageAsync(pipe, new ProtocolMessage(1, "installed", nonce), timeout.Token);
            var decision = await ReadMessageAsync(pipe, timeout.Token);
            if (decision.Version != 1 ||
                !CryptographicOperations.FixedTimeEquals(
                    Encoding.UTF8.GetBytes(nonce),
                    Encoding.UTF8.GetBytes(decision.Nonce ?? string.Empty)))
                throw new SecurityException("Launcher decision authentication failed.");

            if (decision.Type == "commit")
                return;

            if (decision.Type != "rollback")
                throw new SecurityException("Launcher sent an unsupported update decision.");

            rollbackAttempted = true;
            RestorePreviousVersion(update);
            Console.WriteLine("The update was rolled back by the launcher.");
        }
        catch
        {
            // انقطاع المنسق أو انتهاء المهلة بعد تبديل الملفات يعني أن النسخة الجديدة
            // لم تحصل على تأكيد صحة؛ لذلك نرجع إلى النسخة السابقة تلقائيًا.
            if (!rollbackAttempted && Directory.Exists(update.BackupDirectory))
                RestorePreviousVersion(update);
            throw;
        }
    }

    private static async Task WriteMessageAsync(
        Stream stream,
        ProtocolMessage message,
        CancellationToken cancellationToken)
    {
        var payload = JsonSerializer.SerializeToUtf8Bytes(message);
        if (payload.Length is <= 0 or > 4096)
            throw new InvalidDataException("Launcher protocol message size is invalid.");

        var header = new byte[sizeof(int)];
        BinaryPrimitives.WriteInt32LittleEndian(header, payload.Length);
        await stream.WriteAsync(header, cancellationToken);
        await stream.WriteAsync(payload, cancellationToken);
        await stream.FlushAsync(cancellationToken);
    }

    private static async Task<ProtocolMessage> ReadMessageAsync(
        Stream stream,
        CancellationToken cancellationToken)
    {
        var header = new byte[sizeof(int)];
        await stream.ReadExactlyAsync(header, cancellationToken);
        var length = BinaryPrimitives.ReadInt32LittleEndian(header);
        if (length is <= 0 or > 4096)
            throw new InvalidDataException("Launcher protocol message size is invalid.");

        var payload = new byte[length];
        await stream.ReadExactlyAsync(payload, cancellationToken);
        return JsonSerializer.Deserialize<ProtocolMessage>(payload)
            ?? throw new InvalidDataException("Launcher protocol message is empty.");
    }

    private static void StopInstalledApplication(string installDirectory)
    {
        var expectedExecutable = Path.GetFullPath(Path.Combine(installDirectory, "homi_grocery.exe"));
        foreach (var process in Process.GetProcessesByName("homi_grocery"))
        {
            using (process)
            {
                try
                {
                    var runningExecutable = process.MainModule?.FileName;
                    if (string.IsNullOrWhiteSpace(runningExecutable))
                        throw new SecurityException("Could not verify the executable path of a running Homi Grocery process.");

                    if (!Path.GetFullPath(runningExecutable).Equals(
                            expectedExecutable,
                            StringComparison.OrdinalIgnoreCase))
                        continue;

                    if (!process.HasExited)
                    {
                        process.Kill(entireProcessTree: true);
                        if (!process.WaitForExit(10_000))
                            throw new TimeoutException("Updated Homi Grocery process could not be stopped for rollback.");
                    }
                }
                catch (InvalidOperationException)
                {
                    // انتهت العملية أثناء الفحص؛ يمكن متابعة الاسترجاع.
                }
                catch (System.ComponentModel.Win32Exception error)
                {
                    // فشل التحقق من العملية يمنع الاسترجاع الآمن؛ لا نتابع وكأن المسار أصبح خاليًا.
                    throw new SecurityException(
                        "Could not safely inspect or stop the updated Homi Grocery process; rollback was halted.",
                        error);
                }
            }
        }
    }

    private static void RestorePreviousVersion(UpdateResult update)
    {
        StopInstalledApplication(update.InstallDirectory);
        if (!Directory.Exists(update.BackupDirectory))
            throw new DirectoryNotFoundException("Previous application backup is unavailable; automatic rollback cannot continue.");

        var failedDirectory = update.InstallDirectory + ".homi-rejected-" + Guid.NewGuid().ToString("N");
        if (Directory.Exists(update.InstallDirectory))
            Directory.Move(update.InstallDirectory, failedDirectory);

        try
        {
            Directory.Move(update.BackupDirectory, update.InstallDirectory);
        }
        catch
        {
            if (!Directory.Exists(update.InstallDirectory) && Directory.Exists(failedDirectory))
                Directory.Move(failedDirectory, update.InstallDirectory);
            throw;
        }

        if (Directory.Exists(failedDirectory))
            Directory.Delete(failedDirectory, recursive: true);
    }

    private static void EnsureRegisteredInstallDirectory(string installDir)
    {
        using var baseKey = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry64);
        using var key = baseKey.OpenSubKey(@"Software\Homi Grocery", writable: false)
            ?? throw new SecurityException("Homi Grocery installation is not registered by the official installer.");

        var registeredPath = key.GetValue(
            "InstallDir",
            null,
            RegistryValueOptions.DoNotExpandEnvironmentNames) as string;
        if (string.IsNullOrWhiteSpace(registeredPath))
            throw new SecurityException("The registered Homi Grocery installation path is missing.");

        var normalizedRegisteredPath = Path.TrimEndingDirectorySeparator(Path.GetFullPath(registeredPath));
        if (!installDir.Equals(normalizedRegisteredPath, StringComparison.OrdinalIgnoreCase))
            throw new SecurityException("The requested installation directory does not match the registered Homi Grocery installation.");
    }

    private sealed record ProtocolMessage(int Version, string Type, string? Nonce);
    private sealed record UpdateResult(string InstallDirectory, string BackupDirectory);

    private static void ExtractAndValidate(string archivePath, string stageDir)
    {
        using var archive = ZipFile.OpenRead(archivePath);
        if (archive.Entries.Count is 0 or > MaxEntries)
            throw new InvalidDataException("Update archive entry count is invalid.");

        var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        long expandedBytes = 0;
        var root = Path.GetFullPath(stageDir) + Path.DirectorySeparatorChar;
        Directory.CreateDirectory(stageDir);

        foreach (var entry in archive.Entries)
        {
            var name = entry.FullName.Replace('\\', '/');
            if (string.IsNullOrWhiteSpace(name) || name.StartsWith('/') ||
                Path.IsPathRooted(name) ||
                name.Split('/').Any(part => part is "." or ".." || part.Contains(':')))
                throw new SecurityException("Archive contains an unsafe path.");

            // Reject Unix symlinks and other non-regular special entries.
            var unixType = (entry.ExternalAttributes >> 16) & 0xF000;
            if (unixType == 0xA000)
                throw new SecurityException("Archive symlinks are not allowed.");

            var destination = Path.GetFullPath(Path.Combine(stageDir, name.Replace('/', Path.DirectorySeparatorChar)));
            if (!destination.StartsWith(root, StringComparison.OrdinalIgnoreCase))
                throw new SecurityException("Archive entry escapes the staging directory.");

            if (!names.Add(name.TrimEnd('/')))
                throw new InvalidDataException("Archive contains duplicate paths.");

            if (name.EndsWith('/'))
            {
                Directory.CreateDirectory(destination);
                continue;
            }

            if (entry.Length > MaxExpandedBytes - expandedBytes)
                throw new InvalidDataException("Expanded update package is too large.");

            Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
            using var input = entry.Open();
            using var output = new FileStream(destination, FileMode.CreateNew, FileAccess.Write, FileShare.None);
            var buffer = new byte[81920];
            long entryBytes = 0;
            int bytesRead;
            while ((bytesRead = input.Read(buffer, 0, buffer.Length)) > 0)
            {
                entryBytes = checked(entryBytes + bytesRead);
                expandedBytes = checked(expandedBytes + bytesRead);
                // لا نعتمد على أحجام ZIP الوصفية وحدها؛ نحد الحجم الفعلي أثناء فك الضغط.
                if (entryBytes > entry.Length || expandedBytes > MaxExpandedBytes)
                    throw new InvalidDataException("Expanded update package exceeded its declared or allowed size.");
                output.Write(buffer, 0, bytesRead);
            }
            if (entryBytes != entry.Length)
                throw new InvalidDataException("Extracted file length does not match the archive.");
        }
    }
}
