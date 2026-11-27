# MB130 DevProfile: test aracı soketini (TCP 1986) açma ve kapatma

Tek tuşla kurulumun ön koşulu. Yalnız Vestel MB130 anakartında (55UD8400, yazılım 3.62.25.1) denendi.

| Dosya | Ne |
|---|---|
| `mb130_devprofile.bin` | USB'ye konacak derlenmiş profil: `TesttoolSocket=True` (soketi açar). |
| `mb130_testtool_enable.xml` | Bu `.bin`'in kaynağı (ProfileComposer projesi). |
| `mb130_testtool_disable.xml` | Kapatma profili kaynağı: `TesttoolSocket=False`. |

Profiller Vestel'in ProfileComposer aracıyla (Windows) derleniyor. Araç bu depoda yok. Kapatma profilinin derlenmiş
`.bin`'i de yok, gerekirse XML'den ProfileComposer ile derlenmeli. Çıktının adı yine `mb130_devprofile.bin` olur.

## Açma

1. `mb130_devprofile.bin` dosyasını FAT32 bir USB belleğe kopyalayın: hem kök dizine hem de `profile/` klasörüne
   (`/mb130_devprofile.bin` ve `/profile/mb130_devprofile.bin`). Denediğimiz bellekte iki konumda da vardı; TV'nin
   hangisini okuduğunu ayırmadık.
2. Belleği TV'ye takın. TV menüsü açıkken kumandada **4725** tuşlayın (servis menüsü) ve **USB Diagnostic**'i çalıştırın.
3. TV'yi kapatın, yaklaşık 1 dakika sonra açın. TCP 1986 açılır: `nc -vz <TV_IP> 1986`.

## Kapatma

`mb130_testtool_disable.xml`'i ProfileComposer ile derleyip aynı adımları uygulayın. Kapatma yolu bu TV'de denenmedi.

**Güvenlik:** 1986 soketi kimlik doğrulamasız ve gelen komutu root olarak çalıştırıyor. Profil etkin kaldıkça yerel
ağdaki herkes TV'de komut çalıştırabilir. Yalnız güvendiğiniz ağda açık tutun.
