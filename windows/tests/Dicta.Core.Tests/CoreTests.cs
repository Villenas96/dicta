using Dicta.Core;
using Xunit;

public class HotkeyTests
{
    [Fact] public void HoldToTalk()
    {
        var m = new HotkeyStateMachine();
        Assert.Equal([HotkeyAction.StartRecording], m.KeyDown(0));
        Assert.Equal([HotkeyAction.StopAndProcess], m.KeyUp(1.2));
    }

    [Fact] public void DoubleTapLocksAndTapStops()
    {
        var m = new HotkeyStateMachine();
        m.KeyDown(0); m.KeyUp(0.1);
        Assert.Equal([HotkeyAction.LockHandsFree], m.KeyDown(0.3));
        m.KeyUp(0.35);
        Assert.Empty(m.Tick(5));
        Assert.True(m.IsRecording);
        Assert.Equal([HotkeyAction.StopAndProcess], m.KeyDown(9));
    }

    [Fact] public void SingleTapDiscarded()
    {
        var m = new HotkeyStateMachine();
        m.KeyDown(0); m.KeyUp(0.1);
        Assert.Equal([HotkeyAction.Cancel], m.Tick(0.6));
    }
}

public class DictionaryTests
{
    static readonly DictionaryEntry[] E = [new("Wispr", []), new("Typeless", [])];

    [Fact] public void FixesWhisper() =>
        Assert.Equal("me lo sigue escribiendo como Wispr y no como Wispr del Wispr Flow",
            DictionaryCorrector.Apply("me lo sigue escribiendo como whisper y no como whisper del whisper Flow", E));

    [Fact] public void Alias() =>
        Assert.Equal("funciona como Typeless", DictionaryCorrector.Apply("funciona como timeless", [new("Typeless", ["timeless"])]));

    [Fact] public void LeavesOthers()
    {
        var s = "Mañana voy de marcha con mi primo, es una persona muy espabilada.";
        Assert.Equal(s, DictionaryCorrector.Apply(s, [new("Wispr", []), new("Marta", []), new("Kubernetes", [])]));
    }
}

public class EditAndTextTests
{
    [Fact] public void Intent()
    {
        Assert.Equal(EditIntent.Replacement, EditIntentClassifier.Classify("Esto no es un dictado."));
        Assert.Equal(EditIntent.Instruction, EditIntentClassifier.Classify("vale, por favor, hazlo más formal"));
        Assert.Equal(EditIntent.Instruction, EditIntentClassifier.Classify("Cámbialo a jueves"));
    }

    [Fact] public void FitInsertion() =>
        Assert.Equal(" y luego vamos.", TextTools.FitInsertion("Y luego vamos.", "Primero comemos,"));

    [Fact] public void Hallucinations()
    {
        Assert.True(LocalCleaner.IsHallucination("Subtítulos realizados por la comunidad de Amara.org"));
        Assert.False(LocalCleaner.IsHallucination("Quiero algo para el jueves."));
    }

    [Fact] public void PlacementAvoidsBox()
    {
        var work = new RectD(0, 0, 1920, 1040);
        var box = new RectD(700, 950, 520, 70);
        var (x, y) = OverlayPlacement.Choose(work, 360, 60, box);
        Assert.False(new RectD(x, y, 360, 60).Intersects(box));
    }
}
