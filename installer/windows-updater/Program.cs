using System.Diagnostics;
using System.IO.Compression;
using System.Security;

namespace HomiUpdater;

internal static class Program
{
    private const long MaxArchiveBytes = 1024L * 1024 * 1024;
    private const int MaxEntries = 20_000;
    private const long MaxExpandedBytes = 3L * 1024 * 1024 * 1024;

    private static int Main(string[] args)
    {
        try
        {
            var options = ParseArgs(args);
            Apply(options);
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

        return values;
    }

    private static void Apply(IReadOnlyDictionary<string, string> options)
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
            if (!process.ProcessName.Equals("homi_grocery", StringComparison.OrdinalIgnoreCase))
                throw new SecurityException("The supplied process ID is not Homi Grocery.");
            process.WaitForExit();
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

            // لا نحذف النسخة السابقة هنا؛ تظل متاحة للاسترجاع اليدوي بعد التحقق من التشغيل.
        }
        finally
        {
            if (Directory.Exists(stageDir))
                Directory.Delete(stageDir, recursive: true);
        }
    }

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
