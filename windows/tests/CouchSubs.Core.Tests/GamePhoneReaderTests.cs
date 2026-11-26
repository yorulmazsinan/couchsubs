// SPDX-License-Identifier: AGPL-3.0-only

using CouchSubs.Core;

namespace CouchSubs.Core.Tests;

public class GamePhoneReaderTests
{
    [Theory]
    [InlineData(-0.06)]
    [InlineData(0.06)]
    public void CorrectsBothTiltDirectionsAndRestoresWordAndIconPositions(double tilt)
    {
        var pose = new GamePhoneGeometry.Pose(0.50, 0.16, 0.50 + tilt, 0.82);
        var frame = Frame.Blank(800, 450);
        // Pixel coordinates are encoded in the image, so the fake OCR can verify which part of the source it received.
        for (int y = 0; y < frame.Height; y++)
        for (int x = 0; x < frame.Width; x++)
        {
            int i = y * frame.Stride + x * 4;
            frame.Pixels[i] = (byte)(x / 4);
            frame.Pixels[i + 1] = (byte)(y / 2);
            // Aydınlık ekran: koyu ekran hazırlığı (PhoneDarkScreen) kodlanmış koordinatları değiştirmesin.
            frame.Pixels[i + 2] = 255;
        }
        var reader = new ProbeReader();
        var region = pose.Bounds;
        var reading = new GamePhoneReader().Read(frame, region, pose, reader);
        Assert.Equal(1, reader.Calls);
        Assert.Equal(4, reader.Samples.Count);
        var line = Assert.Single(reading.Lines);
        var box = line.Box!.Value.PlacedIn(new TextBox(region.Left, region.Top, region.Right, region.Bottom));
        Assert.InRange(Math.Abs(box.Left * frame.Width - reader.Samples.Min(p => p.X)), 0, 5);
        Assert.InRange(Math.Abs(box.Right * frame.Width - reader.Samples.Max(p => p.X)), 0, 5);
        Assert.InRange(Math.Abs(box.Top * frame.Height - reader.Samples.Min(p => p.Y)), 0, 3);
        Assert.InRange(Math.Abs(box.Bottom * frame.Height - reader.Samples.Max(p => p.Y)), 0, 3);
        Assert.Equal(line.Box, Assert.Single(line.Words!).Box);
        Assert.Equal(line.Box, Assert.Single(line.Icons!).Box);
        Assert.Equal(new TextBox(0.2, 0.25, 0.6, 0.35), line.PhoneBox);
    }

    [Fact]
    public void WrappedMessagesAndReplyButtonsStayWithTheirOwnBubbleOnAnAngledScreen()
    {
        // Tilt makes the display boxes overlap even between different bubbles.
        static TextLine Line(string text, double x, double y, double right) =>
            new(text, new TextBox(x, y, right, y + 0.068)) { PhoneBox = new TextBox(x, y, right, y + 0.026) };
        var reading = new Reading([
            Line("That was quite a", 0.10, 0.20, 0.75),
            Line("surprise!", 0.10, 0.237, 0.35),
            Line("Did you see it?", 0.10, 0.325, 0.70),
            Line("Ask later", 0.52, 0.78, 0.88),
            Line("No problem", 0.50, 0.862, 0.88),
        ]);
        var groups = GamePhoneText.Groups(reading);
        Assert.Equal(["That was quite a surprise!", "Did you see it?", "Ask later", "No problem"],
            groups.Select(group => Assert.Single(group.Paragraphs)));
        Assert.Equal(reading.Lines[0].Box!.Value.Union(reading.Lines[1].Box!.Value), groups[0].Box);
    }

    [Theory]
    [InlineData(true, false, true, 2, true)]
    [InlineData(true, false, true, 2, false, true)]
    [InlineData(true, false, false, 2, false)]
    [InlineData(false, false, true, 1, false)]
    [InlineData(true, true, true, 1, false)]
    public void ChecksOnlyAnUnreadStripAndRequiresTheSameTailInTheCurrentFrame(
        bool hasInk, bool complete, bool anchorMatches, int calls, bool recovered, bool partial = false)
    {
        var frame = Frame.Blank(200, 300);
        if (hasInk)
            for (int y = 244; y < 266; y++)
            for (int x = 40; x < 150; x++)
                Array.Fill(frame.Pixels, (byte)((x / 3 % 2) * 180), y * frame.Stride + x * 4, 3);
        var anchor = new TextLine("around. Be good", new(.20, .88, .67, .94), Confidence: .98);
        var upper = new TextLine("Just passing through", new(.20, .83, .85, .89), Confidence: .96);
        List<TextLine> lines = [new("Friends", new(.1, .12, .3, .18)), new("See you soon.", new(.1, .49, .6, .54)), anchor];
        if (complete) lines.Add(upper);
        if (partial) lines.Add(new TextLine("passing through", new(.41, .83, .85, .89)));
        var reader = new StripReader(new Reading(lines), crop =>
        {
            Assert.True(crop.Height < frame.Height);
            // Crop includes both lines, and uses the full width of the phone.
            int start = (int)Math.Floor((.88 - 1.6 * (.94 - .88)) * frame.Height);
            int end = (int)Math.Ceiling((.94 + .35 * (.94 - .88)) * frame.Height);
            TextBox Local(TextBox b) => b with { Top = (b.Top * frame.Height - start) / (end - start),
                Bottom = (b.Bottom * frame.Height - start) / (end - start) };
            var upperBox = Local(upper.Box!.Value);
            return new Reading([upper with { Box = upperBox, Words = [new("passing", upperBox)] },
                anchor with { Text = anchorMatches ? anchor.Text : "around the corner", Box = Local(anchor.Box!.Value) }]);
        });
        var phone = new GamePhoneReader();
        var result = phone.ReadMessages(frame, reader);
        Assert.Equal(calls, reader.Calls);
        Assert.Single(result.Lines, l => l.Text == anchor.Text);
        var found = result.Lines.Where(l => l.Text == upper.Text).ToList();
        Assert.Equal(complete || recovered ? 1 : 0, found.Count);
        if (calls == 2 && !anchorMatches)
        {
            // A failed rescue cannot start another OCR pass on each visit to the same chat.
            Assert.Same(result, phone.ReadMessages(frame, reader));
            Assert.Equal(3, reader.Calls);
        }
        if (recovered)
        {
            var line = Assert.Single(found);
            Assert.Equal(upper.Box!.Value.Top, line.Box!.Value.Top, 5);
            Assert.Equal(line.Box, Assert.Single(line.Words!).Box);
        }
    }

    private sealed class StripReader(Reading full, Func<Frame, Reading> strip) : ITextReader
    {
        public int Calls { get; private set; }
        public string Read(Frame image) => throw new NotSupportedException();
        public Reading ReadScreen(Frame image)
        {
            Calls++;
            return image.Height == 300 ? full : strip(image);
        }
    }

    private sealed class ProbeReader : ITextReader
    {
        public int Calls { get; private set; }
        public List<(double X, double Y)> Samples { get; } = [];
        public string Read(Frame image) => throw new NotSupportedException();
        public Reading ReadScreen(Frame image)
        {
            Calls++;
            var box = new TextBox(0.2, 0.25, 0.6, 0.35);
            foreach (double v in new[] { box.Top, box.Bottom })
            foreach (double u in new[] { box.Left, box.Right })
            {
                int i = (int)(image.Height * v) * image.Stride + (int)(image.Width * u) * 4;
                Samples.Add((image.Pixels[i] * 4, image.Pixels[i + 1] * 2));
            }
            return new Reading([new TextLine("Notice", box, Words: [new TextWord("Notice", box)],
                                            Icons: [new IconSlot(box, "X")])]);
        }
    }
}
