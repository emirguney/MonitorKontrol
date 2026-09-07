# AI Usage Side-Notch MVP Planı

Durum: Planlandı, henüz uygulanmadı  
Çalışma adı: `SideQuota`  
Hedef: Ayrı bir macOS uygulaması ve ayrı bir Git deposu  
Önerilen yürütme modeli: `gpt-5.6-terra`, reasoning `high`

## 1. Amaç

Claude Code ve OpenAI Codex abonelik limitlerini Mac ekranının sağ kenarında, dikkat dağıtmayan mini-notch arayüzünde gösterecek yerel bir macOS uygulaması geliştirilecek.

Uygulama şu temel ilkelere uyacak:

- Yerel ve salt-okunur çalışacak.
- Claude/Codex hook'ları kurmayacak ve mevcut ayar dosyalarını değiştirmeyecek.
- Telemetri, analitik, crash-reporting veya üçüncü taraf proxy kullanmayacak.
- Kimlik bilgilerini başka bir dosyaya veya uygulama Keychain girdisine kopyalamayacak.
- Her sağlayıcı ayrı bir modül olacak; biri bozulduğunda diğeri çalışmaya devam edecek.
- Başarısız veya eski veriyi güncelmiş gibi göstermeyecek.
- MVP yalnızca kota yüzdeleri, sıfırlanma zamanı ve veri tazeliğine odaklanacak.

## 2. Ürün kapsamı

### MVP dahil

- Sağ ekran kenarında ince, her zaman erişilebilir mini-notch.
- Hover veya tıklama ile genişleyen panel.
- Claude ve Codex için:
  - 5 saatlik kullanım yüzdesi,
  - haftalık kullanım yüzdesi,
  - varsa model bazlı haftalık limit,
  - sıfırlanma zamanı,
  - son başarılı güncelleme zamanı.
- Kullanıldı/kaldı görünümü.
- Manuel yenileme.
- Varsayılan 5 dakikalık otomatik yenileme.
- Sağlayıcı bazında bağlantı, yetkilendirme, eski veri ve hata durumları.
- Açılışta çalıştırma seçeneği.
- Dahili ekran, harici ekran ve çoklu ekran seçimi.
- macOS 14+; macOS 26/Tahoe üzerinde özel performans kontrolü.
- Universal binary: Apple Silicon ve Intel.
- Türkçe ve İngilizce arayüz.

### MVP dışı

- Gemini, Cursor, OpenRouter veya başka sağlayıcılar.
- Token maliyet hesabı ve geçmiş grafikleri.
- Prompt, konuşma veya proje içeriği okuma.
- Ajan çalışma durumu, izin onaylama veya terminale geri dönme.
- Claude/Codex hook kurulumu.
- Çoklu hesap ve hesap değiştirme.
- Otomatik token yenileme veya `auth.json` yazma.
- Kendi sunucumuz, kullanıcı hesabı veya bulut senkronizasyonu.
- Otomatik güncelleme sistemi; ilk sürümden sonra değerlendirilecek.
- Mac App Store dağıtımı.

## 3. Görsel ve etkileşim tasarımı

Hivinz'in sağ kenar konsepti yalnızca ilham kaynağıdır. Tasarım dosyaları, görseller veya birebir piksel kopyası kullanılmayacak; özgün bir uygulama kimliği oluşturulacak.

### Dar durum

- Ekranın sağ kenarında 8-12 pt görünen bir sekme.
- Görünmeyen hit-area en az 28 pt olacak.
- En kritik sağlayıcının küçük halka göstergesi veya iki ince durum noktası gösterilecek.
- Panel klavye odağını veya aktif uygulamayı çalmayacak.

### Geniş durum

- Yaklaşık 240-280 pt genişlik.
- Claude ve Codex kartları aynı anda görülebilecek.
- Her kartta sağlayıcı adı, 5 saatlik ve haftalık bar, sıfırlanma zamanı bulunacak.
- Alt bölümde `Az önce güncellendi`, `12 dk önce`, `Veri eski` veya hata mesajı gösterilecek.
- Yenile ve Ayarlar düğmeleri olacak.

### Açılma/kapanma kuralları

- Hover sonrası 100-150 ms içinde açılacak.
- İmleç panelden ayrıldıktan 700-1.000 ms sonra kapanacak.
- Tıklama paneli sabitleyebilecek; dışarı tıklama veya Escape kapatacak.
- Kullanıcı çalışırken panel kendiliğinden açılmayacak.
- Tam ekran uygulamada varsayılan olarak yalnızca ince tetikleyici kalacak; ayarlardan tamamen gizlenebilecek.
- Animasyonlar 60 FPS hedefleyecek ve `Reduce Motion` ayarına uyacak.

## 4. Teknik mimari

### Uygulama kabuğu

- Swift 6 / SwiftUI + AppKit.
- `LSUIElement=true`; Dock ikonu olmayacak.
- Kenar paneli için borderless, non-activating `NSPanel` kullanılacak.
- Panel konumu `NSScreen.visibleFrame` ve ekran kimliği üzerinden hesaplanacak.
- Swift Package Manager ile mümkün olduğunca bağımlılıksız yapı.
- Kaynak düzeni:

```text
SideQuota/
  Package.swift
  Sources/SideQuota/
    App/
    Core/
    Providers/
      Claude/
      Codex/
    UI/
      Panel/
      Components/
      Settings/
    Security/
    Resources/
  Tests/SideQuotaTests/
    Fixtures/
  scripts/
    build.sh
    verify.sh
  docs/
    architecture.md
    privacy.md
    release.md
```

### Sağlayıcı sözleşmesi

Tek bir sağlayıcının endpoint veya JSON biçimi değiştiğinde UI ve diğer sağlayıcı etkilenmemeli.

```swift
protocol UsageProvider: Sendable {
    var id: ProviderID { get }
    func availability() async -> ProviderAvailability
    func fetchUsage() async -> ProviderResult
}
```

Temel modeller:

- `ProviderID`: `claude`, `codex`
- `UsageWindow`: tür, kullanılan yüzde, sıfırlanma zamanı, isteğe bağlı model etiketi
- `UsageSnapshot`: pencereler, alınma zamanı, kaynak türü
- `ProviderAvailability`: hazır, kimlik bilgisi yok, süresi dolmuş, desteklenmiyor
- `ProviderResult`: başarı veya kullanıcıya gösterilebilir sınıflandırılmış hata
- `Freshness`: güncel, eski, hiç veri yok

UI sağlayıcının ham JSON'unu veya credential biçimini bilmeyecek.

### Veri akışı

```text
CredentialReader (salt-okunur)
        -> UsageProvider
        -> normalize edilmiş UsageSnapshot
        -> UsageStore (yalnız bellekte son değer)
        -> Side-notch UI
```

Başarılı son snapshot uygulama çalışırken bellekte tutulabilir. MVP'de kota snapshot'ı diske yazılmayacak; uygulama yeniden açıldığında yeniden alınacak.

## 5. Sağlayıcı uygulaması

### Codex

- `~/.codex/auth.json` yalnızca okunacak.
- Dosyanın tamamı loglanmayacak veya başka yere kopyalanmayacak.
- Access token yalnızca istek süresince bellekte tutulacak.
- Uygulama refresh token kullanmayacak ve dosyaya geri yazmayacak.
- Birincil veri kaynağı ayrı bir `CodexUsageProvider` içinde kapsüllenecek.
- Belgelenmemiş kullanım endpoint'i değişirse yalnızca bu provider ve parser değiştirilecek.
- Parser; eksik alan, yeni alan, `null`, yüzde sınır dışı değer ve farklı reset biçimlerini güvenli ele alacak.

### Claude

- Öncelik sırası:
  1. Kullanıcı ortamında desteklenen Claude credential dosyası, salt-okunur.
  2. macOS Keychain `Claude Code-credentials`, salt-okunur.
- Keychain erişimi otomatik arka plan sürprizi olarak değil, kullanıcı Claude'u etkinleştirdiğinde açıklamalı şekilde istenecek.
- Access token kopyalanmayacak, kalıcılaştırılmayacak ve yenilenmeyecek.
- Claude usage endpoint'i ve parser ayrı bir `ClaudeUsageProvider` içinde kalacak.

### Ağ sınırı

- `URLSessionConfiguration.ephemeral` kullanılacak.
- Cookie, URL cache ve credential persistence kapalı olacak.
- İstekler yalnızca provider içinde tanımlı HTTPS hostlarına gidecek.
- Redirect sonrası host allowlist tekrar doğrulanacak; başka hosta Authorization header taşınmayacak.
- User-Agent uygulama adı/sürümüyle sınırlı olacak; cihaz veya kullanıcı kimliği içermeyecek.
- Hata loglarında URL query, header, response body veya token bulunmayacak.

### Belgelenmemiş endpoint gerçeği

Claude ve ChatGPT abonelik kullanım endpoint'leri değişebilir. Bu nedenle:

- Sağlayıcı durumu `temporarilyUnsupported` olabilmeli.
- UI `Servis biçimi değişmiş olabilir` mesajı göstermeli.
- Eski başarılı veri varsa yüzde gösterilmeye devam edilebilir ama belirgin `Veri eski` rozeti zorunlu olmalı.
- Parser fixture'ları endpoint cevap biçiminin sözleşme testi olacak.

## 6. Yenileme ve tazelik modeli

- Uygulama açılışında tek yenileme.
- Varsayılan periyot: 5 dakika.
- Ayarlar: 5, 15 ve 30 dakika.
- Manuel yenileme aynı anda ikinci istek başlatmayacak.
- Sağlayıcılar paralel yenilenecek; sonuçlar bağımsız yayınlanacak.
- Hata sonrası backoff: 5 -> 10 -> 20 -> 30 dakika; manuel yenileme her zaman mümkün.
- Uyku sonrası ağ hazır olduğunda tek yenileme.
- Arka arkaya timer birikmesi olmayacak; tek `Task`/scheduler sahibi olacak.

Tazelik eşikleri:

- `fresh`: son başarılı veri, seçili yenileme aralığının iki katından genç.
- `stale`: eşik aşılmış fakat elde önceki veri var.
- `unavailable`: hiç başarılı veri yok.

## 7. Güvenlik ve gizlilik kapıları

Bu maddelerden biri sağlanmadan MVP tamamlanmış sayılmaz:

- Credential dosyalarına yazma yapan kod bulunmamalı.
- Token, e-posta, kullanıcı ID'si ve ham response loglanmamalı.
- Token için ayrı dosya, UserDefaults veya uygulamaya ait Keychain kaydı oluşturulmamalı.
- Hook, shell profile, Claude ayarı veya Codex ayarı değiştirilmemeli.
- Telemetri SDK'sı ve üçüncü taraf ağ bağımlılığı bulunmamalı.
- Network host allowlist testlerle doğrulanmalı.
- Redirect ile Authorization sızıntısı engellenmeli ve test edilmeli.
- Uygulama kapandığında devam eden istekler iptal edilmeli.
- Gizlilik belgesi hangi dosyaların okunduğunu ve hangi hostlara bağlanıldığını açıkça listelemeli.

## 8. Uygulama fazları

### Faz 0 — Ayrı repo ve iskelet

Öncelik: P0  
Bağımlılık: Yok

İşler:

- Yeni, ayrı repo oluştur: önerilen ad `SideQuota`.
- Swift package/app iskeleti, test target'ı ve kaynak klasörlerini kur.
- AppKit `NSPanel` spike'ı ile sağ kenar yerleşimini doğrula.
- `build.sh` ve `verify.sh` oluştur.
- Lisans ve ilham/atıf notlarını ekle.

Kabul:

- Uygulama Dock ikonu olmadan açılır.
- Sağ kenardaki panel ana ve harici ekranda konumlanır.
- Build, plist lint ve codesign doğrulaması geçer.

### Faz 1 — Provider core ve fixture testleri

Öncelik: P0  
Bağımlılık: Faz 0

İşler:

- Ortak provider sözleşmesi ve hata modeli.
- Codex/Claude credential reader'ları.
- Provider parser'ları.
- Sahte cevap fixture'ları: başarılı, eksik alan, 401, 403, 429, 500, bozuk JSON, yeni bilinmeyen alan.
- Token redaction ve redirect-host testleri.

Kabul:

- Tüm provider testleri internet olmadan geçer.
- Testler gerçek credential veya canlı endpoint kullanmaz.
- Bir provider başarısızken diğeri snapshot üretebilir.
- Credential dosyalarının checksum/mtime değerleri test öncesi ve sonrası değişmez.

### Faz 2 — Mini-notch UI

Öncelik: P0  
Bağımlılık: Faz 1 modelleri

İşler:

- Dar ve geniş panel durumları.
- Hover/tıklama/pin/Escape davranışı.
- Provider kartları, progress bar ve reset zamanı.
- Loading, auth gerekli, hata ve stale tasarımları.
- Türkçe/İngilizce kaynaklar.
- Reduce Motion ve VoiceOver etiketleri.

Kabul:

- Panel aktif uygulamanın odağını çalmaz.
- Dar/geniş geçişte titreme ve pencere zıplaması görülmez.
- Eski veri güncel veriyle görsel olarak karışmaz.
- Notch'lu/notch'suz ekran ve açık/koyu tema ekran görüntüleri alınır.

### Faz 3 — Lifecycle, ekran ve performans

Öncelik: P0  
Bağımlılık: Faz 2

İşler:

- Tek scheduler, backoff ve manuel yenileme.
- Sleep/wake ve network geri dönüş davranışı.
- Ekran seçimi, ekran takma/çıkarma, çözünürlük değişimi.
- Tam ekran ve Focus Mode davranışı.
- Launch at Login.

Kabul:

- Beklemede hot loop veya saniyelik gereksiz polling yok.
- 10 dakikalık idle ölçümde ortalama CPU <%1 hedefi.
- Bellek kararlı; her refresh'te büyüme görülmez.
- Ekran değişince görünmez veya erişilemez panel oluşmaz.
- Aynı anda en fazla bir provider isteği/provider çalışır.

### Faz 4 — Güvenlik, paketleme ve MVP teslimi

Öncelik: P0  
Bağımlılık: Faz 0-3

İşler:

- Kaynakta ağ hedefi, credential yazımı ve log taraması.
- Privacy dokümanı.
- Universal Release build, ad-hoc sign ve ZIP/DMG.
- Temiz kullanıcı ortamında smoke test.
- README kurulum/kaldırma adımları.

Kabul:

- Unit testlerin tamamı geçer.
- `plutil -lint`, `codesign --verify --deep --strict` ve arşiv testi geçer.
- Uygulama Claude/Codex ayar dosyalarını değiştirmez.
- Ağ trafiğinde yalnız belgelenen provider hostları görülür.
- Paket temiz bir Mac kullanıcı hesabında açılır ve kaldırılabilir.
- Doğrulanmayan canlı davranış açıkça raporlanır; test geçti diye canlı endpoint başarısı iddia edilmez.

### Faz 5 — MVP sonrası, ayrı onay gerektirir

Öncelik: P1/P2

- Developer ID ile imzalama ve notarization.
- Sparkle güncellemesi ve imzalı appcast.
- Gemini/provider eklenti sistemi.
- Geçmiş grafikler; yalnız anonim yerel snapshot ve kullanıcı onayıyla.
- Tasarım özelleştirme ve ek panel konumları.

## 9. Test matrisi

| Alan | Senaryolar |
|---|---|
| Credential | Dosya yok, Keychain yok, geçerli, süresi dolmuş, bozuk JSON, izin reddi |
| API | 200, 401, 403, 429, 5xx, timeout, offline, redirect, şema değişimi |
| Tazelik | İlk yükleme, fresh, stale, manuel refresh, önceki veri + yeni hata |
| Ekran | Dahili notch, notch'suz harici, çoklu ekran, clamshell, çözünürlük değişimi |
| Pencere | Hover, pin, Escape, dışarı tıklama, tam ekran, Space değişimi |
| Erişilebilirlik | Reduce Motion, VoiceOver, yüksek kontrast, klavye ile kapatma |
| Lifecycle | Launch at Login, sleep/wake, ağ kaybı/dönüşü, uygulama kapanışı |
| Performans | 10 dk idle CPU, refresh sırasında CPU, bellek büyümesi, timer sayısı |

## 10. Referans kullanımı ve lisans sınırı

- Hivinz: ürün ve etkileşim fikri için görünür atıf.
- CodexBar: provider ayrıştırma, hata modeli ve test yaklaşımı için mimari referans.
- CodexIsland: notch pencere davranışı ve tazelik UX'i için referans.
- Brink: sağ kenar etkileşiminin karşılaştırmalı referansı.

Kod kopyalanacaksa kaynak lisans önce doğrulanacak, gerekli copyright/lisans metni korunacak ve dosya bazında atıf yapılacak. Tasarım varlıkları ve marka logoları lisans doğrulaması olmadan alınmayacak.

## 11. Model ve yürütme ayarı

Önerilen varsayılan:

- Model: `gpt-5.6-terra`
- Reasoning: `high`
- Çalışma biçimi: Tek görev, fazlar sırayla; her faz sonunda test ve kısa durum raporu.

Neden: Bu proje AppKit pencere yaşam döngüsü, credential güvenliği, ağ sınırları ve paketleme arasında dikkatli denge istiyor. Terra bu iş için yetenek/maliyet dengesini korur. Kritik son güvenlik ve release incelemesi için gerekirse ayrı bir `gpt-5.6-sol`, reasoning `high` görevi kullanılabilir. Luna yalnız küçük mekanik işler ve test eklemeleri için uygundur; ana mimari ve güvenlik uygulamasına verilmemelidir.

## 12. Uygulayıcı modele verilecek başlangıç talimatı

Aşağıdaki talimat yeni, ayrı proje görevine verilmelidir:

> Bu plandaki MVP'yi ayrı bir macOS uygulaması olarak uygula. MonitorKontrol reposunu değiştirme ve onun kodunu doğrudan kopyalama; yalnız doğrulanmış Swift/AppKit paketleme derslerini referans al. Önce yeni repo durumunu ve macOS/Swift toolchain'i incele, sonra Faz 0'dan başla. Faz atlama. Her fazın kabul kriterlerini gerçekleştirmeden sonraki faza geçme. Credential ve endpoint kodunda salt-okunur sınırı koru; hook, telemetri, token kopyası veya auth dosyasına yazma ekleme. Canlı credential/API çağrısı yapmadan önce fixture testlerini bitir. Ücretli ya da kota tüketebilecek doğrulama yapma. Mevcut kullanıcı dosyalarını ve ilgisiz değişiklikleri koru. Her faz sonunda değişen dosyaları, geçen testleri ve doğrulanamayan sınırları bildir. MVP tamamlandığında build edilebilir uygulama, kaynak kod, testler, privacy dokümanı ve paketlenmiş artifact teslim et.

## 13. Definition of Done

MVP yalnızca aşağıdakilerin tamamı sağlanınca biter:

- Ayrı repo ve bağımsız uygulama oluşmuştur.
- Claude ve Codex fixture testleri geçmektedir.
- İki provider gerçek kullanıcı oturumu bulunan test Mac'inde salt-okunur çalışmıştır veya canlı doğrulama yapılamadıysa bu sınır dürüstçe belgelenmiştir.
- Sağ kenar paneli dikkat dağıtmadan açılıp kapanmaktadır.
- Fresh/stale/unavailable durumları doğru görünmektedir.
- Credential kopyası, auth yazımı, hook ve telemetri yoktur.
- Idle CPU, bellek ve çoklu ekran kabul kriterleri doğrulanmıştır.
- Universal build, imza ve arşiv doğrulamaları geçmiştir.
- README, privacy ve release dokümanları tamamlanmıştır.
