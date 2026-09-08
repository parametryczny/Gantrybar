using Gantry.Services;
StartupState.RunSelfTest();
for (int count = 1; count <= 10; count++)
{
    var state = new StartupState(Enumerable.Range(0, count).Select(i => i.ToString()), () => 0);
    int threshold = (count * 3 + 4) / 5;
    for (int i = 0; i < threshold; i++)
    {
        if (!state.Loading) throw new Exception("Threshold rounded down");
        state.Report(i.ToString());
    }
    if (state.Loading) throw new Exception("Threshold rounded incorrectly");
}
Console.WriteLine("Windows startup policy OK — 60%, unique reports, timeout, empty fleet, one-shot guide");
