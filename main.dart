import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const CarJournalApp());
}

class CarJournalApp extends StatelessWidget {
  const CarJournalApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Бортовой Журнал PRO',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0F172A),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF2563EB),
          secondary: Color(0xFF10B981),
          surface: Color(0xFF1E293B),
        ),
      ),
      home: const JournalHomePage(),
    );
  }
}

class JournalHomePage extends StatefulWidget {
  const JournalHomePage({super.key});

  @override
  State<JournalHomePage> createState() => _JournalHomePageState();
}

class _JournalHomePageState extends State<JournalHomePage> {
  int _tabIndex = 0;
  bool _isLoadingGps = false;

  final String donateUrl = 'https://boosty.to/ваш_аккаунт';

  Map<String, Map<String, double>> defaultPrices = {
    'Лукойл': {'АИ-92': 56.20, 'АИ-95': 61.80, 'АИ-100': 82.50, 'ДТ': 69.90, 'Газ': 29.50},
    'Газпромнефть': {'АИ-92': 55.40, 'АИ-95': 60.50, 'АИ-100': 80.90, 'ДТ': 68.80, 'Газ': 28.90},
    'Роснефть': {'АИ-92': 55.10, 'АИ-95': 60.10, 'АИ-100': 79.80, 'ДТ': 68.40, 'Газ': 28.50},
    'Татнефть': {'АИ-92': 54.90, 'АИ-95': 59.90, 'АИ-100': 79.50, 'ДТ': 68.20, 'Газ': 28.00},
    'Нефтьмагистраль': {'АИ-92': 55.30, 'АИ-95': 60.40, 'АИ-100': 79.90, 'ДТ': 68.50, 'Газ': 28.80},
    'Teboil': {'АИ-92': 55.90, 'АИ-95': 61.40, 'АИ-100': 81.90, 'ДТ': 69.50, 'Газ': 29.20},
    'Средняя по региону': {'АИ-92': 55.50, 'АИ-95': 60.60, 'АИ-100': 80.50, 'ДТ': 68.90, 'Газ': 28.90},
  };

  Map<String, Map<String, double>> _fuelPrices = {};
  List<Map<String, dynamic>> _cars = [];
  int _activeCarId = 1;
  List<Map<String, dynamic>> _refuelings = [];
  List<Map<String, dynamic>> _expenses = [];

  String _selectedFuel = 'АИ-95';
  String _selectedMode = 'Смешанный';
  bool _isFullTank = true;
  String _stationBrand = 'Газпромнефть';
  String _address = 'Геолокация не запрошена';
  double _lat = 55.7558;
  double _lon = 37.6173;
  List<Map<String, dynamic>> _mapStations = [];

  String _expCategory = '🔧 ТО и Запчасти';

  final TextEditingController _quickCtrl = TextEditingController();
  final TextEditingController _odoCtrl = TextEditingController();
  final TextEditingController _litersCtrl = TextEditingController();
  final TextEditingController _costCtrl = TextEditingController();
  final TextEditingController _stationCtrl = TextEditingController();

  final TextEditingController _expCostCtrl = TextEditingController();
  final TextEditingController _expCommCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _stationCtrl.text = _stationBrand;
    _initData();
  }

  Future<void> _initData() async {
    final prefs = await SharedPreferences.getInstance();

    _fuelPrices = {};
    defaultPrices.forEach((brand, fuels) {
      _fuelPrices[brand] = Map<String, double>.from(fuels);
    });

    try {
      final resp = await http.get(Uri.parse('https://raw.githubusercontent.com/Sanox667/car-journal-pro/main/prices.json')).timeout(const Duration(seconds: 3));
      if (resp.statusCode == 200) {
        final onlineData = jsonDecode(resp.body) as Map<String, dynamic>;
        onlineData.forEach((k, v) {
          _fuelPrices[k] = (v as Map<String, dynamic>).map((fk, fv) => MapEntry(fk, (fv as num).toDouble()));
        });
      }
    } catch (_) {}

    final savedCars = prefs.getString('cars');
    if (savedCars != null) {
      _cars = List<Map<String, dynamic>>.from(jsonDecode(savedCars));
    }
    if (_cars.isEmpty) {
      _cars = [{'id': 1, 'name': 'Моё авто', 'service_interval': 10000, 'last_service_odo': 0}];
    }

    _activeCarId = prefs.getInt('active_car_id') ?? (_cars.first['id'] as num).toInt();

    final savedRef = prefs.getString('refuelings');
    if (savedRef != null) {
      _refuelings = List<Map<String, dynamic>>.from(jsonDecode(savedRef));
    }

    final savedExp = prefs.getString('expenses');
    if (savedExp != null) {
      _expenses = List<Map<String, dynamic>>.from(jsonDecode(savedExp));
    }

    _syncControllersWithState();
    setState(() {});
  }

  Future<void> _saveData() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('fuel_prices', jsonEncode(_fuelPrices));
    await prefs.setString('cars', jsonEncode(_cars));
    await prefs.setInt('active_car_id', _activeCarId);
    await prefs.setString('refuelings', jsonEncode(_refuelings));
    await prefs.setString('expenses', jsonEncode(_expenses));
  }

  void _syncControllersWithState() {
    final price = _getFuelPrice(_stationBrand, _selectedFuel);
    _costCtrl.text = price.toStringAsFixed(2);
    _stationCtrl.text = _stationBrand;
  }

  Map<String, dynamic> get _activeCar {
    return _cars.firstWhere((c) => (c['id'] as num).toInt() == _activeCarId, orElse: () => _cars.first);
  }

  List<Map<String, dynamic>> get _carRefuelings {
    final list = _refuelings.where((r) => (r['car_id'] as num).toInt() == _activeCarId).toList();
    list.sort((a, b) => (a['odometer'] as num).toInt().compareTo((b['odometer'] as num).toInt()));
    return list;
  }

  List<Map<String, dynamic>> get _carExpenses {
    final list = _expenses.where((e) => (e['car_id'] as num).toInt() == _activeCarId).toList();
    list.sort((a, b) => (b['id'] as int).compareTo((a['id'] as int)));
    return list;
  }

  int get _currentOdometer {
    final refs = _carRefuelings;
    return refs.isNotEmpty ? (refs.last['odometer'] as num).toInt() : 0;
  }

  double _getFuelPrice(String stationBrand, String fuelType) {
    String key = 'Средняя по региону';
    for (final known in defaultPrices.keys) {
      if (stationBrand.toLowerCase().contains(known.toLowerCase())) {
        key = known;
        break;
      }
    }
    return _fuelPrices[key]?[fuelType] ?? defaultPrices['Средняя по региону']?[fuelType] ?? 60.0;
  }

  void _updateFuelPrice(String stationBrand, String fuelType, double pricePerLiter) {
    if (pricePerLiter <= 10 || pricePerLiter > 250) return;
    String key = 'Средняя по региону';
    for (final known in defaultPrices.keys) {
      if (stationBrand.toLowerCase().contains(known.toLowerCase())) {
        key = known;
        break;
      }
    }
    _fuelPrices[key] ??= {};
    _fuelPrices[key]![fuelType] = double.parse(pricePerLiter.toStringAsFixed(2));
  }

  void _notify(String msg, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
        backgroundColor: isError ? const Color(0xFFEF4444) : const Color(0xFF10B981),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  String _detectBrandName(String raw) {
    final low = raw.toLowerCase();
    final mapping = {
      'лукойл': 'Лукойл', 'lukoil': 'Лукойл',
      'газпром': 'Газпромнефть', 'gazprom': 'Газпромнефть',
      'роснефть': 'Роснефть', 'rosneft': 'Роснефть',
      'татнефть': 'Татнефть', 'tatneft': 'Татнефть',
      'нефтьмагистраль': 'Нефтьмагистраль',
      'teboil': 'Teboil', 'тебойл': 'Teboil',
    };
    for (final entry in mapping.entries) {
      if (low.contains(entry.key)) return entry.value;
    }
    return raw.trim().isNotEmpty ? raw.trim() : 'Средняя по региону';
  }

  int _haversineM(double lat1, double lon1, double lat2, double lon2) {
    const r = 6371000.0;
    final p1 = lat1 * pi / 180;
    final p2 = lat2 * pi / 180;
    final dp = (lat2 - lat1) * pi / 180;
    final dl = (lon2 - lon1) * pi / 180;
    final a = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2);
    return (2 * r * atan2(sqrt(a), sqrt(1 - a))).round();
  }

  Future<void> _handleGpsSearch() async {
    setState(() => _isLoadingGps = true);
    _notify('📡 Ищем АЗС и подтягиваем цены на карту...');

    double? lat;
    double? lon;

    try {
      LocationPermission perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
      if (perm == LocationPermission.whileInUse || perm == LocationPermission.always) {
        final pos = await Geolocator.getCurrentPosition().timeout(const Duration(seconds: 7));
        lat = pos.latitude;
        lon = pos.longitude;
      }
    } catch (_) {}

    if (lat == null || lon == null) {
      try {
        final resp = await http.get(Uri.parse('http://ip-api.com/json/?fields=status,lat,lon,city,regionName&lang=ru')).timeout(const Duration(seconds: 5));
        final data = jsonDecode(resp.body);
        if (data['status'] == 'success') {
          lat = (data['lat'] as num).toDouble();
          lon = (data['lon'] as num).toDouble();
        }
      } catch (_) {
        setState(() => _isLoadingGps = false);
        _notify('⚠️ Не удалось получить координаты.', isError: true);
        return;
      }
    }

    if (lat == null || lon == null) {
      setState(() => _isLoadingGps = false);
      _notify('⚠️ Геолокация недоступна.', isError: true);
      return;
    }

    double curLat = lat;
    double curLon = lon;
    List<Map<String, dynamic>> foundStations = [];

    try {
      final query = '[out:json][timeout:6];node["amenity"="fuel"](around:3000,$curLat,$curLon);out body;';
      final url = Uri.parse('https://overpass-api.de/api/interpreter?data=${Uri.encodeComponent(query)}');
      final resp = await http.get(url, headers: {'User-Agent': 'CarJournalPro/2.0'}).timeout(const Duration(seconds: 6));
      final osm = jsonDecode(resp.body);
      final elements = List<Map<String, dynamic>>.from(osm['elements'] ?? []);
      
      foundStations = elements.map((el) {
        final tags = Map<String, dynamic>.from(el['tags'] ?? {});
        final rawName = (tags['brand'] ?? tags['name'] ?? tags['operator'] ?? 'АЗС').toString();
        final brand = _detectBrandName(rawName);
        final price = _getFuelPrice(brand, _selectedFuel);
        return {
          'brand': brand,
          'price': price,
          'lat': (el['lat'] as num).toDouble(),
          'lon': (el['lon'] as num).toDouble(),
        };
      }).toList();

      if (elements.isNotEmpty) {
        elements.sort((a, b) {
          final da = _haversineM(curLat, curLon, (a['lat'] as num).toDouble(), (a['lon'] as num).toDouble());
          final db = _haversineM(curLat, curLon, (b['lat'] as num).toDouble(), (b['lon'] as num).toDouble());
          return da.compareTo(db);
        });
        final nearest = elements.first;
        final tags = Map<String, dynamic>.from(nearest['tags'] ?? {});
        _stationBrand = _detectBrandName((tags['brand'] ?? tags['name'] ?? tags['operator'] ?? 'АЗС').toString());
      }
    } catch (_) {}

    setState(() {
      _lat = curLat;
      _lon = curLon;
      _mapStations = foundStations;
      _stationCtrl.text = _stationBrand;
      final newPrice = _getFuelPrice(_stationBrand, _selectedFuel);
      _costCtrl.text = newPrice.toStringAsFixed(2);
      _isLoadingGps = false;
    });

    _notify('📍 Найдено АЗС: ${_mapStations.length}. Смотрите вкладку «Карта АЗС»!');
  }

  // Меню выбора навигатора для построения маршрута
  void _showRouteMenu(String brand, double destLat, double destLon) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E293B),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        return Container(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Маршрут до АЗС: $brand',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
              ),
              const SizedBox(height: 12),
              _buildBtn('🚗 Яндекс Навигатор', () async {
                Navigator.pop(context);
                final uri = Uri.parse('yandexnavi://build_route_on_map?lat_to=$destLat&lon_to=$destLon');
                if (await canLaunchUrl(uri)) {
                  await launchUrl(uri);
                } else {
                  final webUri = Uri.parse('https://yandex.ru/maps/?rtext=~$destLat,$destLon&rtype=uri');
                  await launchUrl(webUri, mode: LaunchMode.externalApplication);
                }
              }, bgColor: const Color(0xFFCE2E2E)),
              const SizedBox(height: 8),
              _buildBtn('🗺 Google Карты', () async {
                Navigator.pop(context);
                final uri = Uri.parse('https://www.google.com/maps/search/?api=1&query=$destLat,$destLon');
                await launchUrl(uri, mode: LaunchMode.externalApplication);
              }, bgColor: const Color(0xFF2563EB)),
              const SizedBox(height: 8),
              _buildBtn('📍 Яндекс Карты (Веб)', () async {
                Navigator.pop(context);
                final uri = Uri.parse('https://yandex.ru/maps/?rtext=~$destLat,$destLon&rtype=uri');
                await launchUrl(uri, mode: LaunchMode.externalApplication);
              }, bgColor: const Color(0xFFD97706)),
            ],
          ),
        );
      },
    );
  }

  String _nowStr() {
    final n = DateTime.now();
    return '${n.year}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')} ${n.hour.toString().padLeft(2, '0')}:${n.minute.toString().padLeft(2, '0')}';
  }

  String _fmtNum(num val) {
    return val.toStringAsFixed(0).replaceAllMapped(RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'), (Match m) => '${m[1]} ');
  }

  void _saveQuickRefuel() {
    final text = _quickCtrl.text.replaceAll(',', '.');
    final matches = RegExp(r'\d+(?:\.\d+)?').allMatches(text).map((m) => m.group(0)!).toList();

    if (matches.length != 2 && matches.length != 3) {
      _notify('⚠️ Введите: Пробег Литры (напр: 145200 42.5)', isError: true);
      return;
    }

    final odo = double.parse(matches[0]).round();
    final liters = double.parse(matches[1]);
    final autoPrice = _getFuelPrice(_stationBrand, _selectedFuel);
    final val = matches.length == 3 ? double.parse(matches[2]) : autoPrice;

    final prevOdo = _currentOdometer;
    if (prevOdo > 0 && odo <= prevOdo) {
      _notify('⚠️ Пробег ($odo) должен быть больше предыдущего ($prevOdo)!', isError: true);
      return;
    }

    final totalCost = val < 250 ? val * liters : val;
    final pricePerL = liters > 0 ? totalCost / liters : autoPrice;
    _updateFuelPrice(_stationBrand, _selectedFuel, pricePerL);

    _refuelings.add({
      'id': DateTime.now().millisecondsSinceEpoch,
      'car_id': _activeCarId,
      'date': _nowStr(),
      'odometer': odo,
      'liters': liters,
      'cost': totalCost,
      'is_full': 1,
      'fuel_type': _selectedFuel,
      'mode': _selectedMode,
      'station_name': _stationBrand,
      'lat': _lat,
      'lon': _lon,
      'address': _address,
    });

    _quickCtrl.clear();
    _saveData();
    setState(() {});
    _notify('⚡ Записано ($_stationBrand): $odo км, $liters л, ${totalCost.toStringAsFixed(0)} ₽');
  }

  void _saveFullRefuel() {
    final odo = int.tryParse(_odoCtrl.text.trim().replaceAll(' ', ''));
    final liters = double.tryParse(_litersCtrl.text.trim().replaceAll(',', '.'));
    final val = double.tryParse(_costCtrl.text.trim().replaceAll(',', '.'));

    if (odo == null || liters == null || val == null || odo <= 0 || liters <= 0 || val <= 0) {
      _notify('⚠️ Заполните все поля корректными числами!', isError: true);
      return;
    }

    final prevOdo = _currentOdometer;
    if (prevOdo > 0 && odo <= prevOdo) {
      _notify('⚠️ Пробег должен быть больше предыдущего ($prevOdo км)!', isError: true);
      return;
    }

    final totalCost = val < 250 ? val * liters : val;
    final pricePerL = totalCost / liters;
    final stBrand = _stationCtrl.text.trim().isNotEmpty ? _stationCtrl.text.trim() : _stationBrand;

    _updateFuelPrice(stBrand, _selectedFuel, pricePerL);

    _refuelings.add({
      'id': DateTime.now().millisecondsSinceEpoch,
      'car_id': _activeCarId,
      'date': _nowStr(),
      'odometer': odo,
      'liters': liters,
      'cost': totalCost,
      'is_full': _isFullTank ? 1 : 0,
      'fuel_type': _selectedFuel,
      'mode': _selectedMode,
      'station_name': stBrand,
      'lat': _lat,
      'lon': _lon,
      'address': _address,
    });

    _odoCtrl.clear();
    _litersCtrl.clear();
    _saveData();
    setState(() {});
    _notify('✅ Заправка ($stBrand) сохранена!');
  }

  void _loadDemoData() {
    _refuelings.removeWhere((r) => (r['car_id'] as num).toInt() == _activeCarId);
    _expenses.removeWhere((e) => (e['car_id'] as num).toInt() == _activeCarId);

    final car = _activeCar;
    car['last_service_odo'] = 140000;
    car['service_interval'] = 10000;

    final demoRefs = [
      [143100, 40.0, 2420.0, 1, 'АИ-95', 'Смешанный', 'Газпромнефть', 55.8941, 37.4432, 'Химки', '2026-09-28 10:15'],
      [143600, 45.5, 2811.9, 1, 'АИ-95', 'Город', 'Лукойл', 55.7558, 37.6173, 'Москва', '2026-10-05 18:40'],
      [144150, 37.4, 2247.7, 1, 'АИ-95', 'Трасса', 'Роснефть', 55.9912, 37.2145, 'Зеленоград', '2026-10-12 08:30'],
      [144680, 47.2, 2850.9, 1, 'АИ-95', 'Город', 'Нефтьмагистраль', 55.6890, 37.8920, 'Люберцы', '2026-10-18 09:15'],
      [145200, 42.5, 2571.2, 1, 'АИ-95', 'Смешанный', 'Газпромнефть', 55.8941, 37.4432, 'Химки', '2026-10-25 14:20'],
    ];

    int baseId = DateTime.now().millisecondsSinceEpoch;
    for (final r in demoRefs) {
      _refuelings.add({
        'id': baseId++, 'car_id': _activeCarId, 'odometer': r[0], 'liters': r[1],
        'cost': r[2], 'is_full': r[3], 'fuel_type': r[4], 'mode': r[5],
        'station_name': r[6], 'lat': r[7], 'lon': r[8], 'address': r[9], 'date': r[10],
      });
    }

    _syncControllersWithState();
    _saveData();
    setState(() {});
    _notify('🎲 Демо-данные загружены!');
  }

  Widget _buildCard({required List<Widget> children}) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: const Color(0xFF1E293B), borderRadius: BorderRadius.circular(12)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
    );
  }

  Widget _buildBtn(String text, VoidCallback onTap, {Color bgColor = const Color(0xFF2563EB), Color textColor = Colors.white}) {
    return Material(
      color: bgColor,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 11, horizontal: 10),
          child: Text(text, textAlign: TextAlign.center, style: TextStyle(color: textColor, fontWeight: FontWeight.bold, fontSize: 12.5)),
        ),
      ),
    );
  }

  Widget _buildTextField(TextEditingController ctrl, String label, {bool isNumber = false, Color textColor = Colors.white}) {
    return TextField(
      controller: ctrl,
      keyboardType: isNumber ? const TextInputType.numberWithOptions(decimal: true) : TextInputType.text,
      style: TextStyle(color: textColor, fontSize: 14),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(color: Color(0xFF94A3B8), fontSize: 12.5),
        filled: true, fillColor: const Color(0xFF0F172A),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Color(0xFF334155))),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Color(0xFF2563EB), width: 1.5)),
      ),
    );
  }

  Widget _buildRefuelTab() {
    final autoPrice = _getFuelPrice(_stationBrand, _selectedFuel);
    final prevOdo = _currentOdometer;
    final prevHint = prevOdo > 0 ? 'Предыдущий: $prevOdo км' : 'Первая запись';
    final brands = ['Лукойл', 'Газпромнефть', 'Роснефть', 'Татнефть', 'Нефтьмагистраль', 'Teboil'];
    final fuels = ['АИ-92', 'АИ-95', 'АИ-100', 'ДТ', 'Газ'];
    final modes = ['Город', 'Трасса', 'Смешанный'];

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        _buildCard(
          children: [
            const Text('📍 Геолокация и выбор АЗС', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFFF8FAFC))),
            const SizedBox(height: 8),
            _buildBtn(_isLoadingGps ? '⏳ Ищем АЗС...' : '📡 Найти АЗС и цены на карте по GPS', _isLoadingGps ? () {} : _handleGpsSearch, bgColor: const Color(0xFF10B981)),
            const SizedBox(height: 8),
            const Text('Или выберите бренд в 1 клик:', style: TextStyle(fontSize: 11.5, color: Color(0xFF94A3B8))),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6, runSpacing: 6,
              children: brands.map((b) {
                final isSel = _stationBrand == b;
                return SizedBox(
                  width: (MediaQuery.of(context).size.width - 68) / 3,
                  child: _buildBtn(b, () {
                    setState(() {
                      _stationBrand = b;
                      _stationCtrl.text = b;
                      _costCtrl.text = _getFuelPrice(b, _selectedFuel).toStringAsFixed(2);
                    });
                  }, bgColor: isSel ? const Color(0xFF059669) : const Color(0xFF334155)),
                );
              }).toList(),
            ),
            const SizedBox(height: 10),
            _buildTextField(_stationCtrl, 'Название АЗС'),
          ],
        ),
        _buildCard(
          children: [
            const Text('⚡ Быстрый ввод', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF94A3B8))),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(child: _buildTextField(_quickCtrl, '145200 42.5 (цена: ${autoPrice.toStringAsFixed(2)} ₽)')),
                const SizedBox(width: 8),
                _buildBtn('Ок', _saveQuickRefuel, bgColor: const Color(0xFF10B981)),
              ],
            ),
          ],
        ),
        _buildCard(
          children: [
            const Text('Новая заправка', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFFF8FAFC))),
            const SizedBox(height: 10),
            _buildTextField(_odoCtrl, 'Пробег, км ($prevHint)', isNumber: true),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(child: _buildTextField(_litersCtrl, 'Литры', isNumber: true)),
                const SizedBox(width: 8),
                Expanded(child: _buildTextField(_costCtrl, 'Цена 1л / Сумма', isNumber: true, textColor: const Color(0xFF38BDF8))),
              ],
            ),
            const SizedBox(height: 10),
            const Text('Марка топлива:', style: TextStyle(fontSize: 11.5, color: Color(0xFF94A3B8))),
            const SizedBox(height: 6),
            Row(
              children: fuels.map((f) {
                final isSel = _selectedFuel == f;
                return Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: _buildBtn(f, () {
                      setState(() {
                        _selectedFuel = f;
                        _costCtrl.text = _getFuelPrice(_stationBrand, f).toStringAsFixed(2);
                      });
                    }, bgColor: isSel ? const Color(0xFF2563EB) : const Color(0xFF334155)),
                  ),
                );
              }).toList(),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Заправка до полного бака', style: TextStyle(fontSize: 13.5)),
              value: _isFullTank, activeColor: const Color(0xFF10B981),
              onChanged: (v) => setState(() => _isFullTank = v),
            ),
            const SizedBox(height: 12),
            _buildBtn('СОХРАНИТЬ ЗАПРАВКУ', _saveFullRefuel),
          ],
        ),
      ],
    );
  }

  // ---------------- ВКЛАДКА 3: КАРТА АЗС С МЕНЮ МАРШРУТА ----------------
  Widget _buildMapTab() {
    return FlutterMap(
      options: MapOptions(
        initialCenter: LatLng(_lat, _lon),
        initialZoom: 14.0,
      ),
      children: [
        TileLayer(
          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
          userAgentPackageName: 'com.carjournal.app',
        ),
        MarkerLayer(
          markers: [
            // Маркер текущей позиции пользователя
            Marker(
              point: LatLng(_lat, _lon),
              width: 50,
              height: 50,
              child: const Icon(Icons.my_location, color: Colors.blueAccent, size: 38),
            ),
            // Маркеры АЗС с ценами и открытием меню маршрута по тапу
            ..._mapStations.map((st) {
              final brand = st['brand'] ?? 'АЗС';
              final price = (st['price'] as num).toDouble();
              final stationLat = (st['lat'] as num).toDouble();
              final stationLon = (st['lon'] as num).toDouble();

              return Marker(
                point: LatLng(stationLat, stationLon),
                width: 95,
                height: 65,
                child: GestureDetector(
                  onTap: () {
                    // При нажатии показываем выбор навигатора и одновременно выбираем АЗС в форму
                    setState(() {
                      _stationBrand = brand;
                      _stationCtrl.text = brand;
                      _costCtrl.text = price.toStringAsFixed(2);
                    });
                    _showRouteMenu(brand, stationLat, stationLon);
                  },
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                        decoration: BoxDecoration(
                          color: const Color(0xFF1E293B),
                          border: Border.all(color: const Color(0xFF38BDF8), width: 1),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          '${price.toStringAsFixed(1)} ₽',
                          style: const TextStyle(color: Color(0xFF38BDF8), fontSize: 10, fontWeight: FontWeight.bold),
                        ),
                      ),
                      const Icon(Icons.local_gas_station, color: Colors.redAccent, size: 28),
                    ],
                  ),
                ),
              );
            }),
          ],
        ),
      ],
    );
  }

  Widget _buildExpensesTab() {
    final categories = ['🔧 ТО и Запчасти', '🚿 Мойка', '📄 Страховка', '🅿️ Штрафы/Парковка', '📦 Прочее'];
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        _buildCard(
          children: [
            const Text('Добавить расход', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
            Wrap(
              spacing: 6, runSpacing: 6,
              children: categories.map((c) {
                final isSel = _expCategory == c;
                return _buildBtn(c, () => setState(() => _expCategory = c), bgColor: isSel ? const Color(0xFF2563EB) : const Color(0xFF334155));
              }).toList(),
            ),
            const SizedBox(height: 10),
            _buildTextField(_expCostCtrl, 'Сумма (₽)', isNumber: true),
            const SizedBox(height: 10),
            _buildTextField(_expCommCtrl, 'Комментарий'),
            const SizedBox(height: 12),
            _buildBtn('СОХРАНИТЬ РАСХОД', () {
              final cost = double.tryParse(_expCostCtrl.text.trim().replaceAll(',', '.'));
              if (cost == null || cost <= 0) {
                _notify('⚠️ Введите сумму!', isError: true);
                return;
              }
              _expenses.add({
                'id': DateTime.now().millisecondsSinceEpoch,
                'car_id': _activeCarId, 'date': _nowStr(),
                'category': _expCategory, 'cost': cost,
                'comment': _expCommCtrl.text.trim().isNotEmpty ? _expCommCtrl.text.trim() : 'Без комментария',
              });
              _expCostCtrl.clear(); _expCommCtrl.clear();
              _saveData(); setState(() {});
              _notify('✅ Расход добавлен!');
            }, bgColor: const Color(0xFF10B981)),
          ],
        ),
      ],
    );
  }

  Widget _buildStatsTab() {
    final refs = _carRefuelings;
    final exps = _carExpenses;
    final totalFuelCost = refs.fold<double>(0.0, (s, r) => s + (r['cost'] as num).toDouble());
    final totalExtraCost = exps.fold<double>(0.0, (s, e) => s + (e['cost'] as num).toDouble());

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        _buildCard(
          children: [
            const Text('Сводка затрат', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Text('• Топливо: ${_fmtNum(totalFuelCost)} ₽'),
            Text('• Прочее: ${_fmtNum(totalExtraCost)} ₽'),
            Text('• ИТОГО: ${_fmtNum(totalFuelCost + totalExtraCost)} ₽', style: const TextStyle(color: Color(0xFF10B981), fontWeight: FontWeight.bold)),
          ],
        ),
      ],
    );
  }

  Widget _buildGarageTab() {
    final car = _activeCar;
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        _buildCard(
          children: [
            Text('Гараж: ${car['name']}', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
            _buildBtn('☕ Задонатить разработчику', () async => await launchUrl(Uri.parse(donateUrl), mode: LaunchMode.externalApplication), bgColor: const Color(0xFF8B5CF6)),
            const SizedBox(height: 8),
            _buildBtn('🎲 Загрузить демо-данные', _loadDemoData, bgColor: const Color(0xFF334155)),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final car = _activeCar;
    final currOdo = _currentOdometer;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Container(
              color: const Color(0xFF1E293B),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('${car['name']} (${_fmtNum(currOdo)} км)', style: const TextStyle(fontSize: 16.5, fontWeight: FontWeight.bold)),
                  _buildBtn('Гараж', () => setState(() => _tabIndex = 4), bgColor: const Color(0xFF334155)),
                ],
              ),
            ),
            Expanded(
              child: [
                _buildRefuelTab(),
                _buildExpensesTab(),
                _buildMapTab(),
                _buildStatsTab(),
                _buildGarageTab(),
              ][_tabIndex],
            ),
          ],
        ),
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _tabIndex,
        onTap: (i) => setState(() => _tabIndex = i),
        backgroundColor: const Color(0xFF1E293B),
        selectedItemColor: const Color(0xFF38BDF8),
        unselectedItemColor: const Color(0xFF94A3B8),
        type: BottomNavigationBarType.fixed,
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.local_gas_station), label: 'Заправки'),
          BottomNavigationBarItem(icon: Icon(Icons.receipt_long), label: 'Расходы'),
          BottomNavigationBarItem(icon: Icon(Icons.map), label: 'Карта АЗС'),
          BottomNavigationBarItem(icon: Icon(Icons.bar_chart), label: 'Аналитика'),
          BottomNavigationBarItem(icon: Icon(Icons.build_circle_outlined), label: 'Гараж'),
        ],
      ),
    );
  }
}
