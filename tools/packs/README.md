# Oyun paketi yapım araçları

Marvel's Spider-Man 2 ve Death Stranding Director's Cut paketleri bu betiklerle yapıldı (2026-11-12).
Akış: `extract.py` (herkese açık kaynaktan İngilizce satırlar) → `poolfix.py` (ortak havuzdaki OCR satırlarını
düzeltme) → `translate.py` (Claude ile cümle cümle çeviri) → `review.py` ve `fixcase.py` (denetim) → `build.py`
(biçim 2 paket: SHA-256 anahtarlar, parçalar, bulanık imzalar) → `coverage.py` (havuz satırlarıyla kapsam ölçümü).

Anthropic anahtarı `~/.config/couchsubs/anthropic-key` dosyasından okunur; depoya konmaz. Harcama `ledger.jsonl`'a
yazılır. Kaynaklar ve lisansları THIRD-PARTY-NOTICES.md'de.
