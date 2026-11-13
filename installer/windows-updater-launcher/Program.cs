using System.Buffers.Binary;
using System.ComponentModel;
using System.Diagnostics;
using System.IO.Pipes;
using System.Security;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace HomiUpdateLauncher;

internal static class Program
{
    private const int ProtocolVersion = 1;
    private const int MaxMessageBytes = 4096;
    private static readonly TimeSpan ConnectionTimeout = TimeSpan.FromSeconds(150);

    private static async Task<int> Main(string[] args)
    {
        try
        {
            if (!OperatingSystem.IsWindows())
                throw new PlatformNotSupportedException("The Windows update launcher can run only on Windows.");

            var options = ParseArgs(args);
            await LaunchElevatedUpdaterAsync(options);
            Console.WriteLine("تم استلام تأكيد تبديل ملفات التطبيق من مساعد التحديث.");
            return 0;
        }
        catch (Win32Exception error) when (error.NativeErrorCode == 1223)
        {
            Console.Error.WriteLine("ألغى المستخدم طلب صلاحيات المسؤول؛ لم يبدأ التحديث.");
            return 2;
        }
        catch (Exception error)
        {
            Console.Error.WriteLine($"تعذر تنسيق تحديث Homi Grocery: {error.Message}");
            return 1;
        }
    }

    private static Dictionary<string, string> ParseArgs(string[] args)
    {
        var values = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        for (var i = 0; i < args.Length; i++)
        {
            if (!args[i].StartsWith("--", StringComparison.Ordinal) || i + 1 >= args.Length)
                throw new ArgumentException("وسائط تشغيل المنسق غير صحيحة.");
            if (!values.TryAdd(args[i][2..], args[++i]))
                throw new ArgumentException("تكرر أحد وسائط تشغيل المنسق.");
        }

        var expected = new HashSet<string>(
            ["pid", "install-dir", "package", "sha256", "updater"],
            StringComparer.OrdinalIgnoreCase);
        if (values.Count != expected.Count || values.Keys.Any(key => !expected.Contains(key)))
            throw new ArgumentException("يجب تمرير وسائط pid وinstall-dir وpackage وsha256 وupdater فقط.");

        if (!int.TryParse(values["pid"], out var processId) || processId <= 0)
            throw new ArgumentException("معرّف عملية التطبيق غير صحيح.");
        if (!System.Text.RegularExpressions.Regex.IsMatch(values["sha256"], "^[0-9a-fA-F]{64}$"))
            throw new ArgumentException("بصمة SHA-256 غير صحيحة.");

        values["install-dir"] = Path.TrimEndingDirectorySeparator(Path.GetFullPath(values["install-dir"]));
        values["package"] = Path.GetFullPath(values["package"]);
        values["updater"] = Path.GetFullPath(values["updater"]);

        if (!Directory.Exists(values["install-dir"]))
            throw new DirectoryNotFoundException("مجلد تثبيت Homi Grocery غير موجود.");
        if (!File.Exists(values["package"]))
            throw new FileNotFoundException("حزمة التحديث غير موجودة.", values["package"]);
        if (!File.Exists(values["updater"]))
            throw new FileNotFoundException("مساعد التحديث غير موجود.", values["updater"]);

        var installPrefix = values["install-dir"] + Path.DirectorySeparatorChar;
        if (values["package"].StartsWith(installPrefix, StringComparison.OrdinalIgnoreCase) ||
            values["updater"].StartsWith(installPrefix, StringComparison.OrdinalIgnoreCase))
            throw new SecurityException("يجب أن تكون حزمة التحديث ومساعده خارج مجلد تثبيت التطبيق.");

        return values;
    }

    private static async Task LaunchElevatedUpdaterAsync(IReadOnlyDictionary<string, string> options)
    {
        var pipeName = $"homi-update-{Guid.NewGuid():N}";
        var nonce = Convert.ToHexString(RandomNumberGenerator.GetBytes(32));

        // CurrentUserOnly يمنع مستخدم Windows آخر من الاتصال بقناة التحديث.
        await using var pipe = new NamedPipeServerStream(
            pipeName,
            PipeDirection.InOut,
            maxNumberOfServerInstances: 1,
            PipeTransmissionMode.Byte,
            PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);

        var arguments = new[]
        {
            "--pid", options["pid"],
            "--install-dir", options["install-dir"],
            "--package", options["package"],
            "--sha256", options["sha256"],
            "--pipe-name", pipeName,
            "--nonce", nonce
        };

        var startInfo = new ProcessStartInfo
        {
            FileName = options["updater"],
            Arguments = string.Join(" ", arguments.Select(QuoteWindowsArgument)),
            WorkingDirectory = Path.GetDirectoryName(options["updater"])!,
            UseShellExecute = true,
            Verb = "runas"
        };

        using var updater = Process.Start(startInfo)
            ?? throw new InvalidOperationException("تعذر تشغيل مساعد التحديث بصلاحيات المسؤول.");

        using var timeout = new CancellationTokenSource(ConnectionTimeout);
        var connectTask = pipe.WaitForConnectionAsync(timeout.Token);
        var exitTask = updater.WaitForExitAsync();

        var completed = await Task.WhenAny(connectTask, exitTask);
        if (completed == exitTask && !pipe.IsConnected)
        {
            await exitTask;
            throw new InvalidOperationException(
                $"انتهى مساعد التحديث قبل إنشاء قناة الاتصال (رمز الخروج: {updater.ExitCode}).");
        }

        try
        {
            await connectTask;
        }
        catch (OperationCanceledException)
        {
            throw new TimeoutException("انتهت مهلة انتظار اتصال مساعد التحديث.");
        }

        var message = await ReadMessageAsync(pipe, timeout.Token);
        var expectedNonce = Encoding.UTF8.GetBytes(nonce);
        var receivedNonce = Encoding.UTF8.GetBytes(message.Nonce ?? string.Empty);
        if (message.Version != ProtocolVersion ||
            !CryptographicOperations.FixedTimeEquals(expectedNonce, receivedNonce) ||
            !string.Equals(message.Type, "installed", StringComparison.Ordinal))
            throw new SecurityException("رفض المنسق رسالة غير موثوقة أو خارج تسلسل بروتوكول التحديث.");

        // هذه المرحلة تتحقق من قناة الاتصال فقط. قرار commit/rollback وتشغيل النسخة
        // الجديدة وفحص صحتها سيضاف بعد توصيل المساعد ببروتوكول الاسترداد.
    }

    private static async Task<ProtocolMessage> ReadMessageAsync(
        Stream stream,
        CancellationToken cancellationToken)
    {
        var header = new byte[sizeof(int)];
        await stream.ReadExactlyAsync(header, cancellationToken);
        var length = BinaryPrimitives.ReadInt32LittleEndian(header);
        if (length is <= 0 or > MaxMessageBytes)
            throw new InvalidDataException("حجم رسالة بروتوكول التحديث غير مسموح.");

        var payload = new byte[length];
        await stream.ReadExactlyAsync(payload, cancellationToken);
        return JsonSerializer.Deserialize<ProtocolMessage>(payload)
            ?? throw new InvalidDataException("رسالة بروتوكول التحديث فارغة.");
    }

    private static string QuoteWindowsArgument(string value)
    {
        // اقتباس متوافق مع قواعد سطر أوامر Windows، بما فيها الشرطات العكسية قبل علامات الاقتباس.
        if (value.Length > 0 && !value.Any(char.IsWhiteSpace) && !value.Contains('"'))
            return value;

        var result = new StringBuilder("\"");
        var backslashes = 0;
        foreach (var character in value)
        {
            if (character == '\\')
            {
                backslashes++;
                continue;
            }

            if (character == '"')
            {
                result.Append('\\', backslashes * 2 + 1);
                result.Append('"');
                backslashes = 0;
                continue;
            }

            result.Append('\\', backslashes);
            backslashes = 0;
            result.Append(character);
        }

        result.Append('\\', backslashes * 2);
        result.Append('"');
        return result.ToString();
    }

    private sealed record ProtocolMessage(int Version, string Type, string? Nonce);
}
