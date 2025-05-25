% Deprem Sismik Risk Analizi ve Erken Uyarı Sistemi
% Geliştiren: [Sismokod]
% Tarih: 24.04.2025
% Bu MATLAB betiği, Türkiye'deki sismik aktiviteyi izlemek, potansiyel risk
% senaryolarını değerlendirmek ve belirli koşullar altında erken uyarılar
% sağlamak için tasarlanmıştır. Program, Kandilli Rasathanesi'nden canlı
% deprem verilerini çeker, son 24 saatteki depremleri filtreler ve
% fay hatları ile birlikte görselleştirir. Akkar ve Çağnan (2010) gibi
% güncel sismik tehlike modellerine dayalı olarak deprem riskini tahmin
% eder ve mekansal kümelenmeyi analiz eder.
% Risk seviyeleri renk kodlamasıyla harita üzerinde gösterilirken,
% bölgeler bazında tahmini risk senaryoları sunulur. Ayrıca, bir makine
% öğrenimi (Karar Ağacı) modeli, deprem özelliklerine göre risk seviyesi
% sınıflandırması yapmak üzere entegre edilmiştir. Son olarak, Türkiye'nin
% kritik bölgeleri için tanımlanmış eşik değerlere göre bölgesel yüksek
% risk uyarı sistemi devreye girer ve Marmara Bölgesi'nde kritik bir durum
% tespit edildiğinde sesli ve e-posta bildirimi yapar.
% Bu araç, sismik risk değerlendirmesi ve afet hazırlığı konusunda hızlı
% ve bilgilendirici bir genel bakış sağlamayı amaçlamaktadır.
% Not: Kodu çalıştırmadan önce MATLAB ortamınızın internete bağlı olduğundan
% ve 'avrasya_fay_hatlari_koordinatlari.csv' dosyasının aynı dizinde
% bulunduğundan emin olun.

clear all; % Tüm çalışma alanı değişkenlerini temizle
close all; % Açık olan tüm şekil pencerelerini kapat
clc;       % Komut penceresini temizle

%% 1. Anlık Deprem Verilerini Kandilli Rasathanesi'nden Çekme
% Bu bölüm, Kandilli Rasathanesi ve Deprem Araştırma Enstitüsü'nün (KOERI)
% son 500 deprem listesini içeren web sayfasından güncel verileri alır.
% Web içeriğinin başarıyla çekilip çekilmediği kontrol edilir ve olası
% hatalar için kullanıcıya bilgi verilir.

url = 'http://www.koeri.boun.edu.tr/scripts/lst5.asp'; % KOERI'nin son depremler listesi URL'si

% Web sayfasının içeriğini güvenli bir şekilde oku
options = weboptions('Timeout', 15, 'CharacterEncoding', 'windows-1254'); % Zaman aşımı ve karakter kodlaması ayarları
try
    disp('Kandilli Rasathanesi''nden güncel deprem verileri çekiliyor...');
    web_content = webread(url, options); % Web sayfasının içeriğini oku
    disp('Deprem verileri başarıyla çekildi.');
catch ME % Herhangi bir hata durumunda
    warning('HATA: Web sayfasını okurken bir sorun oluştu: %s', ME.message);
    warning('Lütfen internet bağlantınızı ve sağlanan URL adresini (%s) kontrol edin.', url);
    return; % Hata durumunda betiği sonlandır
end

% HTML içeriğinden <pre> etiketleri arasındaki ham metni ayıkla.
% Deprem verileri genellikle bu etiketler arasında düzenlenmiş bir metin
% formatında sunulur.
start_idx = strfind(web_content, '<pre>'); % '<pre>' etiketinin başlangıç indeksi
end_idx = strfind(web_content, '</pre>');   % '</pre>' etiketinin bitiş indeksi

if isempty(start_idx) || isempty(end_idx) || start_idx >= end_idx
    warning('HATA: Deprem verilerini içeren <pre> etiketi web sayfasında bulunamadı veya hatalı. Web sayfası yapısı değişmiş olabilir.');
    return;
end

pre_content = web_content(start_idx+5:end_idx-1); % Etiketlerin dışındaki saf veri içeriğini al

% Ayıklanan metni satırlara böl
lines = splitlines(pre_content);

% Veri tablosunun sütun başlıklarını içeren satırı tespit et.
% Bu, verinin doğru şekilde ayrıştırılması için bir referans noktasıdır.
header_line_idx = 0;
for i = 1:length(lines)
    current_line_trimmed = strtrim(lines{i}); % Satırı baştan ve sondan boşluklardan temizle
    if contains(current_line_trimmed, 'Tarih', 'IgnoreCase', true) && ...
       contains(current_line_trimmed, 'Saat', 'IgnoreCase', true) && ...
       contains(current_line_trimmed, 'Enlem(N)', 'IgnoreCase', true) && ...
       contains(current_line_trimmed, 'Boylam(E)', 'IgnoreCase', true)
        header_line_idx = i; % Başlık satırının indeksini kaydet
        break;
    end
end

if header_line_idx == 0 || (header_line_idx + 2 >= length(lines))
    warning('HATA: Sütun başlık satırı veya veri ayırıcı satırı web sayfasında bulunamadı. Lütfen web sitesindeki <pre> etiketinin iç yapısını kontrol edin.');
    return;
end

% Veri satırlarını al - başlık ve ayırıcı çizgiden sonraki satırlar
data_start_line_idx = header_line_idx + 2;
data_lines_to_parse = lines(data_start_line_idx:end);
data_lines_to_parse = data_lines_to_parse(~cellfun('isempty', strtrim(data_lines_to_parse))); % Boş satırları temizle

% Ayrıştırılan ilk birkaç ham veri satırını örnek olarak göster
fprintf('Ayrıştırılan ilk %d ham veri satırı örneği (ayrıştırma öncesi):\n', min(5, length(data_lines_to_parse)));
for k = 1:min(5, length(data_lines_to_parse))
    disp(data_lines_to_parse{k});
end

% Her veri satırını belirli formatlara göre ayrıştırmak için düzenli ifade (regex) kullan
% Bu regex, tarih, saat, enlem, boylam, derinlik, büyüklük (ML) ve konum gibi
% deprem bilgilerini yakalamak üzere tasarlanmıştır.
data_regex = '(\d{4}\.\d{2}\.\d{2})\s+(\d{2}:\d{2}:\d{2})\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)\s+([\d.-]+)\s+([\d.-]+)\s+([\d.-]+)\s+(.*?)(?:\s+(?:İlksel|Revize(?:\d+)?))?(?:\s+\(\d{4}\.\d{2}\.\d{2}\s+\d{2}:\d{2}:\d{2}\))?$';

% Ayrıştırılmış verileri depolamak için ön-tahsis yap (performans için)
% Maksimum 500 deprem kaydı beklenir
dates_str = cell(500, 1);
times_str = cell(500, 1);
latitudes_val = zeros(500, 1);
longitudes_val = zeros(500, 1);
depths_val = zeros(500, 1);
mls_val = zeros(500, 1);
locations_str = cell(500, 1);
idx_count = 0; % Geçerli ayrıştırılan kayıt sayacı

for i = 1:length(data_lines_to_parse)
    line = strtrim(data_lines_to_parse{i}); % Mevcut satırı temizle
    if length(line) < 40 % Çok kısa satırlar genellikle veri içermez
        continue;
    end
    
    tokens = regexp(line, data_regex, 'tokens', 'once'); % Regex ile satırı ayrıştır
    
    if ~isempty(tokens) && length(tokens) >= 9 % Başarılı ayrıştırma ve yeterli token varsa
        idx_count = idx_count + 1;
        dates_str{idx_count} = tokens{1};
        times_str{idx_count} = tokens{2};
        latitudes_val(idx_count) = str2double(tokens{3});
        longitudes_val(idx_count) = str2double(tokens{4});
        depths_val(idx_count) = str2double(tokens{5});
        ml_value = str2double(tokens{7}); % ML (Yerel Büyüklük) değeri
        if isnan(ml_value) % Eğer büyüklük değeri NaN ise 0 olarak ayarla
            ml_value = 0;
        end
        mls_val(idx_count) = ml_value;
        locations_str{idx_count} = strtrim(tokens{9});
    else
        fprintf('Uyarı: Aşağıdaki satır regex ile tam olarak ayrıştırılamadı: %s\n', line);
    end
end

% Ön-tahsis edilmiş dizileri gerçek veri sayısına göre kısalt
if idx_count == 0
    disp('Ayrıştırma işlemi sonrası geçerli deprem verisi bulunamadı. Program sonlandırılıyor.');
    return;
end
dates_str = dates_str(1:idx_count);
times_str = times_str(1:idx_count);
latitudes_val = latitudes_val(1:idx_count);
longitudes_val = longitudes_val(1:idx_count);
depths_val = depths_val(1:idx_count);
mls_val = mls_val(1:idx_count);
locations_str = locations_str(1:idx_count);

% Ayrıştırılan verileri bir MATLAB tablo objesine dönüştür
% Bu, verilere daha kolay erişim ve manipülasyon sağlar.
earthquake_data = table(string(dates_str), string(times_str), latitudes_val, ...
                        longitudes_val, depths_val, mls_val, string(locations_str), ...
                        'VariableNames', {'Tarih', 'Saat', 'Enlem', 'Boylam', 'Derinlik', 'ML', 'Konum'});

% Oluşturulan tablonun ilk birkaç satırını kontrol et
disp(' ');
disp('Tüm çekilen ve ayrıştırılan deprem verileri (ilk 5 kayıt):');
disp(earthquake_data(1:min(5, height(earthquake_data)), :));
fprintf('Toplam %d deprem kaydı başarıyla ayrıştırıldı.\n', size(earthquake_data, 1));

%% 2. Son 24 Saatteki Depremleri Filtreleme
% Çekilen tüm deprem verileri arasından sadece son 24 saatte meydana gelen
% depremleri filtreler. Bu, güncel sismik aktiviteye odaklanmayı sağlar.
try
    currentTime = datetime('now', 'TimeZone', 'UTC+3'); % Mevcut zamanı al (Türkiye saatiyle)
    filterTime = currentTime - duration(24,0,0);       % Son 24 saatlik zaman dilimini hesapla
    
    fprintf('\nMevcut Zaman: %s\n', datestr(currentTime));
    fprintf('Filtreleme Başlangıç Zamanı (Son 24 Saat): %s\n', datestr(filterTime));
    
    % Tablodaki Tarih ve Saat kolonlarını birleştirerek datetime objeleri oluştur
    datetime_input = earthquake_data.Tarih + " " + earthquake_data.Saat;
    disp('Birleştirilmiş tarih-saat girişi örneği (ilk 5 kayıt):');
    disp(datetime_input(1:min(5, height(earthquake_data))));
    
    earthquake_datetimes = datetime(datetime_input, ...
                                   'InputFormat', 'yyyy.MM.dd HH:mm:ss', 'TimeZone', 'UTC+3'); % Doğru formatla datetime objesine çevir
    disp('Dönüştürülmüş datetime objeleri örneği (ilk 5 kayıt):');
    disp(earthquake_datetimes(1:min(5, length(earthquake_datetimes))));
    
    % Son 24 saatlik depremleri filtrele
    last_24_hours_filter = (earthquake_datetimes >= filterTime);
    last_24_hours = earthquake_data(last_24_hours_filter, :);
catch e % Tarih-saat filtreleme sırasında oluşabilecek hataları yakala
    warning('HATA: Tarih-saat filtreleme işlemi sırasında bir hata oluştu: %s', e.message);
    disp('Hata ayıklama bilgileri: Deprem veri tablosu kontrol ediliyor...');
    disp(earthquake_data);
    disp('Filtreleme için geçerli tarih-saat verisi bulunamadı. Program sonlandırılıyor.');
    return;
end

% Filtrelenmiş tabloya yeni kolonlar ekle: Risk_Seviyesi (metin) ve Risk_Level_Numeric (sayısal)
last_24_hours.Risk_Seviyesi = repmat(string(""), height(last_24_hours), 1);
last_24_hours.Risk_Level_Numeric = zeros(height(last_24_hours), 1);

disp(' ');
disp('*** Son 24 Saat İçinde Meydana Gelen Deprem Verileri ***');
if isempty(last_24_hours)
    disp('Son 24 saat içinde belirlenen kriterlere uyan herhangi bir deprem kaydı bulunamadı.');
else
    disp(last_24_hours);
    fprintf('Toplam %d deprem kaydı son 24 saat filtresinden geçti.\n', height(last_24_hours));
end

%% 3. Fay Hatları Verilerinin Entegrasyonu ve İlk Görselleştirme
% Bu bölüm, QGIS'ten dışa aktarılan bir CSV dosyasından fay hattı verilerini
% yükler ve son 24 saatteki depremlerle birlikte harita üzerinde önizleme
% olarak görselleştirir. Eğer fay hattı dosyası bulunamazsa, örnek fay hatları
% kullanılarak görselleştirme devam ettirilir.

csv_filename = 'avrasya_fay_hatlari_koordinatlari.csv'; % Fay hattı verilerini içeren CSV dosyasının adı
try
    disp(['QGIS''ten dışa aktarılan fay hattı verisi (', csv_filename, ') yükleniyor...']);
    fault_data_table = readtable(csv_filename); % CSV dosyasını tablo olarak oku
    fault_lon_all = fault_data_table.X; % Fay hattı boylamları
    fault_lat_all = fault_data_table.Y; % Fay hattı enlemleri
    disp('Fay hattı verileri başarıyla yüklendi.');
catch ME % CSV dosyası okunamıyorsa
    warning('HATA: Fay hattı CSV dosyası okunamadı veya bulunamadı: %s', ME.message);
    warning('Lütfen dosya adının ve sütun adlarının doğru olduğundan emin olun.');
    disp('Görselleştirme için örnek fay hatları verisi kullanılacak.');
    
    % Örnek ana fay hatları koordinatları (KAF, DAF, BAF için basitleştirilmiş)
    kaf_x = [29, 32, 35, 38, 41]; kaf_y = [40, 40.5, 40.5, 40, 39.5]; % Kuzey Anadolu Fay Hattı
    daf_x = [36.5, 38, 39.5, 41]; daf_y = [37, 38.5, 38.5, 38];         % Doğu Anadolu Fay Hattı
    baf_x = [27, 28.5, 29]; baf_y = [38.5, 38, 37.5];                   % Batı Anadolu Fay Hattı
    
    % Fay hatlarını birleştir ve NaN ile ayırarak farklı hatları göster
    fault_lon_all = [kaf_x, NaN, daf_x, NaN, baf_x];
    fault_lat_all = [kaf_y, NaN, daf_y, NaN, baf_y];
end

% Deprem ve fay hatlarının harita üzerinde ilk görselleştirmesi
figure; % Yeni bir şekil penceresi aç
hold on; % Aynı eksen üzerinde birden fazla çizime izin ver

% Fay hatlarını çiz
if exist('fault_lon_all', 'var') && ~isempty(fault_lon_all)
    plot(fault_lon_all, fault_lat_all, 'Color', [0.5 0.5 0.5], 'LineWidth', 1.5, 'DisplayName', 'Ana Fay Hatları');
end

% Son 24 saatteki depremleri önizleme olarak işaretle
if ~isempty(last_24_hours)
    scatter(last_24_hours.Boylam, last_24_hours.Enlem, 80, 'b', 'filled', 'o', 'DisplayName', 'Son 24 Saat Depremleri (Önizleme)');
end

% Harita başlığı ve eksen etiketleri
title('Son 24 Saat Depremleri ve Ana Fay Hatları (Önizleme)', 'FontSize', 14);
xlabel('Boylam (°)', 'FontSize', 12);
ylabel('Enlem (°)', 'FontSize', 12);
grid on;     % Izgara çizgilerini göster
axis equal;  % Eksen oranlarını eşit tutarak coğrafi ölçeği koru
legend('Location', 'best'); % Lejantı en uygun yere yerleştir
xlim([25 45]); % Harita boylam limitlerini belirle
ylim([34 42]); % Harita enlem limitlerini belirle
hold off;    % Çizim modunu kapat

%% 4. Sismik Risk Senaryosu Tahmini ve Mekansal Kümelenme Analizi
% Bu bölüm, Akkar ve Çağnan (2010) modelini kullanarak deprem büyüklüğüne ve
% fay hattına olan mesafeye göre tahmini Yer Hızlanması (PGA) değerlerini hesaplar.
% Ayrıca, depremlerin mekansal kümelenmesini (birbirine yakın ve belirli bir
% sayıdaki deprem) değerlendirir ve bu faktörlere göre risk seviyeleri belirler.

risky_areas = table([], [], [], [], ...
                    'VariableNames', {'Bolge', 'Orijinal_Buyukluk_ML', 'Tahmini_PGA_g', 'Risk_Seviyesi'});

% Akkar ve Çağnan (2010) Yer Hızlanması Tahmini Model Katsayıları
% Bu katsayılar, deprem büyüklüğü ve fay mesafesi gibi parametrelerden
% maksimum yer ivmesi (PGA) tahmin etmek için kullanılır.
C1_Akkar = -1.841;
C2_Akkar = 0.731;
C3_Akkar = -1.351;
h_Akkar = 8.0; % Derinlik parametresi (kilometre cinsinden)

% Risk değerlendirmesi için eşik değerler
Risk_Threshold_km = 10; % Bir depremin fay hattına olan kritik mesafesi (km)
cluster_radius_km = 30; % Kümelenme analizi için komşuluk yarıçapı (km)
min_events_in_cluster = 3; % Bir küme olarak kabul edilmesi için minimum olay sayısı

% Risk seviyelerini sayısal değerlere eşleyen bir Map objesi
risk_level_map = containers.Map({'Düşük', 'Orta', 'Yüksek'}, {1, 2, 3});

if ~isempty(last_24_hours) && exist('fault_lon_all', 'var') && ~isempty(fault_lon_all)
    % Geçerli fay hattı koordinatlarını al (NaN değerleri hariç)
    valid_fault_lon = fault_lon_all(~isnan(fault_lon_all));
    valid_fault_lat = fault_lat_all(~isnan(fault_lat_all));
    
    R_earth = 6371; % Dünya'nın ortalama yarıçapı (km) - Haversine formülü için
    
    % Mekansal Kümelenme Analizi
    % Bu bölüm, son 24 saatteki depremlerin birbirine yakın olup olmadığını
    % değerlendirerek olası sismik kümeleri (artçı şoklar veya deprem dizileri) tespit eder.
    num_earthquakes = height(last_24_hours);
    is_clustered = false(num_earthquakes, 1); % Her deprem için kümelenme durumu bayrağı
    
    if num_earthquakes > 1 % Kümelenme analizi için en az iki deprem olmalı
        earthquake_coords = [last_24_hours.Enlem, last_24_hours.Boylam];
        distances_matrix = zeros(num_earthquakes); % Depremler arası mesafeleri tutacak matris
        
        % Her deprem çifti arasındaki Haversine mesafesini hesapla
        for k1 = 1:num_earthquakes
            for k2 = k1+1:num_earthquakes
                [dist_eq, ~] = haversineDistance(earthquake_coords(k1,1), earthquake_coords(k1,2), ...
                                                  earthquake_coords(k2,1), earthquake_coords(k2,2), R_earth);
                distances_matrix(k1, k2) = dist_eq;
                distances_matrix(k2, k1) = dist_eq; % Simetrik matris
            end
        end
        
        % Her deprem için, belirli bir yarıçap içinde yeterli sayıda komşu olup olmadığını kontrol et
        for k = 1:num_earthquakes
            neighbors_count = sum(distances_matrix(k, :) <= cluster_radius_km) + 1; % Kendi depremini de say
            if neighbors_count >= min_events_in_cluster
                is_clustered(k) = true; % Eğer eşik aşıldıysa, deprem kümelenmiş sayılır
            end
        end
    end
    
    % Her bir deprem için risk seviyesi hesaplama ve tahmini PGA belirleme
    for i = 1:height(last_24_hours)
        eq_lat = last_24_hours.Enlem(i);
        eq_lon = last_24_hours.Boylam(i);
        eq_mag = last_24_hours.ML(i);
        
        min_dist_to_fault = inf; % Depremin en yakın fay hattına olan mesafesi
        
        % En yakın fay hattı parçasını bul
        for j = 1:length(valid_fault_lat)
            [dist_to_point, ~] = haversineDistance(eq_lat, eq_lon, ...
                                                   valid_fault_lat(j), valid_fault_lon(j), R_earth);
            min_dist_to_fault = min(min_dist_to_fault, dist_to_point);
        end
        
        current_risk_level_str = "Düşük"; % Varsayılan risk seviyesi
        predicted_PGA = 0; % Tahmini PGA (Peak Ground Acceleration) değeri
        min_ml_for_high_risk = 5.0; % Yüksek risk için minimum deprem büyüklüğü eşiği
        
        % Fay hattına yakın ve/veya yüksek büyüklüklü depremler için risk değerlendirmesi
        if min_dist_to_fault < Risk_Threshold_km % Deprem fay hattına yeterince yakınsa
            % Akkar ve Çağnan (2010) modeline göre PGA hesapla
            R_term = sqrt(min_dist_to_fault^2 + h_Akkar^2);
            ln_PGA = C1_Akkar + C2_Akkar * eq_mag + C3_Akkar * log(R_term);
            predicted_PGA = exp(ln_PGA); % Doğal logaritmanın tersi
            
            % Kümelenmiş veya yüksek büyüklüklü depremler için risk seviyesini yükselt
            if is_clustered(i) || eq_mag >= min_ml_for_high_risk
                current_risk_level_str = "Yüksek";
            else
                current_risk_level_str = "Orta";
            end
        end
        
        % Hesaplanan risk seviyesini ve sayısal karşılığını tabloya kaydet
        last_24_hours.Risk_Seviyesi(i) = current_risk_level_str;
        last_24_hours.Risk_Level_Numeric(i) = risk_level_map(char(current_risk_level_str));
        
        % Sadece "Düşük" risk seviyesinde olmayan depremleri riskli alanlar tablosuna ekle
        if ~strcmp(current_risk_level_str, "Düşük")
            existing_row_idx = find(strcmp(risky_areas.Bolge, last_24_hours.Konum{i}), 1);
            if isempty(existing_row_idx) % Eğer bölge daha önce eklenmemişse yeni satır ekle
                risky_areas = [risky_areas; ...
                    table(string(last_24_hours.Konum(i)), last_24_hours.ML(i), predicted_PGA, current_risk_level_str, ...
                          'VariableNames', {'Bolge', 'Orijinal_Buyukluk_ML', 'Tahmini_PGA_g', 'Risk_Seviyesi'})];
            else % Bölge zaten varsa, daha yüksek riskli veya büyük büyüklüklü depremle güncelle
                if predicted_PGA > risky_areas.Tahmini_PGA_g(existing_row_idx) || ...
                   risk_level_map(char(current_risk_level_str)) > risk_level_map(char(risky_areas.Risk_Seviyesi(existing_row_idx)))
                    risky_areas.Tahmini_PGA_g(existing_row_idx) = predicted_PGA;
                    risky_areas.Orijinal_Buyukluk_ML(existing_row_idx) = last_24_hours.ML(i);
                    risky_areas.Risk_Seviyesi(existing_row_idx) = current_risk_level_str;
                end
            end
        end
    end
end

disp(' ');
disp('*** Son 24 Saatteki Depremler İçin Tahmini Risk Senaryosu Sonuçları ***');
if isempty(risky_areas)
    disp('Herhangi bir riskli alan veya belirlenen risk seviyesinin üzerinde deprem tespit edilmedi.');
else
    disp(risky_areas);
    fprintf('Toplam %d riskli bölge belirlendi.\n', height(risky_areas));
end

%% 5. Görselleştirme: Risk Seviyelerinin Pasta Grafiği
% Bu bölüm, son 24 saatte meydana gelen depremlerin risk seviyelerine göre
% dağılımını gösteren bir pasta grafiği oluşturur. Bu, genel risk profilinin
% hızlı bir özetini sunar.

if ~isempty(last_24_hours)
    % Her risk seviyesinden deprem sayısını say
    risk_counts = [sum(strcmp(last_24_hours.Risk_Seviyesi, 'Düşük')), ...
                   sum(strcmp(last_24_hours.Risk_Seviyesi, 'Orta')), ...
                   sum(strcmp(last_24_hours.Risk_Seviyesi, 'Yüksek'))];
    risk_labels = {'Düşük Risk', 'Orta Risk', 'Yüksek Risk'};
    
    % Sadece sıfırdan büyük sayılara sahip dilimleri grafikte göster
    non_zero_indices = risk_counts > 0;
    risk_counts = risk_counts(non_zero_indices);
    risk_labels = risk_labels(non_zero_indices);
    
    if ~isempty(risk_counts)
        figure('Position', [100 100 600 400]); % Yeni bir figür penceresi aç ve boyutlandır
        pie(risk_counts, risk_labels); % Pasta grafiğini çiz
        title('Son 24 Saat Depremlerinin Risk Seviyesi Dağılımı', 'FontSize', 14);
        
        % Pasta dilimleri için renk paleti (Yeşil-Düşük, Sarı-Orta, Kırmızı-Yüksek)
        colormap([0 1 0; 1 1 0; 1 0 0]); 
        legend(risk_labels, 'Location', 'bestoutside', 'FontSize', 12); % Lejantı ekle
        
        % Grafiği PNG olarak kaydet
        print('deprem_risk_pasta_grafik.png', '-dpng', '-r300'); % 300 DPI çözünürlükle kaydet
        disp('Risk seviyesi pasta grafiği "deprem_risk_pasta_grafik.png" olarak kaydedildi.');
    else
        disp('Pasta grafiği oluşturmak için yeterli deprem verisi bulunamadı.');
    end
else
    disp('Pasta grafiği oluşturmak için son 24 saatlik deprem verisi yok.');
end

%% 6. Görselleştirme: Deprem Risk Seviyeleri Haritası
% Bu bölüm, son 24 saatteki depremleri risk seviyelerine göre farklı renklerle
% harita üzerinde görselleştirir. Bu, riskli bölgelerin coğrafi dağılımını
% net bir şekilde gösterir.

figure; % Yeni bir şekil penceresi aç
hold on; % Aynı eksen üzerinde birden fazla çizime izin ver

% Fay hatlarını haritaya çiz
if exist('fault_lon_all', 'var') && ~isempty(fault_lon_all)
    plot(fault_lon_all, fault_lat_all, 'Color', [0.5 0.5 0.5], 'LineWidth', 1.5, 'DisplayName', 'Ana Fay Hatları');
end

if ~isempty(last_24_hours)
    % Renk skalasını tanımla ve renk çubuğunu ekle
    % Colormap, sayısal risk seviyelerine (1=Düşük, 2=Orta, 3=Yüksek) karşılık gelen renkleri tanımlar
    colormap(gca, [0 1 0; 1 1 0; 1 0 0]); % Yeşil, Sarı, Kırmızı
    c = colorbar('Ticks', [1, 2, 3], 'TickLabels', {'Düşük', 'Orta', 'Yüksek'}); % Renk çubuğu ve etiketleri (Sırayı düzelttim)
    c.Label.String = 'Risk Seviyesi'; % Renk çubuğu başlığı
    
    % Her risk seviyesine göre depremleri farklı renk ve boyutlarla işaretle
    idx_dusuk = (last_24_hours.Risk_Level_Numeric == 1);
    if any(idx_dusuk)
        scatter(last_24_hours.Boylam(idx_dusuk), last_24_hours.Enlem(idx_dusuk), 100, 'g', 'filled', 'o', 'DisplayName', 'Düşük Risk');
    end
    
    idx_orta = (last_24_hours.Risk_Level_Numeric == 2);
    if any(idx_orta)
        scatter(last_24_hours.Boylam(idx_orta), last_24_hours.Enlem(idx_orta), 100, 'y', 'filled', 'o', 'DisplayName', 'Orta Risk');
    end
    
    idx_yuksek = (last_24_hours.Risk_Level_Numeric == 3);
    if any(idx_yuksek)
        scatter(last_24_hours.Boylam(idx_yuksek), last_24_hours.Enlem(idx_yuksek), 100, 'r', 'filled', 'o', 'DisplayName', 'Yüksek Risk');
    end
end

% Harita başlığı ve eksen etiketleri
title('Son 24 Saat Depremleri ve Belirlenen Risk Seviyeleri', 'FontSize', 14);
xlabel('Boylam (°)', 'FontSize', 12);
ylabel('Enlem (°)', 'FontSize', 12);
grid on; % Izgara çizgilerini göster
axis equal; % Eksen oranlarını eşit tut
legend('Location', 'bestoutside'); % Lejantı en uygun yere yerleştir
xlim([25 45]); % Harita boylam limitleri
ylim([34 42]); % Harita enlem limitleri
hold off; % Çizim modunu kapat

if ~isempty(last_24_hours)
    print('deprem_risk_haritasi.png', '-dpng', '-r300'); % Haritayı PNG olarak kaydet
    disp('Risk seviyesi haritası "deprem_risk_haritasi.png" olarak kaydedildi.');
else
    disp('Risk haritası oluşturmak için yeterli deprem verisi bulunamadı.');
end

%% 7. Görselleştirme: Riskli Bölgelerin Büyüklük Bazında Çubuk Grafiği
% Bu bölüm, belirlenen riskli bölgelerdeki en büyük deprem büyüklüklerini
% gösteren bir çubuk grafiği oluşturur. Bu, hangi bölgelerin daha büyük
% sismik olaylarla karşı karşıya kalabileceğini görselleştirir.

if ~isempty(risky_areas)
    figure; % Yeni bir şekil penceresi aç
    % Çubuk grafiği oluştur: Her bölge için orijinal deprem büyüklüğünü (ML) göster
    bar(categorical(risky_areas.Bolge), risky_areas.Orijinal_Buyukluk_ML, 'FaceColor', [0.8 0.4 0.2]);
    title('Son 24 Saatte Risk Tespit Edilen Bölgelerde Ölçülen En Yüksek Deprem Büyüklükleri (ML)', 'FontSize', 14);
    xlabel('Bölge Adı', 'FontSize', 12);
    ylabel('Orijinal Deprem Büyüklüğü (ML)', 'FontSize', 12);
    grid on; % Izgara çizgilerini göster
    xtickangle(45); % X ekseni etiketlerini 45 derece eğerek okunabilirliği artır
    
    print('deprem_risk_cubuk_grafik.png', '-dpng', '-r300');
    disp('Riskli bölgeler için çubuk grafiği "deprem_risk_cubuk_grafik.png" olarak kaydedildi.');
else
    disp('Risk çubuk grafiği oluşturmak için riskli alan verisi bulunamadı.');
end

% Analiz edilen verileri MAT dosyasında kaydet
save('earthquake_data.mat', 'last_24_hours', 'risky_areas');
disp('Analiz sonuçları "earthquake_data.mat" dosyasına kaydedildi.');

%% 8. Senaryo Bazlı Büyüklük Görselleştirmesi (Ankara Merkezi)
% Bu bölüm, belirli bir merkez (örneğin Ankara) etrafındaki depremlerin
% büyüklüklerini harita üzerinde görselleştirir. Deprem büyüklüğü, kabarcık
% boyutları ve renk skalası ile gösterilir. Bu, belirli bir şehre olan
% sismik etkinin görsel bir temsilini sunar.

scenario_lat = 39.93; % Ankara'nın enlemi
scenario_lon = 32.85; % Ankara'nın boylamı
scenario_name = 'Ankara'; % Senaryo merkezi adı

if isempty(last_24_hours)
    disp(['Senaryo (Merkez: ', scenario_name, ') için son 24 saatlik deprem verisi bulunamadı. Görselleştirme atlandı.']);
    return; % Veri yoksa bu bölümü atla
end

figure; % Yeni bir şekil penceresi aç
hold on; % Aynı eksen üzerinde birden fazla çizime izin ver

% Fay hatlarını haritaya çiz
if exist('fault_lon_all', 'var') && ~isempty(fault_lon_all)
    plot(fault_lon_all, fault_lat_all, 'Color', [0.5 0.5 0.5], 'LineWidth', 1.5, 'DisplayName', 'Ana Fay Hatları');
end

% Deprem büyüklüklerini kabarcık boyutu ve renk skalası ile göster
scatter(last_24_hours.Boylam, last_24_hours.Enlem, ...
        last_24_hours.ML .* 50, last_24_hours.ML, ... % Boyut ML'ye göre ayarlanır, renk ML'ye göre değişir
        'filled', 'o', 'DisplayName', 'Deprem Büyüklüğü (ML)');
colorbar; % Renk çubuğunu göster
colormap('jet'); % "jet" renk haritasını kullan
c = colorbar;
c.Label.String = 'Deprem Büyüklüğü (ML)'; % Renk çubuğu etiketi

title(sprintf('%s Merkezi Çevresindeki Son 24 Saat Deprem Büyüklükleri', scenario_name), 'FontSize', 14);
xlabel('Boylam (°)', 'FontSize', 12);
ylabel('Enlem (°)', 'FontSize', 12);
grid on; % Izgara çizgilerini göster
axis equal; % Eksen oranlarını eşit tut
xlim([25 45]); % Harita boylam limitleri
ylim([34 42]); % Harita enlem limitleri

% Senaryo merkezini işaretle
plot(scenario_lon, scenario_lat, 'kp', 'MarkerSize', 15, 'LineWidth', 2, 'DisplayName', sprintf('%s Merkezi', scenario_name));
legend('Location', 'best'); % Lejantı en uygun yere yerleştir
hold off; % Çizim modunu kapat

print('ankara_senaryo_buyukluk_haritasi.png', '-dpng', '-r300');
disp(['Senaryo bazlı büyüklük görselleştirmesi "', scenario_name, '_senaryo_buyukluk_haritasi.png" olarak kaydedildi.']);

%% 9. Makine Öğrenimi Modeli (Karar Ağacı) ile Risk Sınıflandırması
% Bu bölüm, Karar Ağacı algoritmasını kullanarak deprem özelliklerinden (enlem,
% boylam, derinlik, büyüklük) risk seviyesini tahmin eden bir makine öğrenimi
% modeli eğitir. Modelin doğruluğu test edilir ve karmaşıklık matrisi görselleştirilir.

disp(' ');
disp('--- Makine Öğrenimi Modeli Eğitimi ve Değerlendirmesi ---');

% Makine öğrenimi için kullanılacak verileri hazırla
% Sadece risk seviyesi atanmış (Düşük, Orta, Yüksek) depremleri kullan
if isempty(last_24_hours) || all(last_24_hours.Risk_Level_Numeric == 0)
    disp('Makine öğrenimi modeli eğitimi için yeterli ve geçerli deprem verisi bulunamadı. Bu bölüm atlandı.');
else
    % Sadece risk seviyesi atanmış (1, 2, 3) verileri filtrele
    ml_data_for_training = last_24_hours(last_24_hours.Risk_Level_Numeric >= 1, :);
    
    if isempty(ml_data_for_training)
        disp('Makine öğrenimi için risk seviyesi atanmış geçerli veri bulunamadı. Bu bölüm atlandı.');
    else
        % Özellik matrisi (X) ve hedef değişken (y) oluştur
        X = [ml_data_for_training.Enlem, ml_data_for_training.Boylam, ...
             ml_data_for_training.Derinlik, ml_data_for_training.ML];
        y = ml_data_for_training.Risk_Level_Numeric; % Risk seviyesi (sayısal)
        
        disp(['Makine öğrenimi modeli için ', num2str(size(X, 1)), ' veri noktası hazırlandı.']);
        
        % Veriyi eğitim ve test setlerine ayır (70% eğitim, 30% test)
        cv = cvpartition(length(y), 'Holdout', 0.3); % %30'unu test için ayır
        idxTrain = training(cv); % Eğitim setinin indeksleri
        idxTest = test(cv);     % Test setinin indeksleri
        
        X_train = X(idxTrain, :); % Eğitim özellikleri
        y_train = y(idxTrain);     % Eğitim hedef değişkeni
        X_test = X(idxTest, :);   % Test özellikleri
        y_test = y(idxTest);       % Test hedef değişkeni
        
        try
            % Karar Ağacı (Decision Tree) modelini eğit
            Mdl = fitctree(X_train, y_train, 'PredictorNames', {'Enlem', 'Boylam', 'Derinlik', 'Büyüklük_ML'});
            disp('Karar Ağacı modeli başarıyla eğitildi.');
            
            % Eğitilmiş modeli kullanarak test seti üzerinde tahmin yap
            y_pred = predict(Mdl, X_test);
            
            % Modelin doğruluk oranını hesapla
            accuracy = sum(y_pred == y_test) / numel(y_test);
            fprintf('Eğitilen Modelin Test Seti Doğruluk Oranı: %.2f%%\n', accuracy * 100);
            
            figure; % Yeni bir şekil penceresi aç
            % Karmaşıklık matrisini oluştur ve görselleştir
            C = confusionmat(y_test, y_pred); % Gerçek ve tahmin edilen sınıflar arasındaki karmaşıklık matrisi
            classLabels = {'Düşük Risk', 'Orta Risk', 'Yüksek Risk'}; % Sınıf etiketleri
            
            h = heatmap(classLabels, classLabels, C); % Karmaşıklık matrisini heatmap olarak göster
            h.Title = 'Karar Ağacı Modelinin Karmaşıklık Matrisi';
            h.XLabel = 'Tahmin Edilen Risk Seviyesi';
            h.YLabel = 'Gerçek Risk Seviyesi';
            h.ColorbarVisible = 'off'; % Renk çubuğunu gizle
            h.FontSize = 12; % Metin boyutunu ayarla
            
            print('ml_karmaşıklık_matrisi.png', '-dpng', '-r300');
            disp('Karar Ağacı karmaşıklık matrisi "ml_karmaşıklık_matrisi.png" olarak çizildi ve kaydedildi.');
            
        catch ME % Karar ağacı eğitimi veya tahmini sırasında oluşabilecek hataları yakala
            warning('Karar Ağacı modeli eğitilirken veya tahmin yapılırken bir hata oluştu: %s', ME.message);
            disp('Lütfen veri setinizi ve model parametrelerini kontrol edin.');
        end
    end
end
disp('--- Makine Öğrenimi Analizi Tamamlandı ---');

%% 10. Yardımcı Fonksiyonlar
% Bu bölüm, coğrafi mesafe hesaplamaları için kullanılan yardımcı fonksiyonları içerir.
% Haversine formülü, iki enlem/boylam koordinatı arasındaki mesafeyi (kilometre cinsinden)
% ve isteğe bağlı olarak azimut açısını hesaplamak için kullanılır.

function [distance_km, azimuth_deg] = haversineDistance(lat1_deg, lon1_deg, lat2_deg, lon2_deg, R_earth)
    % haversineDistance: İki coğrafi nokta arasındaki Haversine mesafesini ve azimut açısını hesaplar.
    % Kullanım:
    %   [mesafe_km, azimut_derece] = haversineDistance(enlem1, boylam1, enlem2, boylam2, Dünya_Yarıçapı)
    %
    % Girişler:
    %   lat1_deg, lon1_deg: Birinci noktanın enlem ve boylamı (derece cinsinden)
    %   lat2_deg, lon2_deg: İkinci noktanın enlem ve boylamı (derece cinsinden)
    %   R_earth: Dünya'nın ortalama yarıçapı (örneğin, 6371 km). Opsiyonel, varsayılan 6371 km.
    %
    % Çıkışlar:
    %   distance_km: İki nokta arasındaki mesafe (kilometre cinsinden)
    %   azimuth_deg: İkinci noktaya olan azimut açısı (derece cinsinden, Kuzey 0 derece)
    
    if nargin < 5
        R_earth = 6371; % Dünya'nın ortalama yarıçapı (kilometre)
    end
    
    % Derece cinsinden koordinatları radyan cinsine çevir
    lat1_rad = deg2rad(lat1_deg);
    lon1_rad = deg2rad(lon1_deg);
    lat2_rad = deg2rad(lat2_deg);
    lon2_rad = deg2rad(lon2_deg);
    
    % Enlem ve boylam farklarını hesapla
    delta_lat = lat2_rad - lat1_rad;
    delta_lon = lon2_rad - lon1_rad;
    
    % Haversine formülü uygulaması
    a = sin(delta_lat./2).^2 + cos(lat1_rad) .* cos(lat2_rad) .* sin(delta_lon./2).^2;
    c = 2 * atan2(sqrt(a), sqrt(1-a));
    
    distance_km = R_earth * c; % Mesafeyi kilometre cinsinden bul
    
    % Azimut açısını hesapla (eğer istenirse)
    if nargout > 1
        y = sin(delta_lon) .* cos(lat2_rad);
        x = cos(lat1_rad) .* sin(lat2_rad) - sin(lat1_rad) .* cos(lat2_rad) .* cos(delta_lon);
        azimuth_rad = atan2(y, x);
        azimuth_deg = rad2deg(azimuth_rad);
        azimuth_deg = mod(azimuth_deg + 360, 360); % 0-360 derece aralığına getir
    else
        azimuth_deg = NaN; % İstenmezse NaN döndür
    end
end

function rad = deg2rad(deg)
    % deg2rad: Derece cinsinden açıyı radyan cinsine çevirir.
    rad = deg * pi / 180;
end

function deg = rad2deg(rad)
    % rad2deg: Radyan cinsinden açıyı derece cinsine çevirir.
    deg = rad * 180 / pi;
end

%% 11. Türkiye Bölgesel Yüksek Risk Uyarı Sistemi
% Bu bölüm, önceden tanımlanmış kritik bölgeler (Marmara, Ege, Doğu Anadolu vb.)
% için son 24 saatteki deprem aktivitesini ve makine öğrenimi modelinden gelen
% risk tahminlerini değerlendirerek bölgesel yüksek risk uyarıları üretir.
% Marmara Bölgesi'nde kritik eşik aşıldığında sesli bir alarm çalar ve
% ilgili kişilere e-posta bildirimi gönderir. Tespit edilen yüksek riskli
% depremler bir UI tablosunda görüntülenir.

% --- MATLAB ile E-posta Adreslerini Okuma ve Sismik Uyarı Mesajı Gönderme Entegrasyonu ---
% 1. SMTP Ayarlarını Yapılandırma (İlk kodunuzdan entegre edildi)
disp('--- SMTP Ayarları Yapılandırılıyor ---');
setpref('Internet','SMTP_Server','smtp.gmail.com');
setpref('Internet','E_mail','mogrenelim@gmail.com'); % Gönderici e-posta adresi
setpref('Internet','SMTP_Username','mogrenelim@gmail.com'); % SMTP kullanıcı adı
setpref('Internet','SMTP_Password','jilghsxzjsfpolfq'); % Gmail App Password

% TLS için JavaMail özelliklerini ayarla
props = java.lang.System.getProperties;
props.setProperty('mail.smtp.auth','true');
props.setProperty('mail.smtp.starttls.enable','true'); % TLS'yi etkinleştir
props.setProperty('mail.smtp.port','587'); % Gmail TLS portu

% 2. Dosya Yolunu Tanımlama ve E-posta Adreslerini Okuma (İlk kodunuzdan entegre edildi)
dosyaYolu = 'C:/Users/yakup/Desktop/YeniMetinBelgesi.txt'; % E-posta listesini içeren dosya yolu
mailAdresleriHucre = {}; % Başlangıçta boş hücre dizisi

disp(['E-posta adresleri dosyası (', dosyaYolu, ') okunuyor...']);
fileID = fopen(dosyaYolu, 'r');
if fileID == -1
    warning('UYARI: E-posta adresleri dosyası açılamadı. E-posta bildirimleri yapılamayabilir.');
    % Hata durumunda boş mail listesi ile devam et
else
    mailAdresleriHucre = textscan(fileID, '%s', 'Delimiter', '\n', 'CollectOutput', true);
    fclose(fileID);
    if isempty(mailAdresleriHucre{1})
        warning('UYARI: E-posta adresleri dosyasında geçerli e-posta adresi bulunamadı.');
    else
        fprintf('Dosyadan %d adet e-posta adresi başarıyla okundu.\n', length(mailAdresleriHucre{1}));
    end
end
% --- E-posta Entegrasyonu Sonu ---

% Bu tablo, yüksek riskli deprem kayıtlarını dinamik olarak tutacak.
% 'Zaman' sütunu 'datetime' türünde, 'Bölge' sütunu ise 'string' olarak tanımlanır.
deprem_data = table('Size',[0 5], 'VariableTypes',{'datetime','double','double','double','string'}, ...
                    'VariableNames',{'Zaman','Büyüklük','Enlem','Boylam','Bölge'}); 

% Eğer zaten açık bir "Yüksek Riskli Deprem Kayıtları" figürü varsa, kapat ve yeniden oluştur.
% Bu, her çalıştırmada temiz bir başlangıç sağlar.
figure_title = 'Yüksek Riskli Deprem Kayıtları';
existing_figures = findobj('Type', 'figure', 'Name', figure_title);
if ~isempty(existing_figures)
    close(existing_figures); % Eğer aynı isimde bir figür açıksa kapat
end

% Yeni bir figür penceresi oluştur ve boyutlandır
hFig = figure('Name', figure_title, 'NumberTitle', 'off', 'Position', [100 100 800 450]); 

% İlk başta boş bir UI tablosu (uitable) oluşturulur. Veri, analizler yapıldıktan sonra güncellenecektir.
hTable = uitable(hFig, 'Data', {}, ... % Başlangıçta boş veri
                         'ColumnName', deprem_data.Properties.VariableNames, ... % Sütun başlıkları
                         'Position', [20 50 760 380]); % Tablonun konum ve boyutu

% Tablonun sütun genişliklerinin içeriğe göre otomatik ayarlanmasını sağlar
set(hTable, 'ColumnWidth', 'auto');

disp(' ');
disp('--- Türkiye Bölgesel Yüksek Risk Uyarı Sistemi Başlatılıyor ---');

% Uyarılacak kritik bölgeler ve her bölge için yüksek risk eşik değerleri tanımlanır.
% Bu tanımlamalar, Türkiye'nin ana fay hatları ve yoğun nüfuslu alanlar dikkate alınarak yapılmıştır.
region_definitions = struct();

% 1. Marmara Bölgesi ve Kuzey Anadolu Fay Hattı'nın Batı Uzantısı (İstanbul, Kocaeli, Sakarya, Bursa çevreleri)
region_definitions(1).name = 'Marmara (KAF Batı)';
region_definitions(1).latLimits = [40.2, 41.5];  
region_definitions(1).lonLimits = [28.0, 31.0];
region_definitions(1).highRiskThreshold = 2; % Bu bölgede 2 veya daha fazla yüksek riskli deprem olursa uyarı ver

% 2. Ege Bölgesi (Batı Anadolu Fay Kuşağı) (İzmir, Manisa, Denizli, Aydın çevreleri)
region_definitions(2).name = 'Ege Bölgesi (BAF)';
region_definitions(2).latLimits = [37.0, 39.5]; 
region_definitions(2).lonLimits = [26.0, 30.0];
region_definitions(2).highRiskThreshold = 3; % Ege'deki fay yoğunluğu nedeniyle eşik biraz artırıldı

% 3. İç Anadolu Bölgesi (Ankara ve Çevresi) - Nispeten düşük sismik aktiviteye sahip ama önemli bir merkez
region_definitions(3).name = 'İç Anadolu (Ankara Çevresi)';
region_definitions(3).latLimits = [39.0, 40.5];
region_definitions(3).lonLimits = [32.0, 34.0];
region_definitions(3).highRiskThreshold = 1; % Daha hassas uyarı

% 4. Doğu Anadolu Fay Hattı (DAF) Orta Kısım (Kahramanmaraş, Malatya, Elazığ çevreleri)
region_definitions(4).name = 'DAF Orta (Malatya-Maraş)';
region_definitions(4).latLimits = [37.0, 38.5]; 
region_definitions(4).lonLimits = [36.0, 38.0];
region_definitions(4).highRiskThreshold = 2;

% 5. Kuzey Anadolu Fay Hattı'nın Doğu Uzantısı (Erzincan, Bingöl, Muş çevreleri)
region_definitions(5).name = 'KAF Doğu (Erzincan-Bingöl)';
region_definitions(5).latLimits = [39.0, 40.5];
region_definitions(5).lonLimits = [38.5, 41.5];
region_definitions(5).highRiskThreshold = 2;

% 6. Akdeniz ve Güney Anadolu (Tektonik olarak aktif bir bölge) (Antalya, Mersin, Adana, Hatay çevreleri)
region_definitions(6).name = 'Akdeniz ve Güney Anadolu';
region_definitions(6).latLimits = [35.0, 37.0]; 
region_definitions(6).lonLimits = [30.0, 36.0];
region_definitions(6).highRiskThreshold = 2;

% 7. Doğu Karadeniz (KAF'ın kuzey kolları) (Trabzon, Rize, Artvin çevreleri)
region_definitions(7).name = 'Doğu Karadeniz';
region_definitions(7).latLimits = [40.5, 41.5];
region_definitions(7).lonLimits = [37.0, 42.0];
region_definitions(7).highRiskThreshold = 1; % Genellikle daha az aktif ama yine de izlenebilir

% --- Alarm Sesi Tanımlamaları ---
% Yüksek risk uyarısı durumunda çalacak sesin parametreleri belirlenir.
alarmDuration = 2;       % Alarm sesi süresi (saniye)
alarmFrequency = 3000;   % Alarm sesi frekansı (Hz) - tiz ve dikkat çekici
alarmVolume = 0.8;       % Alarm sesi şiddeti (0.0 - 1.0 arası) - yüksek ses seviyesi
Fs = 44100;              % Örnekleme frekansı (Hz) - ses kalitesi için standart
alarmSound = alarmVolume * sin(2*pi*alarmFrequency*(1:round(Fs*alarmDuration))/Fs); % Alarm sesi sinyalini oluştur

% Makine öğrenimi modeli eğitilmişse ve son 24 saatlik deprem verisi varsa bölgesel risk analizini başlat
if exist('Mdl', 'var') && ~isempty(Mdl) && ~isempty(last_24_hours)
    % Her tanımlı bölge için sismik aktiviteyi ve riski kontrol et
    for r = 1:length(region_definitions)
        current_region = region_definitions(r);
        
        fprintf('\n--> "%s" Bölgesi için risk kontrolü yapılıyor...\n', current_region.name);
        
        % Mevcut bölgenin coğrafi sınırları içine giren depremleri filtrele
        idx_in_region = last_24_hours.Enlem >= current_region.latLimits(1) & ...
                        last_24_hours.Enlem <= current_region.latLimits(2) & ...
                        last_24_hours.Boylam >= current_region.lonLimits(1) & ...
                        last_24_hours.Boylam <= current_region.lonLimits(2);
        
        region_earthquakes = last_24_hours(idx_in_region, :); % Bölgedeki depremler
        
        high_risk_count = 0; % Bölgedeki yüksek riskli deprem sayacı
        
        if ~isempty(region_earthquakes)
            % Bu bölgedeki depremlerin özelliklerini alarak modele ver
            X_region_earthquakes = [region_earthquakes.Enlem, region_earthquakes.Boylam, ...
                                    region_earthquakes.Derinlik, region_earthquakes.ML];
            
            % Makine öğrenimi modeli ile bu depremlerin risk seviyelerini tahmin et
            predicted_risk_numeric_for_region = predict(Mdl, X_region_earthquakes);
            
            % Tahmin edilen risk seviyesi '3' (Yüksek Risk) olanları say
            high_risk_count = sum(predicted_risk_numeric_for_region == 3);
            
            fprintf('  "%s" Bölgesinde son 24 saatte %d adet yüksek riskli deprem tespit edildi.\n', ...
                    current_region.name, high_risk_count);
            
            % Eğer yüksek riskli deprem sayısı bölge için tanımlanan eşiği aşarsa uyarı ver
            if high_risk_count >= current_region.highRiskThreshold
                fprintf('\n*** BÖLGESEL YÜKSEK RİSK UYARISI: %s ***\n', upper(current_region.name));
                fprintf('  Bu bölgede son 24 saatte %d adet yüksek riskli deprem meydana gelmiştir.\n', high_risk_count);
                fprintf('  Bölgedeki sismik aktiviteyi yakından takip edin ve ilgili kurumların uyarılarını dikkate alın!\n');
                
                % Tespit edilen yüksek riskli deprem verilerini UI tablosuna ekle
                high_risk_earthquakes_in_this_region = region_earthquakes(predicted_risk_numeric_for_region == 3, :);
                
                if ~isempty(high_risk_earthquakes_in_this_region)
                    % Her bir yüksek riskli deprem için tabloya yeni satır ekle
                    for eq_idx = 1:size(high_risk_earthquakes_in_this_region, 1)
                        current_eq = high_risk_earthquakes_in_this_region(eq_idx, :);
                        
                        % Tarih ve Saat kolonlarını birleştirerek datetime objesi oluştur
                        current_eq_datetime = datetime(string(current_eq.Tarih) + " " + string(current_eq.Saat), ...
                                                      'InputFormat', 'yyyy.MM.dd HH:mm:ss');
                        
                        % Yeni satırı 'deprem_data' tablosuna ekle
                        new_row = {current_eq_datetime, current_eq.ML, ...
                                   current_eq.Enlem, current_eq.Boylam, current_region.name};
                        deprem_data = [deprem_data; new_row]; 
                    end
                end
                
                % Önemli: SADECE MARMARA BÖLGESİ İÇİN ALARM ÇAL VE E-POSTA BİLDİRİMİ GÖNDER
                if strcmp(current_region.name, 'Marmara (KAF Batı)')
                    sound(alarmSound, Fs); % Tanımlanan tiz ve uzun alarm sesini çal
                    disp(' ');
                    disp('!!! MARMARA BÖLGESİ İÇİN KRİTİK SEVİYEDE ALARM ÇALDI !!!'); 
                    
                    % --- E-posta Bildirimi (Entegre edilmiş kod) ---
                    if ~isempty(mailAdresleriHucre) && ~isempty(mailAdresleriHucre{1}) % Eğer mail adresleri okunduysa
                        
                        bolgeAdi = current_region.name; % E-posta konusu için bölge adı
                        konu = sprintf('ACİL DEPREM UYARISI: %s Bölgesi Yüksek Risk!', bolgeAdi);
                        depremSayisi = high_risk_count; % Gerçek veriye göre güncelleyin
                        guncelTarih = datestr(now, 'dd.mm.yyyy HH:MM');
                        
    mesajGovdesi = {
        'Değerli Kullanıcı,',
        '', % Boş satır
        sprintf('%s Bölgesinde yüksek riskli sismik aktivite tespit edildi.', bolgeAdi),
        sprintf('Son 24 saatte bölgede %d adet yüksek riskli deprem meydana geldi.', depremSayisi),
        'Lütfen dikkatli olun ve ilgili kurumların (AFAD, Kandilli vb.) uyarılarını takip edin.',
        '', % Boş satır
        'Bu mesaj otomatik olarak Türkiye Bölgesel Yüksek Risk Uyarı Sistemi tarafından gönderilmiştir.',
        sprintf('Tarih: %s', guncelTarih)
    };

                        % E-posta gönderme döngüsü (Okunan tüm adreslere gönder)
                        for i_mail = 1:length(mailAdresleriHucre{1})
                            currentMail = strtrim(mailAdresleriHucre{1}{i_mail}); % Baştaki/sondaki boşlukları temizle
                            if ~isempty(currentMail) % Boş satırları atla
                                fprintf('E-posta gönderiliyor: %s ... ', currentMail);
                                try
                                    sendmail(currentMail, konu, mesajGovdesi);
                                    fprintf('BAŞARILI!\n');
                                catch ME_send % E-posta gönderme hatasını yakala
                                    warning('E-posta gönderilemedi (%s): %s', currentMail, ME_send.message);
                                    % Hata günlüğüne kaydet (isteğe bağlı)
                                    fid_log = fopen('email_errors.log', 'a');
                                    fprintf(fid_log, '%s: E-posta gönderilemedi (%s): %s\n', guncelTarih, currentMail, ME_send.message);
                                    fclose(fid_log);
                                end
                            end
                        end
                    else
                        warning('UYARI: Marmara Bölgesi için e-posta gönderilemedi. E-posta adresleri dosyası okunamadı veya boş.');
                    end
                end
            end
        else
            fprintf('  "%s" Bölgesinde son 24 saatte incelenecek deprem bulunamadı.\n', current_region.name);
        end
    end
    
    % --- TÜM BÖLGELER İÇİN TOPLAM YÜKSEK RİSKLİ DEPREM KAYITLARINI UI TABLOSUNDA GÖSTER ---
    % Tüm bölgelerin kontrolü tamamlandıktan sonra uitable'ı güncelleyin.
    if ~isempty(deprem_data)
        % Deprem verilerini zamana göre sırala (en eski en üstte, en yeni en altta)
        deprem_data = sortrows(deprem_data, 'Zaman');
        
        % Uitable'a aktarmadan önce 'datetime' ve 'string' sütunlarını 'char' türüne dönüştür.
        % Uitable, 'char' dizilerini daha iyi işler.
        display_data_cell = table2cell(deprem_data);
        
        % Zaman (datetime) sütununu okunabilir bir tarih-saat formatına dönüştür
        display_data_cell(:, 1) = cellfun(@(x) datestr(x, 'dd-mmm-yyyy HH:MM:SS'), display_data_cell(:, 1), 'UniformOutput', false);
        
        % Bölge (string) sütununu char dizisine dönüştür
        display_data_cell(:, 5) = cellfun(@char, display_data_cell(:, 5), 'UniformOutput', false);
        
        % Güncellenmiş veriyi uitable'a aktar
        set(hTable, 'Data', display_data_cell); 
        set(hTable, 'ColumnWidth', 'auto'); % Sütun genişliklerini içeriğe göre otomatik ayarla
        drawnow; % Figürün ve tablonun hemen güncellenmesini sağla
        
        fprintf('\n-- Yüksek Riskli Deprem Kayıtları "Yüksek Riskli Deprem Kayıtları" penceresinde güncellendi. --\n');
    else
        fprintf('\nSon analizde hiçbir bölgede yüksek riskli deprem tespit edilmedi. Kayıt tablosu boş.\n');
        % Eğer tablo boşsa ve figür açıksa, içini temizleyebiliriz
        set(hTable, 'Data', {});
        set(hTable, 'ColumnName', deprem_data.Properties.VariableNames); % Kolon başlıklarını koru
        drawnow;
    end
else
    disp('Makine öğrenimi modeli (Mdl) eğitilmediği veya son 24 saatlik deprem verisi olmadığı için bölgesel risk analizi ve uyarı sistemi başlatılamıyor.');
end

disp('--- Türkiye Bölgesel Yüksek Risk Uyarı Sistemi Tamamlandı ---');