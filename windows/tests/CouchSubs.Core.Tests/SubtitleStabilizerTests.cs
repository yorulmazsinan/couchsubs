// SPDX-License-Identifier: AGPL-3.0-only

using CouchSubs.Core;

namespace CouchSubs.Core.Tests;

public class SubtitleStabilizerTests
{
    /// Noktalamayla bitmeyen satır yazılmakta olabilir; iki kare aynı okununca gönderilir.
    [Fact]
    public void UnfinishedLineIsSentAfterTwoStableFrames()
    {
        var s = new SubtitleStabilizer();
        Assert.Equal(StabilizerAction.None, s.Feed("We do not have time"));
        Assert.Equal(StabilizerAction.Translate("We do not have time"), s.Feed("We do not have time"));
        Assert.Equal(StabilizerAction.None, s.Feed("We do not have time"));
    }

    /// Süslü yazıda aynı cümle her karede başka çöple okunur; TV'de iki çeviri olarak görünmemeli.
    [Fact]
    public void GarbledRereadOfSentLineDoesNotReemit()
    {
        var s = new SubtitleStabilizer();
        const string first = "Across the deep waters, Pbo went,\nhoping a boat would carry him home.";
        Assert.Equal(StabilizerAction.Translate(first), s.Feed(first));
        Assert.Equal(StabilizerAction.None, s.Feed("Across the deep waters O went,"));
        Assert.Equal(StabilizerAction.None, s.Feed("Across the deep waters O went,"));
        Assert.Equal(StabilizerAction.Translate("We should keep moving."), s.Feed("We should keep moving."));
    }

    /// Cümle bitmişse beklemeye gerek yok; hızlı konuşmada her kare önemli.
    [Theory]
    [InlineData("We do not have time.")]
    [InlineData("Wait!")]
    [InlineData("Who are you?")]
    [InlineData("I know…")]
    [InlineData("\"Run.\"")]
    public void FinishedSentenceIsSentOnFirstFrame(string line)
    {
        var s = new SubtitleStabilizer();
        Assert.Equal(StabilizerAction.Translate(line), s.Feed(line));
        Assert.Equal(StabilizerAction.None, s.Feed(line));
    }

    [Fact]
    public void OcrNoiseDoesNotReemit()
    {
        var s = new SubtitleStabilizer();
        s.Feed("The gate will not hold"); s.Feed("The gate will not hold");
        Assert.Equal(StabilizerAction.None, s.Feed("The gale will not hold"));
        Assert.Equal(StabilizerAction.None, s.Feed("The gale will not hold"));
    }

    [Fact]
    public void FlickeringHudDoesNotSpam()
    {
        var s = new SubtitleStabilizer();
        var sent = 0;
        for (var i = 0; i < 20; i++)
            if (s.Feed(i % 2 == 0 ? "24 / 120" : "").Kind == StabilizerKind.Translate) sent++;
        Assert.Equal(0, sent);
    }

    [Fact]
    public void TypewriterSendsCompletedLine()
    {
        var s = new SubtitleStabilizer();
        s.Feed("We do"); s.Feed("We do not have");
        Assert.Equal(StabilizerAction.Translate("We do not have time for this, boy."), s.Feed("We do not have time for this, boy."));
        Assert.Equal(StabilizerAction.None, s.Feed("We do not have time for this, boy."));
    }

    [Fact]
    public void TwoEmptyFramesClearAfterSend()
    {
        var s = new SubtitleStabilizer();
        s.Feed("Hello there"); s.Feed("Hello there");
        Assert.Equal(StabilizerAction.None, s.Feed(""));
        Assert.Equal(StabilizerAction.Clear, s.Feed(""));
    }

    /// Yavaş kaynakta (saniyede ~3 kare) altyazı kalkınca TV'deki çeviri 6 kare (2 sn) beklemeden kalkmalı.
    [Fact]
    public void SlowSourceClearsAfterEmptyTime()
    {
        long time = 0;
        var s = new SubtitleStabilizer(emptyFramesToClear: 6, emptyTimeToClear: TimeSpan.FromMilliseconds(300), clock: () => time);
        s.Feed("Hello there.");
        time += 333;
        Assert.Equal(StabilizerAction.None, s.Feed(""));
        time += 333;
        Assert.Equal(StabilizerAction.Clear, s.Feed(""));
        time += 333;
        Assert.Equal(StabilizerAction.None, s.Feed(""));
    }

    /// Hızlı kaynakta süre kuralı tek hatalı okumayla silmez; kare sayısı kuralı aynen çalışır.
    [Fact]
    public void FastSourceStillNeedsEmptyFrames()
    {
        long time = 0;
        var s = new SubtitleStabilizer(emptyFramesToClear: 6, emptyTimeToClear: TimeSpan.FromMilliseconds(300), clock: () => time);
        s.Feed("Hello there.");
        for (var i = 0; i < 5; i++)
        {
            time += 50;
            Assert.Equal(StabilizerAction.None, s.Feed(""));
        }
        time += 50;
        Assert.Equal(StabilizerAction.Clear, s.Feed(""));
    }

    /// Süre geçse bile tek boş kare (ör. bir karelik hatalı okuma) altyazıyı silmez.
    [Fact]
    public void SingleEmptyFrameNeverClearsByTime()
    {
        long time = 0;
        var s = new SubtitleStabilizer(emptyFramesToClear: 6, emptyTimeToClear: TimeSpan.FromMilliseconds(300), clock: () => time);
        s.Feed("Hello there.");
        time += 1000;
        Assert.Equal(StabilizerAction.None, s.Feed(""));
        time += 100;
        Assert.Equal(StabilizerAction.None, s.Feed("Hello there."));
    }

    /// Önceden çeviren çevirmenle: bozuk ilk kare tek başına gönderilmez; doğrulanan satır ilk okunan hâliyle gider
    /// (çevirisi o metinle başlatılmıştı).
    [Fact]
    public void GarbledFirstReadingIsConfirmedThenSentAsFirstRead()
    {
        var s = new SubtitleStabilizer(cleanFastPathOnly: true);
        Assert.Equal(StabilizerAction.None, s.Feed("xa Oh, I know exactly who gave you your orders."));
        Assert.Equal(StabilizerAction.Translate("xa Oh, I know exactly who gave you your orders."), s.Feed("Oh, I know exactly who gave you your orders."));
        Assert.Equal(StabilizerAction.None, s.Feed("Oh, I know exactly who gave you your orders."));
    }

    [Fact]
    public void SingleGarbledFrameIsNeverSentButCleanLineGoesAtOnce()
    {
        var s = new SubtitleStabilizer(cleanFastPathOnly: true);
        Assert.Equal(StabilizerAction.None, s.Feed("f fe & ie want it."));
        Assert.Equal(StabilizerAction.Translate("In fact, sir, now you can do me a favor..."), s.Feed("In fact, sir, now you can do me a favor..."));
    }

    /// Bir kez görünüp kalkan kısa satır da gösterilmeli (yalnız iki kare doğrulaması bunu hiç göstermiyordu).
    [Fact]
    public void CleanLineSeenOnceIsSent()
    {
        var s = new SubtitleStabilizer(cleanFastPathOnly: true);
        Assert.Equal(StabilizerAction.Translate("you boys... how'd you boys like a couple of bucks?"), s.Feed("you boys... how'd you boys like a couple of bucks?"));
    }

    [Theory]
    [InlineData("Peter: I did it.", true)]
    [InlineData("Spider-Man: First cover!", true)]
    [InlineData("Head over to the tavern run by Mr. Gray...", true)]
    [InlineData("f fe & ie want it.", false)]
    [InlineData("A _ there's an extra ten bucks if you do.", false)]
    [InlineData("4 Pr and give the stuff out for free.", false)]
    [InlineData("Spider-Man **: can't believe you have this!", false)]
    public void CleanReadingsAreRecognised(string raw, bool clean) => Assert.Equal(clean, SubtitleStabilizer.LooksClean(raw));

    [Fact]
    public void AlreadyTranslatedIsSkipped()
    {
        var s = new SubtitleStabilizer();
        Assert.False(s.ShouldSend("Kullanıcı Ekle Oturum Açtı", "Kullanıcı Ekle Oturum Açtı"));
        Assert.True(s.ShouldSend("Add user", "Kullanıcı ekle"));
    }

    [Fact]
    public void ResetClearsOnlyAfterSomethingWasSent()
    {
        var s = new SubtitleStabilizer();
        Assert.Equal(StabilizerAction.None, s.Reset());
        s.Feed("Hello there"); s.Feed("Hello there");
        Assert.Equal(StabilizerAction.Clear, s.Reset());
        Assert.Equal(StabilizerAction.None, s.Reset());
    }

    /// Çevirisi başarısız olan satır ekranda kaldıkça yeniden denenebilmeli.
    [Fact]
    public void ForgottenLineIsTranslatedAgain()
    {
        var s = new SubtitleStabilizer();
        s.Feed("Hold the gate");
        Assert.Equal(StabilizerAction.Translate("Hold the gate"), s.Feed("Hold the gate"));
        s.ForgetSent();
        Assert.Equal(StabilizerAction.None, s.Feed("Hold the gate"));
        Assert.Equal(StabilizerAction.Translate("Hold the gate"), s.Feed("Hold the gate"));
    }
}
