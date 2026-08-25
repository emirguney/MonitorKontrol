# MonitorKontrol

macOS menü çubuğundan harici monitörün DDC/CI kontrollerini yöneten yerel uygulama.

## İlk sürümde

- Bağlı harici monitörleri otomatik bulur.
- MacBook'un dahili ekranını ayrı gösterir; bölümü varsayılan olarak kapalıdır ve parlaklık kontrolü sunar.
- Dahili ekran hiçbir zaman HDMI/DDC monitörü olarak sınıflandırılmaz.
- Her monitörde parlaklık, kontrast, ses, sessize alma ve giriş VCP kodlarını ayrı ayrı dener.
- Yalnızca okunabilen/desteklenen kontrolleri gösterir.
- HDMI üzerinden değer okuma başarısızsa yazma-odaklı uyumluluk moduna geçer; temel kontroller görünür kalır.
- Standart giriş kodlarının yanında LG monitörlerin alternatif giriş kodlarını da destekler.
- Birden fazla monitör arasında seçim yapılabilir.
- HDMI monitör takıldığında, çıkarıldığında veya Mac uykudan uyandığında liste otomatik yenilenir.
- Menüdeki yenileme düğmesi manuel tekrar tarama için ayrıca korunur.
- DDC motoru uygulamanın içine gömülür; ayrıca Homebrew paketi gerekmez.

## Derleme

```sh
chmod +x build.sh
./build.sh
```

Derlenen uygulama `dist/MonitorKontrol.app`, paylaşılabilir paket ise `dist/MonitorKontrol.zip` altında oluşur.

## Kullanım

1. Harici monitörü MacBook'un dahili HDMI portuna bağla.
2. Monitörün fiziksel menüsünden **DDC/CI** özelliğini aç.
3. `MonitorKontrol.app` uygulamasını çalıştır.
4. Menü çubuğundaki ekran simgesinden kontrolleri aç.

## Donanım notları

- Uygulama Apple Silicon Mac içindir ve macOS 14 veya üzerini ister.
- MacBookPro18,3 modelindeki dahili HDMI hattı için MCDP29xx DDC köprüsü ve köprüye özel `0xB7` adresi desteklenir.
- DDC/CI desteği monitöre, kabloya ve monitörün kendi ayarlarına göre değişir.
- Geliştirme sırasında okunabilir DDC kontrolleri bildiren bir ekran olmadığı için gerçek donanıma yazma testi yapılmadı; desteksiz/okunamayan ekran durumu doğrulandı.
- HDMI uyumluluk modundaki `50` değerleri monitörden okunmuş değerler değil, sürgülerin güvenli başlangıç konumlarıdır. Sürgüyü bıraktığında seçtiğin değer monitöre gönderilir.

## Kaynak ve lisans

DDC taşıma katmanında MIT lisanslı [waydabber/m1ddc](https://github.com/waydabber/m1ddc) kullanılır. Lisans metni `Vendor/m1ddc/LICENSE` içinde korunmuştur.
