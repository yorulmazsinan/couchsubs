// SPDX-License-Identifier: AGPL-3.0-only

using System.Text.Json;

namespace CouchSubs.Shell.Tests;

/// <summary>Xbox oynatıcı sayfasından ikili kare aktarımı ve kare hattı / kare onayı satırı (#1314).</summary>
public class XboxPlayerPipeTests
{
    [Fact]
    public void FrameBytesAreCopiedFromTheSharedBuffer()
    {
        var shared = new byte[64];
        for (var i = 0; i < shared.Length; i++) shared[i] = (byte)i;
        Assert.Equal(new byte[] { 0, 1, 2, 3, 4 }, XboxPlayerPipe.ReadFrame(new MemoryStream(shared), 5, shared.Length));
    }

    /// <summary>Telefon aramasının durum satırındaki Xbox kare biçimi (#1385): JPEG boyutu, akış boyutu, BGRA adımı.</summary>
    [Fact]
    public void FrameFormatNamesJpegStreamAndStride() =>
        Assert.Equal("Xbox JPEG 1280×720 (akış 1920×1080, kalite %80), BGRA adım 5120",
            XboxPlayerPipe.FrameFormat(1280, 720, "1920×1080", 5120));

    [Fact]
    public void InvalidLengthIsRejected()
    {
        var shared = new MemoryStream(new byte[8]);
        Assert.Null(XboxPlayerPipe.ReadFrame(shared, 0, 8));
        Assert.Null(XboxPlayerPipe.ReadFrame(shared, 9, 8));
    }

    [Fact]
    public void PipeLineNamesMainThreadEncodeAndAckGaps()
    {
        using var document = JsonDocument.Parse("""
            {"kind":"pipe","frames":60,"binary":60,"mainAvg":0.42,"mainMax":1.2,"encodeAvg":12,"encodeMax":30,
             "ackSends":610,"ackMaxGap":40.4,"ackOver":0,"worker":true}
            """);
        Assert.Equal("kare hattı (10 sn): yakalanan 60 (60 ikili, Worker); ana iş parçacığında ort 0.4 ms, en çok 1.2 ms; " +
                     "kodlama ort 12.0 ms, en çok 30.0 ms; kare onayı 610 gönderim, en uzun aralık 40 ms, 250 ms'yi aşan 0",
            XboxPlayerPipe.Describe(document.RootElement));
    }

    [Fact]
    public void MissingFieldsReadAsZeroAndFallbackIsNamed()
    {
        using var document = JsonDocument.Parse("""{"kind":"pipe","frames":3,"ackMaxGap":900,"ackOver":2}""");
        var line = XboxPlayerPipe.Describe(document.RootElement);
        Assert.Contains("yakalanan 3 (0 ikili, ana iş parçacığında kodlama)", line);
        Assert.Contains("en uzun aralık 900 ms, 250 ms'yi aşan 2", line);
    }
}
