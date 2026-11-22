# Topluluk katkı havuzu

GTA Türkçe topluluk havuzu (`gta-tr-havuz-katki.json.gz`) ve notu (`GTA_HAVUZ_KATKI.md`) depoda değildir; özel R2
kovasında (`couchsubs-packs`, `contrib/` öneki) durur. Paket betikleri için bu klasöre indirmek:

```sh
python3 scripts/fetch-packs.py --contrib  # erişim: PACKS_R2_* ya da ~/.config/couchsubs/packs.env
```

Güncelleme göndermek isteyen katkıcılar dosyayı PR'a eklemesin; depo sahibiyle iletişime geçsin.
