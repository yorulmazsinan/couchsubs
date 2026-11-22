// SPDX-License-Identifier: AGPL-3.0-only

using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;

namespace CouchSubs.App.Views.Steps;

/// <summary>Kurulum metinlerinde Mac'teki Markdown kalın (**ana**) vurgusu: vurgu büyük harf değil kalın yazıdır.</summary>
public static class StepText
{
    public static TextBlock Rich(string text)
    {
        var block = new TextBlock { TextWrapping = TextWrapping.Wrap, LineStackingStrategy = LineStackingStrategy.BlockLineHeight, LineHeight = 19 };
        block.SetResourceReference(TextBlock.FontSizeProperty, "smallFontSize");
        block.SetResourceReference(TextBlock.ForegroundProperty, "textBrush");
        var parts = text.Split("**");
        for (var i = 0; i < parts.Length; i++)
        {
            if (parts[i].Length == 0) continue;
            var run = new Run(parts[i]);
            if (i % 2 == 1) run.FontWeight = FontWeights.SemiBold;
            block.Inlines.Add(run);
        }
        return block;
    }
}
