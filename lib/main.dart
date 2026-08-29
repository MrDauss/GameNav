import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:maplibre_gl/maplibre_gl.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const GameNavApp());
}

class GameNavApp extends StatelessWidget {
  const GameNavApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'GameNav',
      theme: ThemeData.dark(useMaterial3: true),
      home: const MapScreen(),
    );
  }
}

class SearchResult {
  final String name;
  final double lat;
  final double lon;

  const SearchResult(this.name, this.lat, this.lon);
}

class RouteResult {
  final List<LatLng> geometry;
  final double distanceMeters;
  final double durationSeconds;

  const RouteResult(
    this.geometry,
    this.distanceMeters,
    this.durationSeconds,
  );
}

class GameThemeSpec {
  final String id;
  final String name;
  final String tagline;
  final String mapStyle;
  final Color accent;
  final Color panel;
  final Color foreground;
  final String routeColor;
  final IconData icon;

  const GameThemeSpec({
    required this.id,
    required this.name,
    required this.tagline,
    required this.mapStyle,
    required this.accent,
    required this.panel,
    required this.foreground,
    required this.routeColor,
    required this.icon,
  });
}

const gameThemes = <GameThemeSpec>[
  GameThemeSpec(
    id: 'crime_city',
    name: 'Crime City',
    tagline: 'עיר פתוחה • בהשראת משחקי פשע אורבניים',
    mapStyle: 'https://tiles.openfreemap.org/styles/liberty',
    accent: Color(0xFFE45AAE),
    panel: Color(0xE8121018),
    foreground: Colors.white,
    routeColor: '#E45AAE',
    icon: Icons.location_city,
  ),
  GameThemeSpec(
    id: 'frontier',
    name: 'Frontier Trails',
    tagline: 'מערב פרוע • בהשראת משחקי Frontier',
    mapStyle: 'https://tiles.openfreemap.org/styles/fiord',
    accent: Color(0xFFD59A55),
    panel: Color(0xE81E1610),
    foreground: Color(0xFFFFF1D0),
    routeColor: '#D59A55',
    icon: Icons.landscape,
  ),
  GameThemeSpec(
    id: 'neon_coast',
    name: 'Neon Coast',
    tagline: 'לילה • ניאון • שנות ה־80',
    mapStyle: 'https://tiles.openfreemap.org/styles/dark',
    accent: Color(0xFFFF4FD8),
    panel: Color(0xEB10091C),
    foreground: Color(0xFFF7F2FF),
    routeColor: '#FF4FD8',
    icon: Icons.nightlife,
  ),
  GameThemeSpec(
    id: 'cyber_grid',
    name: 'Cyber Grid',
    tagline: 'עתידני • HUD דיגיטלי',
    mapStyle: 'https://tiles.openfreemap.org/styles/dark',
    accent: Color(0xFF37F6D1),
    panel: Color(0xE8061718),
    foreground: Color(0xFFE8FFF9),
    routeColor: '#37F6D1',
    icon: Icons.memory,
  ),
  GameThemeSpec(
    id: 'midnight',
    name: 'Midnight Run',
    tagline: 'נהיגה לילית • מינימליסטי',
    mapStyle: 'https://tiles.openfreemap.org/styles/dark',
    accent: Color(0xFF9D8CFF),
    panel: Color(0xEC111118),
    foreground: Colors.white,
    routeColor: '#9D8CFF',
    icon: Icons.dark_mode,
  ),
  GameThemeSpec(
    id: 'classic',
    name: 'Classic Navigator',
    tagline: 'מפה בהירה וברורה',
    mapStyle: 'https://tiles.openfreemap.org/styles/positron',
    accent: Color(0xFF3F72FF),
    panel: Color(0xEE10131A),
    foreground: Colors.white,
    routeColor: '#3F72FF',
    icon: Icons.map,
  ),
];

class CommunityReport {
  final String type;
  final DateTime createdAt;

  CommunityReport(this.type) : createdAt = DateTime.now();
}

class OpenMapServices {
  static const _userAgent =
      'GameNav/0.4 (https://github.com/MrDauss/GameNav)';

  static Future<List<SearchResult>> search(
    String query, {
    Position? bias,
  }) async {
    Object? photonError;

    try {
      final params = <String, String>{
        'q': query,
        'limit': '7',
        'lang': 'he',
        'countrycode': 'IL',
      };

      if (bias != null) {
        params['lat'] = bias.latitude.toString();
        params['lon'] = bias.longitude.toString();
        params['zoom'] = '11';
      }

      final uri = Uri.https('photon.komoot.io', '/api/', params);
      final response = await http
          .get(
            uri,
            headers: {
              'User-Agent': _userAgent,
              'Accept': 'application/json',
              'Accept-Language': 'he,en;q=0.8',
            },
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final decoded = jsonDecode(response.body) as Map<String, dynamic>;
        final features = decoded['features'] as List<dynamic>? ?? const [];
        final results = <SearchResult>[];

        for (final raw in features) {
          final feature = raw as Map<String, dynamic>;
          final geometry = feature['geometry'] as Map<String, dynamic>?;
          final properties = feature['properties'] as Map<String, dynamic>?;
          final coordinates = geometry?['coordinates'] as List<dynamic>?;
          if (coordinates == null || coordinates.length < 2) continue;

          final lon = (coordinates[0] as num).toDouble();
          final lat = (coordinates[1] as num).toDouble();
          final name = _photonLabel(properties ?? const {});
          results.add(SearchResult(name, lat, lon));
        }

        if (results.isNotEmpty) return results;
      } else {
        photonError = 'Photon HTTP ${response.statusCode}';
      }
    } catch (e) {
      photonError = e;
    }

    try {
      final uri = Uri.https('nominatim.openstreetmap.org', '/search', {
        'q': query,
        'format': 'jsonv2',
        'addressdetails': '1',
        'limit': '7',
        'countrycodes': 'il',
        'accept-language': 'he,en',
      });

      final response = await http
          .get(
            uri,
            headers: {
              'User-Agent': _userAgent,
              'Accept': 'application/json',
              'Accept-Language': 'he,en;q=0.8',
            },
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) {
        throw Exception('Nominatim HTTP ${response.statusCode}');
      }

      final data = jsonDecode(response.body) as List<dynamic>;
      final results = data.map((e) {
        final m = e as Map<String, dynamic>;
        return SearchResult(
          m['display_name']?.toString() ?? 'יעד',
          double.parse(m['lat'].toString()),
          double.parse(m['lon'].toString()),
        );
      }).toList();

      if (results.isNotEmpty) return results;
    } catch (e) {
      throw Exception('Search providers failed: $photonError / $e');
    }

    return const [];
  }

  static String _photonLabel(Map<String, dynamic> p) {
    final parts = <String>[];
    for (final key in ['name', 'street', 'housenumber', 'district', 'city']) {
      final value = p[key]?.toString().trim();
      if (value != null && value.isNotEmpty && !parts.contains(value)) {
        parts.add(value);
      }
    }
    if (parts.isEmpty) return 'יעד';
    return parts.join(', ');
  }

  static Future<List<RouteResult>> routes(LatLng from, LatLng to) async {
    final path =
        '/route/v1/driving/${from.longitude},${from.latitude};${to.longitude},${to.latitude}';
    final uri = Uri.https('router.project-osrm.org', path, {
      'overview': 'full',
      'geometries': 'geojson',
      'alternatives': 'true',
      'steps': 'true',
    });

    final response = await http
        .get(uri, headers: {'User-Agent': _userAgent})
        .timeout(const Duration(seconds: 15));

    if (response.statusCode != 200) {
      throw Exception('Routing HTTP ${response.statusCode}');
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final routes = data['routes'] as List<dynamic>? ?? const [];
    if (routes.isEmpty) throw Exception('No route');

    return routes.map((raw) {
      final route = raw as Map<String, dynamic>;
      final geometry = route['geometry'] as Map<String, dynamic>;
      final coordinates = geometry['coordinates'] as List<dynamic>;
      final points = coordinates.map((c) {
        final p = c as List<dynamic>;
        return LatLng(
          (p[1] as num).toDouble(),
          (p[0] as num).toDouble(),
        );
      }).toList();

      return RouteResult(
        points,
        (route['distance'] as num).toDouble(),
        (route['duration'] as num).toDouble(),
      );
    }).toList();
  }
}

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  final _searchController = TextEditingController();
  MapLibreMapController? _map;
  StreamSubscription<Position>? _positionSub;
  Symbol? _vehicle;
  Line? _routeLine;
  Position? _lastPosition;
  SearchResult? _destination;
  List<RouteResult> _routeOptions = const [];
  int _selectedRouteIndex = 0;
  bool _styleReady = false;
  bool _following = true;
  bool _programmaticCameraMove = false;
  bool _busy = false;
  bool _rerouting = false;
  int _offRouteSamples = 0;
  DateTime? _lastRerouteAt;
  String? _gpsIssue;
  GameThemeSpec _theme = gameThemes.first;
  final List<CommunityReport> _reports = [];

  bool avoidTraffic = true;
  bool avoidClosures = true;
  bool avoidRoadworks = false;
  bool avoidHazards = false;
  bool avoidTolls = false;
  bool avoidUnpaved = false;
  bool preferMainRoads = false;
  bool preferQuietRoads = false;

  RouteResult? get _route =>
      _routeOptions.isEmpty ? null : _routeOptions[_selectedRouteIndex];

  @override
  void initState() {
    super.initState();
    _startLocation();
  }

  @override
  void dispose() {
    _positionSub?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _startLocation() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      if (mounted) setState(() => _gpsIssue = 'יש להפעיל שירותי מיקום');
      return;
    }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      if (mounted) setState(() => _gpsIssue = 'אין הרשאת GPS');
      return;
    }

    const settings = LocationSettings(
      accuracy: LocationAccuracy.bestForNavigation,
      distanceFilter: 3,
    );

    _positionSub = Geolocator.getPositionStream(locationSettings: settings)
        .listen(_onPosition);

    try {
      await _onPosition(
        await Geolocator.getCurrentPosition(locationSettings: settings),
      );
    } catch (_) {}
  }

  Future<void> _onPosition(Position p) async {
    _lastPosition = p;

    if (mounted && _gpsIssue != null) {
      setState(() => _gpsIssue = null);
    }

    final map = _map;
    if (map == null || !_styleReady) return;

    final point = LatLng(p.latitude, p.longitude);
    final heading = p.heading.isFinite && p.heading >= 0 ? p.heading : 0.0;

    if (_vehicle == null) {
      _vehicle = await map.addSymbol(
        SymbolOptions(
          geometry: point,
          iconImage: 'vehicle-marker',
          iconSize: 0.48,
          iconRotate: heading,
          iconAnchor: 'center',
        ),
      );
    } else {
      await map.updateSymbol(
        _vehicle!,
        SymbolOptions(geometry: point, iconRotate: heading),
      );
    }

    // Check whether the driver has actually left the selected route.
    // We require several consecutive off-route samples so GPS noise does not
    // trigger a reroute while driving normally.
    unawaited(_maybeReroute(p));

    if (_following) {
      final speedKmh = (p.speed.isFinite ? p.speed : 0) * 3.6;
      // Keep navigation visually close to the vehicle. City driving is
      // intentionally tighter; highways zoom out only enough to show the
      // next stretch of road without making the car feel tiny.
      final zoom = speedKmh > 90
          ? 17.0
          : speedKmh > 60
              ? 17.5
              : speedKmh > 35
                  ? 18.0
                  : 18.5;
      final tilt = speedKmh > 35 ? 58.0 : 52.0;
      final lookAheadMeters = speedKmh > 90
          ? 90.0
          : speedKmh > 60
              ? 70.0
              : speedKmh > 35
                  ? 45.0
                  : 25.0;
      final cameraTarget = _pointAhead(point, heading, lookAheadMeters);
      await _animateCamera(
        CameraUpdate.newCameraPosition(
          CameraPosition(
            target: cameraTarget,
            zoom: zoom,
            bearing: heading,
            tilt: tilt,
          ),
        ),
      );
    }
  }

  LatLng _pointAhead(LatLng from, double bearingDegrees, double meters) {
    if (!bearingDegrees.isFinite || meters <= 0) return from;

    const earthRadius = 6371000.0;
    final angularDistance = meters / earthRadius;
    final bearing = bearingDegrees * math.pi / 180.0;
    final lat1 = from.latitude * math.pi / 180.0;
    final lon1 = from.longitude * math.pi / 180.0;

    final lat2 = math.asin(
      math.sin(lat1) * math.cos(angularDistance) +
          math.cos(lat1) * math.sin(angularDistance) * math.cos(bearing),
    );
    final lon2 = lon1 +
        math.atan2(
          math.sin(bearing) * math.sin(angularDistance) * math.cos(lat1),
          math.cos(angularDistance) - math.sin(lat1) * math.sin(lat2),
        );

    return LatLng(lat2 * 180.0 / math.pi, lon2 * 180.0 / math.pi);
  }

  Future<void> _animateCamera(CameraUpdate update) async {
    final map = _map;
    if (map == null) return;

    _programmaticCameraMove = true;
    try {
      await map.animateCamera(update);
    } finally {
      // Give MapLibre's final camera callback a moment to arrive before we
      // treat subsequent moves as a user gesture.
      await Future<void>.delayed(const Duration(milliseconds: 120));
      _programmaticCameraMove = false;
    }
  }

  void _handleCameraMove(CameraPosition _) {
    if (!mounted || _programmaticCameraMove || !_following) return;
    setState(() => _following = false);
  }

  double _distanceToRouteMeters(LatLng point, List<LatLng> geometry) {
    if (geometry.isEmpty) return double.infinity;
    if (geometry.length == 1) {
      return Geolocator.distanceBetween(
        point.latitude,
        point.longitude,
        geometry.first.latitude,
        geometry.first.longitude,
      );
    }

    const earthRadius = 6371000.0;
    final lat0 = point.latitude * math.pi / 180.0;
    final cosLat = math.cos(lat0);

    (double, double) xy(LatLng p) {
      final x = (p.longitude - point.longitude) *
          math.pi / 180.0 * earthRadius * cosLat;
      final y = (p.latitude - point.latitude) *
          math.pi / 180.0 * earthRadius;
      return (x, y);
    }

    var best = double.infinity;
    for (var i = 0; i < geometry.length - 1; i++) {
      final a = xy(geometry[i]);
      final b = xy(geometry[i + 1]);
      final dx = b.$1 - a.$1;
      final dy = b.$2 - a.$2;
      final len2 = dx * dx + dy * dy;

      double t;
      if (len2 <= 0.0001) {
        t = 0;
      } else {
        // Projection of the origin (the live GPS position) onto segment AB.
        t = (-(a.$1 * dx + a.$2 * dy) / len2).clamp(0.0, 1.0).toDouble();
      }

      final nearestX = a.$1 + t * dx;
      final nearestY = a.$2 + t * dy;
      final d = math.sqrt(nearestX * nearestX + nearestY * nearestY);
      if (d < best) best = d;
    }
    return best;
  }

  Future<void> _maybeReroute(Position p) async {
    final route = _route;
    final destination = _destination;
    if (route == null || destination == null || _rerouting) return;

    // Very inaccurate fixes are ignored so a bad GPS sample cannot cause a
    // false reroute.
    if (!p.accuracy.isFinite || p.accuracy > 80) return;

    final distanceToDestination = Geolocator.distanceBetween(
      p.latitude,
      p.longitude,
      destination.lat,
      destination.lon,
    );
    if (distanceToDestination < 60) {
      _offRouteSamples = 0;
      return;
    }

    final distance = _distanceToRouteMeters(
      LatLng(p.latitude, p.longitude),
      route.geometry,
    );
    final threshold = math.max(35.0, p.accuracy * 1.8);

    if (distance > threshold) {
      _offRouteSamples++;
    } else if (distance < threshold * 0.65) {
      _offRouteSamples = 0;
    }

    if (_offRouteSamples < 3) return;

    final now = DateTime.now();
    if (_lastRerouteAt != null &&
        now.difference(_lastRerouteAt!) < const Duration(seconds: 10)) {
      return;
    }

    _offRouteSamples = 0;
    _lastRerouteAt = now;
    if (mounted) {
      setState(() => _rerouting = true);
    } else {
      _rerouting = true;
    }

    try {
      final routes = await OpenMapServices.routes(
        LatLng(p.latitude, p.longitude),
        LatLng(destination.lat, destination.lon),
      );
      if (!mounted || routes.isEmpty) return;

      setState(() {
        _routeOptions = routes;
        _selectedRouteIndex = 0;
        _following = true;
      });
      await _redrawRoute();

      // Return immediately to navigation view instead of showing another
      // high route overview every time the driver misses a turn.
      if (_lastPosition != null) {
        await _onPosition(_lastPosition!);
      }
      _message('המסלול עודכן לפי המיקום החדש');
    } catch (_) {
      // Keep the old route on screen and retry after new GPS samples.
      _message('לא הצלחתי לחשב מסלול מחדש כרגע');
    } finally {
      if (mounted) {
        setState(() => _rerouting = false);
      } else {
        _rerouting = false;
      }
    }
  }

  Future<void> _onStyleLoaded() async {
    _styleReady = true;
    final bytes = await rootBundle.load('assets/icons/vehicle.png');
    await _map?.addImage(
      'vehicle-marker',
      bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
    );
    await _redrawRoute();
    if (_lastPosition != null) await _onPosition(_lastPosition!);
  }

  Future<void> _redrawRoute() async {
    final map = _map;
    final route = _route;
    if (map == null || !_styleReady || route == null) return;

    if (_routeLine != null) {
      try {
        await map.removeLine(_routeLine!);
      } catch (_) {}
      _routeLine = null;
    }

    _routeLine = await map.addLine(
      LineOptions(
        geometry: route.geometry,
        lineColor: _theme.routeColor,
        lineWidth: 7,
        lineOpacity: 0.94,
        lineJoin: 'round',
      ),
    );
  }

  Future<void> _searchDestination() async {
    final query = _searchController.text.trim();
    if (query.isEmpty || _busy) return;

    FocusScope.of(context).unfocus();
    setState(() => _busy = true);

    try {
      final results = await OpenMapServices.search(query, bias: _lastPosition);
      if (!mounted) return;

      if (results.isEmpty) {
        _message('לא נמצא יעד. נסה להוסיף עיר או רחוב.');
        return;
      }

      final chosen = await showModalBottomSheet<SearchResult>(
        context: context,
        showDragHandle: true,
        backgroundColor: _theme.panel,
        builder: (context) => Directionality(
          textDirection: TextDirection.rtl,
          child: SafeArea(
            child: ListView(
              shrinkWrap: true,
              children: [
                ListTile(
                  leading: Icon(Icons.search, color: _theme.accent),
                  title: const Text(
                    'תוצאות חיפוש',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                ...results.map(
                  (r) => ListTile(
                    leading: Icon(Icons.place, color: _theme.accent),
                    title: Text(
                      r.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: () => Navigator.pop(context, r),
                  ),
                ),
              ],
            ),
          ),
        ),
      );

      if (chosen != null) await _buildRoutes(chosen);
    } on TimeoutException {
      _message('שירות החיפוש לא הגיב בזמן. נסה שוב.');
    } catch (_) {
      _message('לא ניתן להתחבר לשירות החיפוש כרגע.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _buildRoutes(SearchResult destination) async {
    final p = _lastPosition;
    final map = _map;
    if (p == null || map == null || !_styleReady) {
      _message('עדיין אין מיקום GPS מדויק.');
      return;
    }

    setState(() => _busy = true);

    try {
      final routes = await OpenMapServices.routes(
        LatLng(p.latitude, p.longitude),
        LatLng(destination.lat, destination.lon),
      );

      setState(() {
        _destination = destination;
        _routeOptions = routes;
        _selectedRouteIndex = 0;
        _following = false;
        _offRouteSamples = 0;
      });

      await _redrawRoute();

      // Enter navigation view immediately. The full-route overview was
      // intentionally removed because it made the live view feel distant
      // and forced the driver to wait before the camera followed the car.
      if (mounted && identical(_destination, destination)) {
        setState(() => _following = true);
        if (_lastPosition != null) await _onPosition(_lastPosition!);
      }
    } on TimeoutException {
      _message('חישוב המסלול ארך יותר מדי זמן. נסה שוב.');
    } catch (_) {
      _message('לא ניתן לחשב מסלול כרגע.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _selectRoute(int index) async {
    if (index < 0 || index >= _routeOptions.length) return;
    setState(() {
      _selectedRouteIndex = index;
      _following = false;
      _offRouteSamples = 0;
    });
    await _redrawRoute();
    if (!mounted) return;
    setState(() => _following = true);
    if (_lastPosition != null) await _onPosition(_lastPosition!);
  }

  void _changeTheme(GameThemeSpec theme) {
    if (theme.id == _theme.id) return;
    setState(() {
      _theme = theme;
      _styleReady = false;
      _map = null;
      _vehicle = null;
      _routeLine = null;
    });
    Navigator.pop(context);
  }

  void _showThemeSheet() {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      backgroundColor: _theme.panel,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.62,
        minChildSize: 0.35,
        maxChildSize: 0.92,
        builder: (context, scrollController) => Directionality(
          textDirection: TextDirection.rtl,
          child: SafeArea(
            child: ListView(
              controller: scrollController,
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 24),
              children: [
                const Text(
                  'Game Themes',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900),
                ),
                const SizedBox(height: 4),
                const Text(
                  'גלול למעלה ולמטה ובחר את עולם המשחק של הניווט.',
                ),
                const SizedBox(height: 14),
                ...gameThemes.map(
                  (theme) => Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: ListTile(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                        side: BorderSide(
                          color: theme.id == _theme.id
                              ? theme.accent
                              : Colors.white12,
                        ),
                      ),
                      tileColor: theme.panel,
                      leading: CircleAvatar(
                        backgroundColor: theme.accent,
                        foregroundColor: Colors.black,
                        child: Icon(theme.icon),
                      ),
                      title: Text(
                        theme.name,
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      subtitle: Text(theme.tagline),
                      trailing: theme.id == _theme.id
                          ? Icon(Icons.check_circle, color: theme.accent)
                          : const Icon(Icons.chevron_left),
                      onTap: () => _changeTheme(theme),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showReportSheet() {
    const reports = <(IconData, String)>[
      (Icons.traffic, 'פקק'),
      (Icons.block, 'חסימת כביש'),
      (Icons.car_crash, 'תאונה'),
      (Icons.construction, 'עבודות בדרך'),
      (Icons.warning_amber_rounded, 'מפגע בכביש'),
      (Icons.car_repair, 'רכב תקוע'),
      (Icons.water, 'הצפה'),
      (Icons.traffic_outlined, 'רמזור תקול'),
      (Icons.shield_outlined, 'פעילות אכיפה באזור'),
    ];

    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      backgroundColor: _theme.panel,
      builder: (context) => Directionality(
        textDirection: TextDirection.rtl,
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(Icons.campaign, color: _theme.accent),
                    const SizedBox(width: 8),
                    const Text(
                      'דיווח בדרך',
                      style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: reports
                      .map(
                        (r) => ActionChip(
                          avatar: Icon(r.$1, size: 20, color: _theme.accent),
                          label: Text(r.$2),
                          onPressed: () {
                            setState(() => _reports.add(CommunityReport(r.$2)));
                            Navigator.pop(context);
                            _message('דיווח “${r.$2}” נשמר בגרסת הניסוי.');
                          },
                        ),
                      )
                      .toList(),
                ),
                const SizedBox(height: 14),
                Text(
                  'דיווחים שנוספו במכשיר: ${_reports.length}. בגרסת השרת נוסיף אימות “עדיין שם / כבר לא”, תפוגה אוטומטית וניקוד אמינות.',
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showAvoidanceSheet() {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      backgroundColor: _theme.panel,
      builder: (context) => StatefulBuilder(
        builder: (context, modalSetState) => Directionality(
          textDirection: TextDirection.rtl,
          child: SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ListTile(
                    leading: Icon(Icons.alt_route, color: _theme.accent),
                    title: const Text(
                      'הימנעות והעדפות מסלול',
                      style: TextStyle(fontSize: 21, fontWeight: FontWeight.bold),
                    ),
                    subtitle: const Text(
                      'ההעדפות נשמרות באפליקציה; שילוב מלא בחישוב המסלול יגיע עם מנוע GameNav backend.',
                    ),
                  ),
                  _avoidSwitch('הימנע מפקקים', avoidTraffic, (v) {
                    modalSetState(() => avoidTraffic = v);
                    setState(() => avoidTraffic = v);
                  }),
                  _avoidSwitch('הימנע מחסימות', avoidClosures, (v) {
                    modalSetState(() => avoidClosures = v);
                    setState(() => avoidClosures = v);
                  }),
                  _avoidSwitch('הימנע מעבודות בדרך', avoidRoadworks, (v) {
                    modalSetState(() => avoidRoadworks = v);
                    setState(() => avoidRoadworks = v);
                  }),
                  _avoidSwitch('הימנע ממפגעים', avoidHazards, (v) {
                    modalSetState(() => avoidHazards = v);
                    setState(() => avoidHazards = v);
                  }),
                  _avoidSwitch('הימנע מכבישי אגרה', avoidTolls, (v) {
                    modalSetState(() => avoidTolls = v);
                    setState(() => avoidTolls = v);
                  }),
                  _avoidSwitch('הימנע מכבישים לא סלולים', avoidUnpaved, (v) {
                    modalSetState(() => avoidUnpaved = v);
                    setState(() => avoidUnpaved = v);
                  }),
                  const Divider(),
                  _avoidSwitch('העדף כבישים ראשיים', preferMainRoads, (v) {
                    modalSetState(() => preferMainRoads = v);
                    setState(() => preferMainRoads = v);
                  }),
                  _avoidSwitch('העדף מסלול רגוע', preferQuietRoads, (v) {
                    modalSetState(() => preferQuietRoads = v);
                    setState(() => preferQuietRoads = v);
                  }),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _avoidSwitch(
    String title,
    bool value,
    ValueChanged<bool> onChanged,
  ) {
    return SwitchListTile(
      activeThumbColor: _theme.accent,
      title: Text(title),
      value: value,
      onChanged: onChanged,
    );
  }

  String _routeSummary(RouteResult route) {
    final km = route.distanceMeters / 1000;
    final min = (route.durationSeconds / 60).round();
    return '${km.toStringAsFixed(1)} ק״מ • $min דקות';
  }

  void _message(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text),
        backgroundColor: _theme.panel,
      ),
    );
  }

  Widget _routeAlternatives() {
    if (_routeOptions.length <= 1) return const SizedBox.shrink();
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: List.generate(_routeOptions.length, (index) {
          final selected = index == _selectedRouteIndex;
          return Padding(
            padding: const EdgeInsets.only(left: 8),
            child: ChoiceChip(
              selected: selected,
              selectedColor: _theme.accent,
              labelStyle: TextStyle(
                color: selected ? Colors.black : Colors.white,
                fontWeight: FontWeight.bold,
              ),
              label: Text('מסלול ${index + 1} • ${_routeSummary(_routeOptions[index])}'),
              onSelected: (_) => _selectRoute(index),
            ),
          );
        }),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final initialTarget = _lastPosition == null
        ? const LatLng(31.9, 34.8)
        : LatLng(_lastPosition!.latitude, _lastPosition!.longitude);

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            MapLibreMap(
              key: ValueKey(_theme.id),
              styleString: _theme.mapStyle,
              initialCameraPosition: CameraPosition(
                target: initialTarget,
                zoom: _lastPosition == null ? 9 : 16,
              ),
              onMapCreated: (c) => _map = c,
              onStyleLoadedCallback: _onStyleLoaded,
              onCameraMove: _handleCameraMove,
            ),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  children: [
                    Material(
                      color: _theme.panel,
                      elevation: 10,
                      borderRadius: BorderRadius.circular(22),
                      child: TextField(
                        controller: _searchController,
                        textInputAction: TextInputAction.search,
                        onSubmitted: (_) => _searchDestination(),
                        style: TextStyle(color: _theme.foreground),
                        decoration: InputDecoration(
                          hintText: 'לאן נוסעים?',
                          hintStyle: TextStyle(
                            color: _theme.foreground.withValues(alpha: 0.65),
                          ),
                          prefixIcon: Icon(Icons.search, color: _theme.accent),
                          suffixIcon: _busy
                              ? Padding(
                                  padding: const EdgeInsets.all(14),
                                  child: SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: _theme.accent,
                                    ),
                                  ),
                                )
                              : IconButton(
                                  icon: Icon(Icons.arrow_back, color: _theme.accent),
                                  onPressed: _searchDestination,
                                ),
                          border: InputBorder.none,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 16,
                          ),
                        ),
                      ),
                    ),
                    if (_gpsIssue != null) ...[
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.center,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: _theme.panel,
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 7,
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.gps_off,
                                  size: 16,
                                  color: _theme.accent,
                                ),
                                const SizedBox(width: 8),
                                Text(_gpsIssue!),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                    if (_rerouting) ...[
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.center,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: _theme.panel,
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 7,
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: _theme.accent,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                const Text('מחשב מסלול מחדש…'),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                    if (_destination != null) ...[
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: _theme.panel,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.flag, color: _theme.accent),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                _destination!.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 6),
                      _routeAlternatives(),
                    ],
                    const Spacer(),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Column(
                          children: [
                            FloatingActionButton.small(
                              heroTag: 'themes',
                              backgroundColor: _theme.panel,
                              foregroundColor: _theme.accent,
                              onPressed: _showThemeSheet,
                              child: const Icon(Icons.palette),
                            ),
                            const SizedBox(height: 10),
                            FloatingActionButton.small(
                              heroTag: 'avoid',
                              backgroundColor: _theme.panel,
                              foregroundColor: _theme.accent,
                              onPressed: _showAvoidanceSheet,
                              child: const Icon(Icons.tune),
                            ),
                            const SizedBox(height: 10),
                            FloatingActionButton.small(
                              heroTag: 'follow',
                              backgroundColor: _theme.panel,
                              foregroundColor: _theme.accent,
                              onPressed: () {
                                setState(() => _following = true);
                                if (_lastPosition != null) {
                                  _onPosition(_lastPosition!);
                                }
                              },
                              child: const Icon(Icons.my_location),
                            ),
                          ],
                        ),
                        const Spacer(),
                        FloatingActionButton.extended(
                          heroTag: 'report',
                          backgroundColor: _theme.accent,
                          foregroundColor: Colors.black,
                          onPressed: _showReportSheet,
                          icon: const Icon(Icons.campaign),
                          label: const Text(
                            'דיווח',
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
