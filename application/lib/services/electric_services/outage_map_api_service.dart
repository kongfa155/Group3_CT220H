import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../../models/OutageItem.dart';

class OutageMapResult {
  final List<OutagePointGroup> wardSummaries;
  final List<OutageAreaFeature> roadAreas;
  final List<OutageAreaFeature> placeAreas;
  final List<OutagePointGroup> points;
  final String date;
  final DateTime lastUpdated;
  final bool fromCache;

  OutageMapResult({
    required this.wardSummaries,
    required this.roadAreas,
    required this.placeAreas,
    required this.points,
    required this.date,
    required this.lastUpdated,
    required this.fromCache,
  });
}

class OutageMapApiService {
  // Có thể trỏ bản debug vào backend local bằng:
  // flutter run --dart-define=API_BASE_URL=http://10.0.2.2:3000/api/outages
  // (Android emulator dùng 10.0.2.2 thay cho localhost).
  static const String baseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://group22-ct220h.onrender.com/api/outages',
  );
  static const String _cacheDataKey = 'outage_map_latest_data';
  static const String _cacheUpdatedAtKey = 'outage_map_latest_updated_at';

  static Future<OutageMapResult> getOutagesByWard({String? date}) async {
    final uri = Uri.parse(
      '$baseUrl/by-ward',
    ).replace(queryParameters: date != null ? {'date': date} : null);

    try {
      final response = await http.get(uri).timeout(const Duration(seconds: 15));

      if (response.statusCode != 200) {
        throw Exception('Máy chủ trả về lỗi ${response.statusCode}');
      }

      final updatedAt = DateTime.now();
      final responseData = jsonDecode(response.body) as Map<String, dynamic>;
      //Encode lấy dữ liệu cần thiết, bỏ bớt mấy cái nặng
      final lightweightCache = jsonEncode({
        'date': responseData['date'],
        'wardSummaries': responseData['wardSummaries'] ?? [],
      });
      //Lưu dữ liệu bằng thư viện sharePreferences để xài offline
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(_cacheDataKey, lightweightCache);
      //Lưu dữ liệu theo dạng key : value vào file của máy
      await preferences.setString(
        _cacheUpdatedAtKey,
        updatedAt.toIso8601String(),
      );

      return _parseResult(
        response.body,
        lastUpdated: updatedAt,
        fromCache: false,
      );
    } catch (_) {
      final cachedResult = await _readCache();
      if (cachedResult != null) return cachedResult;
      rethrow;
    }
  }

  static Future<OutageMapResult?> _readCache() async {
    //Đọc dữ liệu ra
    final preferences = await SharedPreferences.getInstance();
    final cachedData = preferences.getString(_cacheDataKey);
    if (cachedData == null) return null;

    final updatedAtText = preferences.getString(_cacheUpdatedAtKey);
    final updatedAt = DateTime.tryParse(updatedAtText ?? '') ?? DateTime.now();
    try {
      return _parseResult(cachedData, lastUpdated: updatedAt, fromCache: true);
    } catch (_) {
      await preferences.remove(_cacheDataKey);
      await preferences.remove(_cacheUpdatedAtKey);
      return null;
    }
  }

  static OutageMapResult _parseResult(
    String responseBody, {
    required DateTime lastUpdated,
    required bool fromCache,
  }) {
    final data = jsonDecode(responseBody) as Map<String, dynamic>;

    List<T> parseList<T>(
      String key,
      T Function(Map<String, dynamic>) fromJson,
    ) {
      final list = data[key] as List? ?? [];
      return list.map((e) => fromJson(e as Map<String, dynamic>)).toList();
    }

    return OutageMapResult(
      wardSummaries: parseList('wardSummaries', OutagePointGroup.fromJson),
      roadAreas: parseList('roadAreas', OutageAreaFeature.fromJson),
      placeAreas: parseList('placeAreas', OutageAreaFeature.fromJson),
      points: parseList('points', OutagePointGroup.fromJson),
      date: data['date']?.toString() ?? '',
      lastUpdated: lastUpdated,
      fromCache: fromCache,
    );
  }
}
