# Mac paketini CI'da imzalama ve onaylatma

`release.yml` bir `v*` etiketinde Mac paketini GitHub Actions'ta imzalar, Apple'a onaylatır (notarization), zımbalar
(stapler), DMG'yi ve Sparkle `appcast.xml`'ini üretir. Bütün sürüm dosyaları `SHA256SUMS.txt`'ye girer ve her birine
derleme kanıtı (build provenance) eklenir. İmza `scripts/release-mac.sh` ile aynıdır: `scripts/package-mac.sh`,
sıkılaştırılmış çalışma (hardened runtime), zaman damgası ve `mac/CouchSubs/CouchSubs.entitlements` kullanır.

Altı sırdan biri bile eksikse Mac işi uyarı verir ve paketi imzasız çıkarır. Bu durumda sürüm eskisi gibi hemen
"en son sürüm" olur, imzalı ZIP, DMG ve appcast'i `scripts/release-mac.sh` ile elle yüklemek gerekir. Altısı da
tanımlıysa sürüm önce taslak açılır, bütün dosyalar (Mac dahil) yüklenip denetlenince yayınlanır ve "en son sürüm"
yapılır.

| Sır | İçerik |
| --- | --- |
| `MACOS_CERT_P12` | Developer ID Application kimliği (sertifika ve özel anahtar), `.p12`, base64 |
| `MACOS_CERT_PASSWORD` | `.p12` dosyasının parolası |
| `ASC_KEY_ID` | App Store Connect API anahtarının kimliği (Key ID) |
| `ASC_ISSUER_ID` | App Store Connect Issuer ID |
| `ASC_KEY_P8` | API anahtarı dosyasının (`AuthKey_<KEY_ID>.p8`) içeriği |
| `SPARKLE_ED_PRIVATE_KEY` | Sparkle güncelleme imzası için ed25519 özel anahtarı (PEM) |

## Hazırlık (kendi Mac'inizde)

Komutlar değerleri ekrana yazdırmaz. Parolayı `read -rs` ile girin: kabuk geçmişine düşmez.

1. Kimliği bulun (yalnız adını görmek için):

   ```sh
   security find-identity -v -p codesigning
   ```

   Listede `Developer ID Application: … (79N3CT6T46)` olmalı.

2. Kimliği `.p12` olarak dışa aktarın. En temizi Anahtar Zinciri Erişimi: Oturum › Sertifikalarım ›
   `Developer ID Application: …` › sağ tık › Dışa Aktar › `/tmp/cs.p12`, bir parola verin. Yalnız bu kimlik çıkar.
   Komut satırından da olur, ama bu komut oturum anahtar zincirindeki **bütün** kimlikleri dosyaya koyar:

   ```sh
   read -rs P12_PW
   security export -k ~/Library/Keychains/login.keychain-db -t identities -f pkcs12 -o /tmp/cs.p12 -P "$P12_PW"
   ```

3. Sertifika sırları:

   ```sh
   base64 -i /tmp/cs.p12 | gh secret set MACOS_CERT_P12 -R yorulmazsinan/couchsubs
   printf '%s' "$P12_PW" | gh secret set MACOS_CERT_PASSWORD -R yorulmazsinan/couchsubs
   rm -f /tmp/cs.p12; unset P12_PW
   ```

   (Anahtar Zinciri Erişimi'yle aktardıysanız önce `read -rs P12_PW` ile aynı parolayı girin.)

4. App Store Connect API anahtarı (notarytool; anahtar en az Developer rolünde olmalı). Değerler
   `~/.config/couchsubs/asc.env`'dekilerle aynıdır:

   ```sh
   source ~/.config/couchsubs/asc.env
   printf '%s' "$ASC_KEY_ID" | gh secret set ASC_KEY_ID -R yorulmazsinan/couchsubs
   printf '%s' "$ASC_ISSUER_ID" | gh secret set ASC_ISSUER_ID -R yorulmazsinan/couchsubs
   gh secret set ASC_KEY_P8 -R yorulmazsinan/couchsubs < "$ASC_KEY_PATH"
   ```

5. Sparkle anahtarı (uygulamadaki `SUPublicEDKey` ile eşleşmezse CI durur):

   ```sh
   gh secret set SPARKLE_ED_PRIVATE_KEY -R yorulmazsinan/couchsubs \
     < "$HOME/Library/Application Support/CouchSubs-release/sparkle-ed25519.pem"
   ```

6. Denetim (yalnız adlar listelenir):

   ```sh
   gh secret list -R yorulmazsinan/couchsubs
   ```

Sırlar tanımlandıktan sonraki ilk etikette `release-mac.sh` çalıştırmaya gerek kalmaz. Mac işinin günlüğünde
"Mac paketi CI'da imzalanıp Apple'a onaylatılacak." yazmalı.

## Derleme kanıtını doğrulama

```sh
gh release download v0.1.0-beta.60 -R yorulmazsinan/couchsubs -p CouchSubs-macos.dmg
gh attestation verify CouchSubs-macos.dmg -R yorulmazsinan/couchsubs
```
