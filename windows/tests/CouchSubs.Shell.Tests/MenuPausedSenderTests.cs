// SPDX-License-Identifier: AGPL-3.0-only

using CouchSubs.Core;
using CouchSubs.Shell;

namespace CouchSubs.Shell.Tests;

public class MenuPausedSenderTests
{
    private sealed class Sink : ISubtitleSender
    {
        public List<string> Sent { get; } = [];
        public int Clears;
        public void SendSubtitle(string text, int durationMs = 15000, TextBox? box = null, bool paragraphs = false, bool replaces = false) => Sent.Add(text);
        public void Clear() => Clears++;
    }

    [Fact]
    public void SubtitlesWaitWhileAMenuIsOnScreen()
    {
        var sink = new Sink();
        var menu = false;
        var sender = new MenuPausedSender(sink, () => menu);
        sender.SendSubtitle("Bir");
        menu = true;
        sender.SendSubtitle("RESTORE DEFAULT");
        sender.Clear();
        menu = false;
        sender.SendSubtitle("İki");
        Assert.Equal(["Bir", "İki"], sink.Sent);
        Assert.Equal(1, sink.Clears);
    }
}
