# Uygulamayla gelen oyun paketleri

Paket dosyaları (`*.json.gz`) depoda değildir; yalnız uygulama içinden dağıtılır. Yayın derlemesi onları özel R2
kovasından (`couchsubs-packs`, `bundled/` öneki) bu klasöre indirir:

```sh
python3 scripts/fetch-packs.py            # erişim: PACKS_R2_* (CI sırları) ya da ~/.config/couchsubs/packs.env
```

Mac/iPhone (Swift paketi kaynağı), Windows (gömülü kaynak) ve Android (assets) buradan okur. Klasör boşsa uygulama
paketsiz derlenir; gerçek paketlere dayanan testler kendini atlar. Ayrıntı: server/packs/README.md.
