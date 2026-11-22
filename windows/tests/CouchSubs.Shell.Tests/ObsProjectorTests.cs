// SPDX-License-Identifier: AGPL-3.0-only

using CouchSubs.Shell;

namespace CouchSubs.Shell.Tests;

/// <summary>OBS'in Program/Önizleme projektörü CouchSubs'ın OBS katmanını da içerir (Mac: WindowCaptureTests).</summary>
public class ObsProjectorTests
{
    [Theory]
    [InlineData("OBS", "Projector - Program", true)]
    [InlineData("obs64", "Windowed Projector (Preview)", true)]
    [InlineData("OBS Studio", "OBS 31.1.2 - Profil: Yayın - Sahneler: GTA", true)]
    [InlineData("OBS", "Projector - Source: Capture Card", false)]
    [InlineData("obs64", "Projektör - Kaynak: Yakalama kartı", false)]
    [InlineData("obs64", "Windowed Projector (Source) - Elgato", false)]
    [InlineData("RemotePlay", "PS Remote Play", false)]
    [InlineData("Jobs Viewer", "Program", false)]
    public void SourceProjectorHintForObsProgramProjector(string process, string title, bool expected) =>
        Assert.Equal(expected, ObsProjector.NeedsSourceProjectorHint(new WindowCaptureTarget(process, title)));

    [Fact]
    public void NoHintWithoutSelection() => Assert.False(ObsProjector.NeedsSourceProjectorHint(null));
}
