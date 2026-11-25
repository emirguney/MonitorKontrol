# MonitorKontrol

Apple Silicon Mac'lerde dahili ekran parlaklığını ve harici monitörlerin DDC/CI kontrollerini macOS menü çubuğundan ve Dock'tan yöneten yerel uygulama.

## Özellikler

- Bağlı harici monitörleri otomatik bulur; birden fazla monitörü ayrı ayrı yönetir.
- MacBook'un dahili ekranını DDC monitörlerinden ayırır ve parlaklığını kendi ekran servisi üzerinden değiştirir.
- Harici monitörlerde desteklenen parlaklık, kontrast, ses ve sessize alma kontrollerini gösterir.
- Uygulama açılırken ve elle yenileme yapıldığında monitörün güncel DDC değerlerini okur.
- Uygun harici monitörlerde parlaklık değişimini kontrasta seçilebilir bir oranda uygular.
- DDC değerleri okunamayan bağlantılarda yazma odaklı HDMI uyumluluk moduna geçer.
- Monitör takma, çıkarma ve uykudan uyanma olaylarında ekran listesini otomatik yeniler.
- Otomatik yenilemede yalnızca ekran topolojisini tarayarak gereksiz DDC okumalarını ve menü çubuğu gecikmesini önler.
- Dock'ta normal bir uygulama olarak görünür; Dock simgesine tıklamak monitör kontrol penceresini açar ya da öne getirir.
- Menü çubuğu popover'ı ve kontrol penceresi aynı monitör durumunu paylaşır; pencere kapatılınca menü çubuğu simgesi ve medya tuşları çalışmaya devam eder.
- Tahoe'da kararlı görünüm ve düşük yük için klasik `NSStatusItem` ile animasyonsuz `NSPopover` kullanır.
- DDC motorunu uygulama içinde taşır; ayrıca Homebrew paketi kurulmasını gerektirmez.

> Monitor girişini değiştirme kontrolleri güncel sürümde yer almaz.

## Gereksinimler

- Apple Silicon Mac
- macOS 26 (Tahoe) veya üzeri
- Harici monitörde etkinleştirilmiş DDC/CI desteği
- DDC iletişimini iletebilen bir bağlantı yolu, adaptör ve kablo

## Derleme

```sh
chmod +x build.sh
./build.sh
```

Derleme betiği vendored `m1ddc` aracını, Swift uygulamasını ve Dock ikonunu (`scripts/generate-icon.swift`) derler, uygulamayı ad-hoc imzalar ve şu çıktıları üretir:

- `dist/MonitorKontrol.app`
- `dist/MonitorKontrol.zip`

## Kullanım

1. Harici monitörü Mac'e bağla.
2. Monitörün fiziksel menüsünden **DDC/CI** özelliğini aç.
3. `MonitorKontrol.app` uygulamasını Finder'dan aç. İlk açılışta kontrol penceresi görünür.
4. Kontrollere Dock simgesinden ya da menü çubuğundaki ekran simgesinden eriş.
5. İlgili monitörü açarak parlaklık, kontrast, ses veya sessiz ayarını değiştir.

Kontrol penceresini kapatmak uygulamayı kapatmaz; menü çubuğu simgesi ve medya tuşu yönlendirmesi çalışmaya devam eder. Uygulamadan tamamen çıkmak için `⌘Q` ya da paneldeki **Çık** düğmesini kullan.

## Dock'a sabitleme

Dock, sabitlenen uygulamayı dosya konumuyla hatırlar. `dist/` her derlemede yeniden oluşturulduğu için uygulamayı önce sabit bir konuma kopyala:

```sh
ditto dist/MonitorKontrol.app /Applications/MonitorKontrol.app
open /Applications/MonitorKontrol.app
```

1. Uygulama çalışırken Dock'taki MonitorKontrol simgesine sağ tıkla.
2. **Seçenekler → Dock'ta Tut**'u seç.
3. Artık Dock simgesine tıklamak uygulamayı başlatır; uygulama çalışıyorsa kontrol penceresini öne getirir.

Yeni bir sürüm derlediğinde aynı `ditto` komutuyla `/Applications` içindeki kopyayı güncelle. Ad-hoc imza her derlemede değiştiği için medya tuşları için verilen Erişilebilirlik iznini yeniden onaylaman gerekebilir.

Sağ üstteki yenileme düğmesi ekranları tekrar tarar ve okunabilen gerçek DDC değerlerini yeniden yükler. Harici monitör kontrolleri ilk bulunduğunda açık, dahili ekran bölümü ise kapalı gösterilir.

## Parlaklık ve kontrastı birlikte ayarlama

Gerçek parlaklık ve kontrast değerleri okunabilen harici monitörlerde **Parlaklıkla kontrastı birlikte ayarla** seçeneği görünür.

- Özellik isteğe bağlıdır ve ilk açılışta kapalıdır.
- **Kontrast etkisi** alanı `0–100` arasında ayarlanabilir; varsayılan değer `%50`'dir.
- Oran, parlaklıktaki değişimin monitörün kontrast aralığına ne kadar yansıtılacağını belirler. `%0` kontrastı değiştirmez, `%100` aynı oransal değişimi uygular.
- Bağlı modda kontrast sürgüsü gizlenir; kontrast başlığı ve güncel değeri görünür kalır.
- Önce parlaklık, ardından kontrast yazılır. Kontrast yazımı başarısız olursa parlaklığın uygulanmış olabileceği arayüzde açıkça bildirilir.

Bu seçenek, değerlerin okunamadığı yazma odaklı HDMI uyumluluk modunda gösterilmez.

## Donanım ve uyumluluk notları

- Uygulama Apple Silicon Mac içindir ve macOS 26 (Tahoe) veya üzerini ister.
- Görüntünün HDMI üzerinden gelmesi, aynı yolun DDC/CI komutlarını da taşıdığını garanti etmez. Sonuç Mac modeline, bağlantı köprüsüne, adaptöre, kabloya ve monitöre göre değişir.
- `MacBookPro18,3` modelindeki dahili HDMI hattı için MCDP29xx DDC köprüsü ve köprüye özel `0xB7` adresi desteklenir; bu destek tüm HDMI donanımları için genel bir garanti değildir.
- DDC kontrollerinden biri okunamazsa uygulama yazma odaklı uyumluluk moduna geçer. Bu moddaki `50` değerleri monitörden okunmuş değerler değil, güvenli başlangıç konumlarıdır; sürgü bırakıldığında seçilen değer monitöre gönderilir.
- Dahili ekran harici DDC yolu üzerinden kontrol edilmez ve hiçbir zaman HDMI monitörü olarak sınıflandırılmaz.
- Otomatik ekran olayları mevcut değerleri koruyarak yalnızca bağlı ekran listesini günceller. Tam DDC okuması uygulama başlangıcında ve yenileme düğmesiyle yapılır.

## Kaynak ve lisans

DDC taşıma katmanında MIT lisanslı [waydabber/m1ddc](https://github.com/waydabber/m1ddc) kullanılır. Lisans metni `Vendor/m1ddc/LICENSE` içinde korunur ve derlenen uygulamanın kaynaklarına eklenir.
