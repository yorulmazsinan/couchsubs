// SPDX-License-Identifier: AGPL-3.0-only

namespace CouchSubs.Core.Tests;

/// <summary>Ekranda zaten Türkçe olan satır çevrilmez (#289; Mac: TurkishTextTests.swift, Android: TurkishTextTest.kt).</summary>
public class TurkishTextTests
{
    private static readonly Frame Image = Frame.Blank(64, 64);

    [Theory]
    [InlineData("Daha Sonra Güncelle")]
    [InlineData("Sistem Yazillml Güncellem€")] // Yazı tanıma "Yazılımı Güncellemesi"ni bozmuş.
    [InlineData("Lütfen bekleyin.")]
    [InlineData("Ekran görüntüsü kaydedildi")]
    [InlineData("Yardımcı\nolabilir miyim, efendim?")]
    [InlineData("Merchant: Yardımcı olabilir miyim, efendim?")]
    public void TurkishLineIsSure(string text) => Assert.True(TurkishText.IsSure(text));

    [Theory]
    [InlineData("Atatürk said we must defend the city.")]
    [InlineData("Herr Müller wants the system back online.")]
    [InlineData("Play Grand Theft Auto V's Story Mode.")]
    [InlineData("Kurulum sirasmda PS5 sisteminizi kapatmayn.")] // Türkçe harf yok: temkinli, çeviriye gider.
    public void OtherLinesAreNotSure(string text) => Assert.False(TurkishText.IsSure(text));

    private static async Task Run(SubtitlePipeline pipeline, int frames)
    {
        for (var i = 0; i < frames; i++)
        {
            await pipeline.ProcessAsync(Image, new CropRegion());
            await pipeline.WaitForTranslationsAsync();
        }
    }

    [Fact]
    public async Task TurkishLineIsNotSentToTheEngine()
    {
        var sender = new FakeSender();
        var translator = new FakeTranslator();
        var pipeline = new SubtitlePipeline(new FakeReader("Daha Sonra Güncelle", "Daha Sonra Güncelle", "Daha Sonra Güncelle"), translator, sender);
        await Run(pipeline, 3);
        Assert.Empty(translator.Requested);
        Assert.Empty(sender.Sent);
    }

    [Fact]
    public async Task EnglishLineWithTurkishNameIsTranslated()
    {
        const string line = "Atatürk said no.";
        var sender = new FakeSender();
        var translator = new FakeTranslator();
        var pipeline = new SubtitlePipeline(new FakeReader(line, line, line), translator, sender);
        await Run(pipeline, 3);
        Assert.Equal([line], translator.Requested);
        Assert.Equal(["TR: " + line], sender.Sent);
    }

    [Fact]
    public async Task OtherTargetLanguageTranslatesTurkish()
    {
        var translator = new FakeTranslator();
        var pipeline = new SubtitlePipeline(new FakeReader("Daha Sonra Güncelle", "Daha Sonra Güncelle", "Daha Sonra Güncelle"), translator,
            new FakeSender()) { SkipsTurkish = false };
        await Run(pipeline, 3);
        Assert.Equal(["Daha Sonra Güncelle"], translator.Requested);
    }
}
