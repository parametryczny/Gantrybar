namespace Gantry.Models;

/// One per-printer automation: a trigger → action rule. Flat (JSON-friendly) model; TriggerKind /
/// ActionKind are string tags with a value field, rather than the discriminated enums used on macOS.
public sealed class PrinterAutomation
{
    public string Id { get; set; } = Guid.NewGuid().ToString();
    public string Name { get; set; } = "";
    public bool Enabled { get; set; } = true;

    // Trigger: "manual" | "layer" | "progress" | "state"
    public string TriggerKind { get; set; } = "manual";
    public int TriggerValue { get; set; }          // layer N or progress %
    public string TriggerState { get; set; } = ""; // PrinterState name for the "state" trigger

    // Action: "lightOn" | "lightOff" | "pause" | "resume" | "stop" | "notify" | "command" | "script"
    public string ActionKind { get; set; } = "lightOff";
    public string ActionText { get; set; } = "";   // notify text / raw command / script content

    public bool IsScript => ActionKind == "script";

    public PrinterAutomation Clone() => (PrinterAutomation)MemberwiseClone();
}
