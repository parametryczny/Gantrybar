// Only the unused shared catalogue and the logging endpoint need desktop-free stand-ins.
// The physical store, serializer, atomic writer and domain models are production files.
namespace Gantry { internal static class App { internal static void LogError(string source, System.Exception? error) => System.Console.Error.WriteLine(source + ": " + error?.Message); } }
namespace Gantry.Services { public sealed class FilamentStore { } }
