import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
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
  final String repoReleasesUrl =
      'https://github.com/Sanox667/car-journal-pro/actions';

  final Map<String, Map<String, double>> defaultPrices = {
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
  double _lat = 0.0;
  double _lon = 0.0;

  String _expCategory = '🔧 ТО и Запчасти';

  final TextEditingController _quickCtrl = TextEditingController();
  final TextEditingController _odoCtrl = TextEditingController();
  final TextEditingController _litersCtrl = TextEditingController();
  final TextEditingController _costCtrl = TextEditingController();
  final TextEditingController _stationCtrl = TextEditingController();

  final TextEditingController _expCostCtrl = TextEditingController();
  final TextEditingController _expCommCtrl = TextEditingController();

  final TextEditingController _srvOdoCtrl = TextEditingController();
  final TextEditingController _srvIntCtrl = TextEditingController();
  final TextEditingController _newCarNameCtrl = TextEditingController();
  final TextEditingController _newCarIntCtrl = TextEditingController(text: '10000');

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
    final savedPrices = prefs.getString('fuel_prices');
    if (savedPrices != null) {
      try {
        final decoded = jsonDecode(savedPrices) as Map<String, dynamic>;
        decoded.forEach((k, v) {
          _fuelPrices[k] = (v as Map<String, dynamic>)
              .map((fk, fv) => MapEntry(fk, (fv as num).toDouble()));
        });
      } catch (_) {}
    }

    final savedCars = prefs.getString('cars');
    if (savedCars != null) {
      _cars = List<Map<String, dynamic>>.from(jsonDecode(savedCars));
    }
    if (_cars.isEmpty) {
      _cars = [
        {
          'id': 1,
          'name': 'Моё авто',
          'service_interval': 10000,
          'last_service_odo': 0,
        }
      ];
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

    final car = _activeCar;
    final currOdo = _currentOdometer;
    final lastSrv = (car['last_service_odo'] as num).toInt();
    _srvOdoCtrl.text = (lastSrv > 0 ? lastSrv : currOdo).toString();
    _srvIntCtrl.text = car['service_interval'].toString();
  }

  Map<String, dynamic> get _activeCar {
    return _cars.firstWhere(
      (c) => (c['id'] as num).toInt() == _activeCarId,
      orElse: () => _cars.first,
    );
  }

  List<Map<String, dynamic>> get _carRefuelings {
    final list = _refuelings
        .where((r) => (r['car_id'] as num).toInt() == _activeCarId)
        .toList();
    list.sort((a, b) =>
        (a['odometer'] as num).toInt().compareTo((b['odometer'] as num).toInt()));
    return list;
  }

  List<Map<String, dynamic>> get _carExpenses {
    final list = _expenses
        .where((e) => (e['car_id'] as num).toInt() == _activeCarId)
        .toList();
    list.sort((a, b) => (b['id'] as num).toInt().compareTo((a['id'] as num).toInt()));
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
    return _fuelPrices[key]?[fuelType] ??
        defaultPrices['Средняя по региону']?[fuelType] ??
        60.0;
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
        content: Text(
          msg,
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
        ),
        backgroundColor: isError ? const Color(0xFFEF4444) : const Color(0xFF10B981),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  String _detectBrandName(String raw) {
    final low = raw.toLowerCase();
    final mapping = {
      'лукойл': 'Лукойл',
      'lukoil': 'Лукойл',
      'газпром': 'Газпромнефть',
      'gazprom': 'Газпромнефть',
      'роснефть': 'Роснефть',
      'rosneft': 'Роснефть',
      'татнефть': 'Татнефть',
      'tatneft': 'Татнефть',
      'нефтьмагистраль': 'Нефтьмагистраль',
      'teboil': 'Teboil',
      'тебойл': 'Teboil',
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
    final a = sin(dp / 2) * sin(dp / 2) +
        cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2);
    return (2 * r * atan2(sqrt(a), sqrt(1 - a))).round();
  }

  Future<void> _handleGpsSearch() async {
    setState(() => _isLoadingGps = true);
    _notify('📡 Определяем координаты и ищем ближайшую АЗС...');

    double? lat;
    double? lon;

    try {
      LocationPermission perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.whileInUse ||
          perm == LocationPermission.always) {
        final pos = await Geolocator.getCurrentPosition()
            .timeout(const Duration(seconds: 7));
        lat = pos.latitude;
        lon = pos.longitude;
      }
    } catch (_) {}

    if (lat == null || lon == null) {
      try {
        final resp = await http
            .get(Uri.parse(
                'http://ip-api.com/json/?fields=status,lat,lon,city,regionName&lang=ru'))
            .timeout(const Duration(seconds: 5));
        final data = jsonDecode(resp.body);
        if (data['status'] == 'success') {
          lat = (data['lat'] as num).toDouble();
          lon = (data['lon'] as num).toDouble();
        }
      } catch (_) {
        setState(() => _isLoadingGps = false);
        _notify('⚠️ Не удалось получить координаты. Проверьте GPS или интернет.',
            isError: true);
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
    String foundBrand = 'Средняя по региону';
    int? distM;
    String addrStr = '${curLat.toStringAsFixed(4)}, ${curLon.toStringAsFixed(4)}';

    try {
      final query =
          '[out:json][timeout:6];node["amenity"="fuel"](around:2500,$curLat,$curLon);out body;';
      final url = Uri.parse(
          'https://overpass-api.de/api/interpreter?data=${Uri.encodeComponent(query)}');
      final resp = await http
          .get(url, headers: {'User-Agent': 'CarJournalPro/2.0'})
          .timeout(const Duration(seconds: 6));
      final osm = jsonDecode(resp.body);
      final elements = List<Map<String, dynamic>>.from(osm['elements'] ?? []);
      if (elements.isNotEmpty) {
        final double baseLat = curLat;
        final double baseLon = curLon;
        elements.sort((a, b) {
          final da = _haversineM(baseLat, baseLon, (a['lat'] as num).toDouble(),
              (a['lon'] as num).toDouble());
          final db = _haversineM(baseLat, baseLon, (b['lat'] as num).toDouble(),
              (b['lon'] as num).toDouble());
          return da.compareTo(db);
        });
        final nearest = elements.first;
        final tags = Map<String, dynamic>.from(nearest['tags'] ?? {});
        final rawName =
            (tags['brand'] ?? tags['name'] ?? tags['operator'] ?? 'АЗС').toString();
        foundBrand = _detectBrandName(rawName);
        final nLat = (nearest['lat'] as num).toDouble();
        final nLon = (nearest['lon'] as num).toDouble();
        distM = _haversineM(baseLat, baseLon, nLat, nLon);
        curLat = nLat;
        curLon = nLon;
      }
    } catch (_) {}

    try {
      final nomUrl = Uri.parse(
          'https://nominatim.openstreetmap.org/reverse?format=json&lat=$curLat&lon=$curLon&zoom=18&accept-language=ru');
      final resp = await http
          .get(nomUrl, headers: {'User-Agent': 'CarJournalPro/2.0'})
          .timeout(const Duration(seconds: 5));
      final nom = jsonDecode(resp.body);
      final addr = Map<String, dynamic>.from(nom['address'] ?? {});
      final city =
          addr['city'] ?? addr['town'] ?? addr['village'] ?? addr['state'] ?? '';
      final road = addr['road'] ?? '';
      final house = addr['house_number'] ?? '';
      final parts =
          [city, road, house].where((s) => s.toString().isNotEmpty).toList();
      if (parts.isNotEmpty) {
        addrStr = parts.join(', ');
      }
    } catch (_) {}

    setState(() {
      _stationBrand = foundBrand;
      _stationCtrl.text = foundBrand;
      _address = distM != null ? '$addrStr ($distM м)' : addrStr;
      _lat = curLat;
      _lon = curLon;
      final newPrice = _getFuelPrice(_stationBrand, _selectedFuel);
      _costCtrl.text = newPrice.toStringAsFixed(2);
      _isLoadingGps = false;
    });

    final newPrice = _getFuelPrice(_stationBrand, _selectedFuel);
    _notify(
        '📍 Найдена АЗС: $_stationBrand | Цена $_selectedFuel: ${newPrice.toStringAsFixed(2)} ₽/л');
  }

  List<Map<String, dynamic>> _calculateConsumptionPoints() {
    final records = _carRefuelings;
    if (records.length < 2) return [];

    final List<Map<String, dynamic>> points = [];
    int lastFullOdo = (records.first['odometer'] as num).toInt();
    double accLiters = 0.0;
    double accCost = 0.0;

    for (int i = 1; i < records.length; i++) {
      final r = records[i];
      final odo = (r['odometer'] as num).toInt();
      final liters = (r['liters'] as num).toDouble();
      final cost = (r['cost'] as num).toDouble();
      final isFull = (r['is_full'] as num).toInt() == 1;

      accLiters += liters;
      accCost += cost;

      if (isFull && odo > lastFullOdo) {
        final dist = odo - lastFullOdo;
        final cons = (accLiters / dist) * 100.0;
        points.add({
          'date': r['date'],
          'odometer': odo,
          'distance': dist,
          'liters': accLiters,
          'cost': accCost,
          'consumption': cons,
          'price_per_liter': liters > 0 ? cost / liters : 0.0,
          'mode': r['mode'],
          'fuel_type': r['fuel_type'],
          'station': r['station_name'] ?? '',
        });
        lastFullOdo = odo;
        accLiters = 0.0;
        accCost = 0.0;
      }
    }
    return points;
  }

  String _nowStr() {
    final n = DateTime.now();
    final y = n.year.toString();
    final m = n.month.toString().padLeft(2, '0');
    final d = n.day.toString().padLeft(2, '0');
    final h = n.hour.toString().padLeft(2, '0');
    final min = n.minute.toString().padLeft(2, '0');
    return '$y-$m-$d $h:$min';
  }

  String _fmtNum(num val) {
    return val.toStringAsFixed(0).replaceAllMapped(
        RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'), (Match m) => '${m[1]} ');
  }

  void _saveQuickRefuel() {
    final text = _quickCtrl.text.replaceAll(',', '.');
    final matches = RegExp(r'\d+(?:\.\d+)?')
        .allMatches(text)
        .map((m) => m.group(0)!)
        .toList();

    if (matches.length != 2 && matches.length != 3) {
      _notify('⚠️ Введите: Пробег Литры (например: 145200 42.5)', isError: true);
      return;
    }

    final odo = double.parse(matches[0]).round();
    final liters = double.parse(matches[1]);
    final autoPrice = _getFuelPrice(_stationBrand, _selectedFuel);
    final val = matches.length == 3 ? double.parse(matches[2]) : autoPrice;

    final prevOdo = _currentOdometer;
    if (prevOdo > 0 && odo <= prevOdo) {
      _notify('⚠️ Пробег ($odo) должен быть больше предыдущего ($prevOdo)!',
          isError: true);
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

    final pts = _calculateConsumptionPoints();
    final consTxt = pts.isNotEmpty
        ? ' | Расход: ${(pts.last['consumption'] as double).toStringAsFixed(2)} л/100км'
        : '';
    _notify(
        '⚡ Записано ($_stationBrand): $odo км, $liters л, ${totalCost.toStringAsFixed(0)} ₽$consTxt');
  }

  void _saveFullRefuel() {
    final odo = int.tryParse(_odoCtrl.text.trim().replaceAll(' ', ''));
    final liters = double.tryParse(_litersCtrl.text.trim().replaceAll(',', '.'));
    final val = double.tryParse(_costCtrl.text.trim().replaceAll(',', '.'));

    if (odo == null ||
        liters == null ||
        val == null ||
        odo <= 0 ||
        liters <= 0 ||
        val <= 0) {
      _notify('⚠️ Заполните пробег, литры и стоимость корректными числами!',
          isError: true);
      return;
    }

    final prevOdo = _currentOdometer;
    if (prevOdo > 0 && odo <= prevOdo) {
      _notify(
          '⚠️ Новый пробег ($odo км) должен быть больше предыдущего ($prevOdo км)!',
          isError: true);
      return;
    }

    final totalCost = val < 250 ? val * liters : val;
    final pricePerL = totalCost / liters;
    final stBrand = _stationCtrl.text.trim().isNotEmpty
        ? _stationCtrl.text.trim()
        : _stationBrand;

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

    final pts = _calculateConsumptionPoints();
    if (_carRefuelings.length == 1) {
      _notify('✅ Первая заправка ($odo км, $stBrand) сохранена!');
    } else if (!_isFullTank) {
      _notify('⏳ Частичная заправка сохранена!');
    } else if (pts.isNotEmpty) {
      final lastP = pts.last;
      _notify(
          '✅ Сохранено ($stBrand)! +${lastP['distance']} км | Расход: ${(lastP['consumption'] as double).toStringAsFixed(2)} л/100км');
    } else {
      _notify('✅ Заправка сохранена!');
    }
  }

  void _loadDemoData() {
    _refuelings.removeWhere((r) => (r['car_id'] as num).toInt() == _activeCarId);
    _expenses.removeWhere((e) => (e['car_id'] as num).toInt() == _activeCarId);

    final car = _activeCar;
    car['last_service_odo'] = 140000;
    car['service_interval'] = 10000;

    final demoRefs = [
      [143100, 40.0, 2420.0, 1, 'АИ-95', 'Смешанный', 'Газпромнефть', 55.8941, 37.4432, 'Химки, Ленинградское ш.', '2026-09-28 10:15'],
      [143600, 45.5, 2811.9, 1, 'АИ-95', 'Город', 'Лукойл', 55.7558, 37.6173, 'Москва, Олимпийский пр-т', '2026-10-05 18:40'],
      [144150, 37.4, 2247.7, 1, 'АИ-95', 'Трасса', 'Роснефть', 55.9912, 37.2145, 'Зеленоград, М-10', '2026-10-12 08:30'],
      [144680, 47.2, 2850.9, 1, 'АИ-95', 'Город', 'Нефтьмагистраль', 55.6890, 37.8920, 'Люберцы, Новорязанское ш.', '2026-10-18 09:15'],
      [145200, 42.5, 2571.2, 1, 'АИ-95', 'Смешанный', 'Газпромнефть', 55.8941, 37.4432, 'Химки, Ленинградское ш.', '2026-10-25 14:20'],
    ];

    int baseId = DateTime.now().millisecondsSinceEpoch;
    for (final r in demoRefs) {
      _refuelings.add({
        'id': baseId++,
        'car_id': _activeCarId,
        'odometer': r[0],
        'liters': r[1],
        'cost': r[2],
        'is_full': r[3],
        'fuel_type': r[4],
        'mode': r[5],
        'station_name': r[6],
        'lat': r[7],
        'lon': r[8],
        'address': r[9],
        'date': r[10],
      });
    }

    final demoExps = [
      ['🔧 ТО и Запчасти', 6800.0, 'Масло ДВС и фильтры', '2026-10-01 12:00'],
      ['🚿 Мойка', 950.0, 'Комплексная мойка кузова и салона', '2026-10-14 19:20'],
      ['📄 Страховка', 8400.0, 'Полис ОСАГО', '2026-10-20 11:00'],
    ];
    for (final ex in demoExps) {
      _expenses.add({
        'id': baseId++,
        'car_id': _activeCarId,
        'category': ex[0],
        'cost': ex[1],
        'comment': ex[2],
        'date': ex[3],
      });
    }

    _syncControllersWithState();
    _saveData();
    setState(() {});
    _notify('🎲 Демо-данные с геометками загружены!');
  }

  Widget _buildCard({required List<Widget> children}) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }

  Widget _buildBtn(
    String text,
    VoidCallback onTap, {
    Color bgColor = const Color(0xFF2563EB),
    Color textColor = Colors.white,
  }) {
    return Material(
      color: bgColor,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 11, horizontal: 10),
          child: Text(
            text,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: textColor,
              fontWeight: FontWeight.bold,
              fontSize: 12.5,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTextField(
    TextEditingController ctrl,
    String label, {
    bool isNumber = false,
    Color textColor = Colors.white,
  }) {
    return TextField(
      controller: ctrl,
      keyboardType: isNumber
          ? const TextInputType.numberWithOptions(decimal: true)
          : TextInputType.text,
      style: TextStyle(color: textColor, fontSize: 14),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(color: Color(0xFF94A3B8), fontSize: 12.5),
        filled: true,
        fillColor: const Color(0xFF0F172A),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: Color(0xFF334155)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: Color(0xFF2563EB), width: 1.5),
        ),
      ),
    );
  }

  Widget _buildRefuelTab() {
    final autoPrice = _getFuelPrice(_stationBrand, _selectedFuel);
    final prevOdo = _currentOdometer;
    final prevHint = prevOdo > 0 ? 'Предыдущий: $prevOdo км' : 'Первая запись';
    final brands = [
      'Лукойл',
      'Газпромнефть',
      'Роснефть',
      'Татнефть',
      'Нефтьмагистраль',
      'Teboil'
    ];
    final fuels = ['АИ-92', 'АИ-95', 'АИ-100', 'ДТ', 'Газ'];
    final modes = ['Город', 'Трасса', 'Смешанный'];

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        _buildCard(
          children: [
            const Text(
              '📍 Геолокация и автоподстановка цен АЗС',
              style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFFF8FAFC)),
            ),
            const SizedBox(height: 8),
            _buildBtn(
              _isLoadingGps
                  ? '⏳ Определяем координаты...'
                  : '📡 Найти ближайшую АЗС по GPS и подставить цену',
              _isLoadingGps ? () {} : _handleGpsSearch,
              bgColor: const Color(0xFF10B981),
            ),
            const SizedBox(height: 8),
            Text(
              '📍 Адрес: $_address',
              style: TextStyle(
                fontSize: 11.5,
                color: _lat != 0
                    ? const Color(0xFF10B981)
                    : const Color(0xFF94A3B8),
              ),
            ),
            const SizedBox(height: 8),
            const Text('Или выберите сеть АЗС в 1 клик:',
                style: TextStyle(fontSize: 11.5, color: Color(0xFF94A3B8))),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: brands.map((b) {
                final isSel = _stationBrand == b;
                return SizedBox(
                  width: (MediaQuery.of(context).size.width - 68) / 3,
                  child: _buildBtn(
                    b,
                    () {
                      setState(() {
                        _stationBrand = b;
                        _stationCtrl.text = b;
                        _costCtrl.text =
                            _getFuelPrice(b, _selectedFuel).toStringAsFixed(2);
                      });
                    },
                    bgColor:
                        isSel ? const Color(0xFF059669) : const Color(0xFF334155),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 10),
            _buildTextField(_stationCtrl, 'Название АЗС (по GPS или вручную)'),
          ],
        ),
        _buildCard(
          children: [
            const Text(
              '⚡ Быстрый ввод (можно без цены — тариф АЗС подставится сам)',
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF94A3B8)),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: _buildTextField(
                    _quickCtrl,
                    '145200 42.5 (тариф ${autoPrice.toStringAsFixed(2)} ₽)',
                  ),
                ),
                const SizedBox(width: 8),
                _buildBtn('Ок', _saveQuickRefuel,
                    bgColor: const Color(0xFF10B981)),
              ],
            ),
          ],
        ),
        _buildCard(
          children: [
            const Text('Новая заправка',
                style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFFF8FAFC))),
            const SizedBox(height: 10),
            _buildTextField(_odoCtrl, 'Пробег, км ($prevHint)', isNumber: true),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child:
                      _buildTextField(_litersCtrl, 'Литры (42.5)', isNumber: true),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _buildTextField(
                    _costCtrl,
                    'Цена 1л / Сумма',
                    isNumber: true,
                    textColor: const Color(0xFF38BDF8),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            const Text('Марка топлива:',
                style: TextStyle(fontSize: 11.5, color: Color(0xFF94A3B8))),
            const SizedBox(height: 6),
            Row(
              children: fuels.map((f) {
                final isSel = _selectedFuel == f;
                return Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: _buildBtn(
                      f,
                      () {
                        setState(() {
                          _selectedFuel = f;
                          _costCtrl.text =
                              _getFuelPrice(_stationBrand, f).toStringAsFixed(2);
                        });
                      },
                      bgColor: isSel
                          ? const Color(0xFF2563EB)
                          : const Color(0xFF334155),
                    ),
                  ),
                );
              }).toList(),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Заправка до полного бака',
                  style: TextStyle(fontSize: 13.5)),
              value: _isFullTank,
              activeColor: const Color(0xFF10B981),
              onChanged: (v) => setState(() => _isFullTank = v),
            ),
            const Text('Режим езды:',
                style: TextStyle(fontSize: 11.5, color: Color(0xFF94A3B8))),
            const SizedBox(height: 6),
            Row(
              children: modes.map((m) {
                final isSel = _selectedMode == m;
                return Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 3),
                    child: _buildBtn(
                      m,
                      () => setState(() => _selectedMode = m),
                      bgColor: isSel
                          ? const Color(0xFF2563EB)
                          : const Color(0xFF334155),
                    ),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 12),
            _buildBtn('СОХРАНИТЬ ЗАПРАВКУ', _saveFullRefuel),
          ],
        ),
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 6),
          child: Text('Последние заправки:',
              style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF94A3B8))),
        ),
        ..._carRefuelings.reversed.take(12).map((r) {
          final odo = (r['odometer'] as num).toInt();
          final lit = (r['liters'] as num).toDouble();
          final cost = (r['cost'] as num).toDouble();
          final priceL = lit > 0 ? cost / lit : 0.0;
          final badge = (r['is_full'] as num).toInt() == 1 ? 'Полный' : 'Частично';
          final st = (r['station_name'] ?? 'АЗС').toString();
          final addr = (r['address'] ?? '').toString();
          final geoTxt =
              (addr.isNotEmpty && addr != 'Геолокация не запрошена')
                  ? ' • 📍 $addr'
                  : '';

          return _buildCard(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${_fmtNum(odo)} км • $lit л (${r['fuel_type']}) • ${cost.toStringAsFixed(0)} ₽ (${priceL.toStringAsFixed(2)} ₽/л)',
                          style: const TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 13),
                        ),
                        const SizedBox(height: 3),
                        Text('⛽ $st$geoTxt',
                            style: const TextStyle(
                                color: Color(0xFF38BDF8), fontSize: 11.5)),
                        const SizedBox(height: 2),
                        Text('${r['date']} | ${r['mode']} | $badge',
                            style: const TextStyle(
                                color: Color(0xFF94A3B8), fontSize: 11)),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline,
                        color: Color(0xFFEF4444)),
                    onPressed: () {
                      setState(
                          () => _refuelings.removeWhere((x) => x['id'] == r['id']));
                      _saveData();
                      _notify('Запись удалена');
                    },
                  ),
                ],
              ),
            ],
          );
        }),
      ],
    );
  }

  Widget _buildExpensesTab() {
    final categories = [
      '🔧 ТО и Запчасти',
      '🚿 Мойка',
      '📄 Страховка',
      '🅿️ Штрафы/Парковка',
      '📦 Прочее'
    ];

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        _buildCard(
          children: [
            const Text('Добавить расход на автомобиль',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: categories.map((c) {
                final isSel = _expCategory == c;
                return _buildBtn(
                  c,
                  () => setState(() => _expCategory = c),
                  bgColor:
                      isSel ? const Color(0xFF2563EB) : const Color(0xFF334155),
                );
              }).toList(),
            ),
            const SizedBox(height: 10),
            _buildTextField(_expCostCtrl, 'Сумма расхода (₽)', isNumber: true),
            const SizedBox(height: 10),
            _buildTextField(
                _expCommCtrl, 'Комментарий (напр. Замена колодок, ОСАГО)'),
            const SizedBox(height: 12),
            _buildBtn(
              'СОХРАНИТЬ РАСХОД',
              () {
                final cost = double.tryParse(
                    _expCostCtrl.text.trim().replaceAll(',', '.'));
                if (cost == null || cost <= 0) {
                  _notify('⚠️ Введите корректную сумму расхода!', isError: true);
                  return;
                }
                final comm = _expCommCtrl.text.trim().isNotEmpty
                    ? _expCommCtrl.text.trim()
                    : 'Без комментария';
                _expenses.add({
                  'id': DateTime.now().millisecondsSinceEpoch,
                  'car_id': _activeCarId,
                  'date': _nowStr(),
                  'category': _expCategory,
                  'cost': cost,
                  'comment': comm,
                });
                _expCostCtrl.clear();
                _expCommCtrl.clear();
                _saveData();
                setState(() {});
                _notify(
                    '✅ Расход ${cost.toStringAsFixed(0)} ₽ ($_expCategory) добавлен!');
              },
              bgColor: const Color(0xFF10B981),
            ),
          ],
        ),
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 6),
          child: Text('История расходов:',
              style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF94A3B8))),
        ),
        ..._carExpenses.map((ex) {
          final cost = (ex['cost'] as num).toDouble();
          return _buildCard(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('${ex['category']}: ${cost.toStringAsFixed(0)} ₽',
                            style: const TextStyle(
                                fontWeight: FontWeight.bold, fontSize: 13.5)),
                        const SizedBox(height: 3),
                        Text('${ex['date']} • ${ex['comment']}',
                            style: const TextStyle(
                                color: Color(0xFF94A3B8), fontSize: 11.5)),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline,
                        color: Color(0xFFEF4444)),
                    onPressed: () {
                      setState(
                          () => _expenses.removeWhere((x) => x['id'] == ex['id']));
                      _saveData();
                      _notify('Расход удален');
                    },
                  ),
                ],
              ),
            ],
          );
        }),
      ],
    );
  }

  Widget _buildStatsTab() {
    final refs = _carRefuelings;
    final exps = _carExpenses;
    final points = _calculateConsumptionPoints();

    final totalLiters =
        refs.fold<double>(0.0, (s, r) => s + (r['liters'] as num).toDouble());
    final totalFuelCost =
        refs.fold<double>(0.0, (s, r) => s + (r['cost'] as num).toDouble());
    final totalExtraCost =
        exps.fold<double>(0.0, (s, e) => s + (e['cost'] as num).toDouble());
    final grandTotal = totalFuelCost + totalExtraCost;

    int totalDist = 0;
    double avgCons = 0.0;
    double fuelKmCost = 0.0;
    double tcoKmCost = 0.0;

    if (refs.length >= 2 && points.isNotEmpty) {
      totalDist = (refs.last['odometer'] as num).toInt() -
          (refs.first['odometer'] as num).toInt();
      final sumLit =
          points.fold<double>(0.0, (s, p) => s + (p['liters'] as double));
      final sumDist =
          points.fold<int>(0, (s, p) => s + (p['distance'] as int));
      avgCons = sumDist > 0 ? (sumLit / sumDist) * 100.0 : 0.0;
      final firstCost = (refs.first['cost'] as num).toDouble();
      fuelKmCost =
          totalDist > 0 ? (totalFuelCost - firstCost) / totalDist : 0.0;
      tcoKmCost = totalDist > 0
          ? ((totalFuelCost - firstCost) + totalExtraCost) / totalDist
          : 0.0;
    }

    Widget statBox(String title, String val, Color col) {
      return Expanded(
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: const Color(0xFF1E293B),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style:
                      const TextStyle(fontSize: 12, color: Color(0xFF94A3B8))),
              const SizedBox(height: 4),
              Text(val,
                  style: TextStyle(
                      fontSize: 17, fontWeight: FontWeight.bold, color: col)),
            ],
          ),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Row(
          children: [
            statBox('Средний расход', '${avgCons.toStringAsFixed(2)} л/100км',
                const Color(0xFFF43F5E)),
            const SizedBox(width: 8),
            statBox('Пробег по базе', '${_fmtNum(totalDist)} км',
                const Color(0xFF38BDF8)),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            statBox('1 км (бензин)', '${fuelKmCost.toStringAsFixed(2)} ₽',
                const Color(0xFF10B981)),
            const SizedBox(width: 8),
            statBox('1 км (полная ТСО)', '${tcoKmCost.toStringAsFixed(2)} ₽',
                const Color(0xFFF59E0B)),
          ],
        ),
        const SizedBox(height: 12),
        _buildCard(
          children: [
            const Text('Сводка затрат',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Text(
                '• Затраты на топливо: ${_fmtNum(totalFuelCost)} ₽ (${totalLiters.toStringAsFixed(1)} л)'),
            const SizedBox(height: 4),
            Text('• Затраты на ТО, мойку и прочее: ${_fmtNum(totalExtraCost)} ₽'),
            const SizedBox(height: 6),
            Text('• ИТОГО ПОТРАЧЕНО: ${_fmtNum(grandTotal)} ₽',
                style: const TextStyle(
                    color: Color(0xFF10B981),
                    fontWeight: FontWeight.bold,
                    fontSize: 14)),
          ],
        ),
        _buildCard(
          children: [
            const Text('Динамика расхода и цен по АЗС',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
            if (points.isEmpty)
              const Text(
                  'Добавьте минимум 2 заправки до полного бака (или загрузите демо-данные).',
                  style: TextStyle(color: Color(0xFF64748B), fontSize: 12))
            else
              ...points.reversed.take(8).map((p) {
                final cons = p['consumption'] as double;
                final ratio = (cons / 16.0).clamp(0.0, 1.0);
                final priceL = p['price_per_liter'] as double;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Column(
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                              '${_fmtNum(p['odometer'] as int)} км (${p['mode']} • ${p['station']})',
                              style: const TextStyle(
                                  fontSize: 11.5, color: Color(0xFFCBD5E1))),
                          Text(
                              '${cons.toStringAsFixed(2)} л/100км (${priceL.toStringAsFixed(1)} ₽/л)',
                              style: const TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.bold,
                                  color: Color(0xFF38BDF8))),
                        ],
                      ),
                      const SizedBox(height: 4),
                      LinearProgressIndicator(
                        value: ratio,
                        backgroundColor: const Color(0xFF0F172A),
                        color: const Color(0xFF3B82F6),
                        minHeight: 8,
                      ),
                    ],
                  ),
                );
              }),
          ],
        ),
        _buildBtn(
          '📋 Скопировать CSV-отчет (для Excel) в буфер обмена',
          () {
            final sb = StringBuffer();
            sb.writeln(
                'ТИП;ДАТА;ПРОБЕГ;ЛИТРЫ;СУММА;ТОПЛИВО/КАТЕГОРИЯ;РЕЖИМ/КОММЕНТАРИЙ;АЗС;АДРЕС');
            for (final r in refs) {
              sb.writeln(
                  'Заправка;${r['date']};${r['odometer']};${r['liters']};${r['cost']};${r['fuel_type']};${r['mode']};${r['station_name']};${r['address']}');
            }
            for (final ex in exps) {
              sb.writeln(
                  'Расход;${ex['date']};;;${ex['cost']};${ex['category']};${ex['comment']};;');
            }
            Clipboard.setData(ClipboardData(text: sb.toString()));
            _notify('📥 CSV-отчет скопирован в буфер обмена!');
          },
          bgColor: const Color(0xFF334155),
        ),
      ],
    );
  }

  Widget _buildGarageTab() {
    final car = _activeCar;
    final interval = (car['service_interval'] as num).toInt();
    final lastSrvOdo = (car['last_service_odo'] as num).toInt();
    final currOdo = _currentOdometer;

    final passed = lastSrvOdo > 0 ? max(currOdo - lastSrvOdo, 0) : 0;
    final progress = (interval > 0 && lastSrvOdo > 0)
        ? (passed / interval).clamp(0.0, 1.0)
        : 0.0;

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        _buildCard(
          children: [
            Text('Контроль замены масла (${car['name']})',
                style:
                    const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Text(
                'Пройдено после ТО: ${_fmtNum(passed)} км из ${_fmtNum(interval)} км',
                style:
                    const TextStyle(fontSize: 13, color: Color(0xFFCBD5E1))),
            const SizedBox(height: 8),
            LinearProgressIndicator(
              value: progress,
              minHeight: 10,
              backgroundColor: const Color(0xFF0F172A),
              color: progress >= 0.9
                  ? const Color(0xFFEF4444)
                  : const Color(0xFF10B981),
            ),
            const SizedBox(height: 10),
            _buildBtn(
              'Я поменял масло сейчас (${_fmtNum(currOdo)} км)',
              () {
                if (currOdo == 0) {
                  _notify('⚠️ Сначала добавьте хотя бы одну заправку!',
                      isError: true);
                  return;
                }
                setState(() {
                  car['last_service_odo'] = currOdo;
                  _srvOdoCtrl.text = currOdo.toString();
                });
                _saveData();
                _notify('✅ Замена масла записана на пробеге $currOdo км!');
              },
              bgColor: const Color(0xFF10B981),
            ),
            const SizedBox(height: 10),
            _buildTextField(_srvOdoCtrl, 'Пробег последней замены (км)',
                isNumber: true),
            const SizedBox(height: 8),
            _buildTextField(_srvIntCtrl, 'Интервал замены (км)', isNumber: true),
            const SizedBox(height: 10),
            _buildBtn('Обновить параметры ТО', () {
              final sOdo = int.tryParse(_srvOdoCtrl.text.trim());
              final sInt = int.tryParse(_srvIntCtrl.text.trim());
              if (sOdo == null || sInt == null || sInt < 500) {
                _notify('⚠️ Введите корректный пробег и интервал!',
                    isError: true);
                return;
              }
              setState(() {
                car['last_service_odo'] = sOdo;
                car['service_interval'] = sInt;
              });
              _saveData();
              _notify('✅ Параметры ТО обновлены!');
            }),
          ],
        ),
        _buildCard(
          children: [
            const Text('Мои автомобили (Гараж)',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            ..._cars.map((c) {
              final cId = (c['id'] as num).toInt();
              final isAct = cId == _activeCarId;
              return Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: _buildBtn(
                  '${isAct ? "✓ " : ""}${c['name']} (ТО: ${c['service_interval']} км)',
                  () {
                    setState(() {
                      _activeCarId = cId;
                      _syncControllersWithState();
                    });
                    _saveData();
                    _notify('Автомобиль переключен');
                  },
                  bgColor:
                      isAct ? const Color(0xFF2563EB) : const Color(0xFF334155),
                ),
              );
            }),
            const Divider(color: Color(0xFF334155), height: 20),
            const Text('+ Добавить еще один автомобиль:',
                style: TextStyle(fontSize: 12.5, color: Color(0xFF94A3B8))),
            const SizedBox(height: 8),
            _buildTextField(_newCarNameCtrl, 'Название нового авто'),
            const SizedBox(height: 8),
            _buildTextField(_newCarIntCtrl, 'Интервал ТО в км', isNumber: true),
            const SizedBox(height: 10),
            _buildBtn(
              '+ Добавить авто в гараж',
              () {
                final name = _newCarNameCtrl.text.trim();
                if (name.isEmpty) {
                  _notify('⚠️ Введите название автомобиля!', isError: true);
                  return;
                }
                final cInt = int.tryParse(_newCarIntCtrl.text.trim()) ?? 10000;
                final newId = DateTime.now().millisecondsSinceEpoch;
                setState(() {
                  _cars.add({
                    'id': newId,
                    'name': name,
                    'service_interval': cInt,
                    'last_service_odo': 0,
                  });
                  _activeCarId = newId;
                  _newCarNameCtrl.clear();
                  _syncControllersWithState();
                });
                _saveData();
                _notify('🚘 Автомобиль «$name» добавлен и выбран!');
              },
              bgColor: const Color(0xFF334155),
            ),
          ],
        ),
        _buildCard(
          children: [
            const Text('☕ Поддержать проект и обновления',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            const Text(
                'Если приложение оказалось полезным, вы можете поддержать автора чаевыми:',
                style: TextStyle(fontSize: 12, color: Color(0xFF94A3B8))),
            const SizedBox(height: 8),
            _buildBtn(
              '☕ Задонатить разработчику',
              () async {
                final uri = Uri.parse(donateUrl);
                await launchUrl(uri, mode: LaunchMode.externalApplication);
              },
              bgColor: const Color(0xFF8B5CF6),
            ),
            const SizedBox(height: 8),
            _buildBtn(
              '🔄 Скачать свежую версию APK с GitHub',
              () async {
                final uri = Uri.parse(repoReleasesUrl);
                await launchUrl(uri, mode: LaunchMode.externalApplication);
              },
              bgColor: const Color(0xFF0EA5E9),
            ),
          ],
        ),
        _buildCard(
          children: [
            const Text('Тестирование и управление базой',
                style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF94A3B8))),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: _buildBtn(
                    '🎲 Демо-данные',
                    _loadDemoData,
                    bgColor: const Color(0xFF334155),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _buildBtn(
                    '🗑 Очистить базу',
                    () {
                      setState(() {
                        _refuelings.removeWhere(
                            (r) => (r['car_id'] as num).toInt() == _activeCarId);
                        _expenses.removeWhere(
                            (e) => (e['car_id'] as num).toInt() == _activeCarId);
                      });
                      _saveData();
                      _notify('История очищена');
                    },
                    bgColor: const Color(0xFF334155),
                    textColor: const Color(0xFFEF4444),
                  ),
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final car = _activeCar;
    final currOdo = _currentOdometer;
    final lastSrv = (car['last_service_odo'] as num).toInt();
    final interval = (car['service_interval'] as num).toInt();

    String badgeText = 'Интервал ТО не задан (см. Гараж/ТО)';
    Color badgeColor = const Color(0xFF94A3B8);

    if (lastSrv > 0) {
      final rem = (lastSrv + interval) - currOdo;
      if (rem <= 0) {
        badgeText = '🚨 Срок замены масла превышен на ${rem.abs()} км!';
        badgeColor = const Color(0xFFEF4444);
      } else if (rem <= 1000) {
        badgeText = '⚠️ Скоро замена масла: через $rem км';
        badgeColor = const Color(0xFFF59E0B);
      } else {
        badgeText = 'До замены масла: ${_fmtNum(rem)} км';
        badgeColor = const Color(0xFF10B981);
      }
    }

    final tabs = [
      _buildRefuelTab(),
      _buildExpensesTab(),
      _buildStatsTab(),
      _buildGarageTab(),
    ];

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
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${car['name']} (${_fmtNum(currOdo)} км)',
                          style: const TextStyle(
                              fontSize: 16.5, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 2),
                        Text(badgeText,
                            style: TextStyle(fontSize: 12, color: badgeColor)),
                      ],
                    ),
                  ),
                  _buildBtn('Сменить', () => setState(() => _tabIndex = 3),
                      bgColor: const Color(0xFF334155)),
                ],
              ),
            ),
            Expanded(child: tabs[_tabIndex]),
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
          BottomNavigationBarItem(
              icon: Icon(Icons.local_gas_station), label: 'Заправки'),
          BottomNavigationBarItem(
              icon: Icon(Icons.receipt_long), label: 'Расходы'),
          BottomNavigationBarItem(
              icon: Icon(Icons.bar_chart), label: 'Аналитика'),
          BottomNavigationBarItem(
              icon: Icon(Icons.build_circle_outlined), label: 'Гараж/ТО'),
        ],
      ),
    );
  }
}
