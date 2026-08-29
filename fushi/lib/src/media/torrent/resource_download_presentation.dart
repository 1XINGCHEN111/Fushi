import 'package:fushi/src/media/torrent/torrent_metainfo.dart';
import 'package:fushi/src/media/video/jimaku_client.dart';
import 'package:fushi/src/media/video/scraper/filename_parser.dart';
import 'package:fushi/src/media/video/scraper/scraper_types.dart';
import 'package:fushi/src/media/video/video_filename_parser.dart';

/// 原“动画与字幕下载”项目使用的 Jimaku 一级版本组。
class ResourceJimakuCategory {
  const ResourceJimakuCategory({
    required this.key,
    required this.name,
    required this.files,
    required this.variants,
  });

  final String key;
  final String name;
  final List<JimakuFile> files;
  final List<ResourceJimakuVariant> variants;
}

/// Jimaku 一级版本组内按格式、语言细分的可选版本。
class ResourceJimakuVariant {
  const ResourceJimakuVariant({
    required this.key,
    required this.name,
    required this.files,
  });

  final String key;
  final String name;
  final List<JimakuFile> files;
}

/// Nyaa torrent 第一层/第二层中的一个可独立选择的视频文件夹。
class ResourceTorrentVideoFolder {
  const ResourceTorrentVideoFolder({
    required this.key,
    required this.name,
    required this.files,
    required this.mediaType,
    this.season,
  });

  final String key;
  final String name;
  final List<TorrentMetainfoFile> files;
  final String mediaType;
  final int? season;

  String get annotatedName => switch (mediaType) {
    'TV' when season != null => '[TV 第$season季] $name',
    'TV' => '[TV] $name',
    'OVA' => '[OVA] $name',
    '剧场版' => '[剧场版] $name',
    _ => '[其他] $name',
  };

  String get typeSeasonLabel => switch (mediaType) {
    'TV' when season != null => '类型：TV  ·  季度：第 $season 季',
    'TV' => '类型：TV  ·  季度：季度未识别',
    _ => '类型：$mediaType',
  };
}

final RegExp _japaneseLanguageMarker = RegExp(
  r'(?<![a-z])(?:ja|jp|jpn)(?![a-z])',
);
final RegExp _englishLanguageMarker = RegExp(r'(?<![a-z])(?:en|eng)(?![a-z])');
final RegExp _simplifiedChineseLanguageMarker = RegExp(
  r'(?<![a-z])(?:chs|sc|zh-cn|zh-hans)(?![a-z])',
);
final RegExp _traditionalChineseLanguageMarker = RegExp(
  r'(?<![a-z])(?:cht|tc|zh-tw|zh-hk|zh-hant)(?![a-z])',
);
final RegExp _genericChineseLanguageMarker = RegExp(
  r'(?<![a-z])(?:zh|zho|chi)(?![a-z])',
);

/// 复刻原项目的 Jimaku 文件名语言分类。组合标签不能只取第一个 token：
/// `[CHS, JPN]` 是中日双语，`[JPN, ENG]` 是英日双语。没有明显中文或
/// 英语标记时，沿用原项目的日语默认值。
String resourceJimakuSubtitleLanguage(String fileName) {
  final String lower = fileName.toLowerCase();
  final bool japanese =
      _japaneseLanguageMarker.hasMatch(lower) ||
      fileName.contains('日本語') ||
      fileName.contains('日语');
  final bool english =
      _englishLanguageMarker.hasMatch(lower) ||
      fileName.contains('英語') ||
      fileName.contains('英语');
  final bool simplified =
      _simplifiedChineseLanguageMarker.hasMatch(lower) ||
      fileName.contains('简体') ||
      fileName.contains('簡体');
  final bool traditional =
      _traditionalChineseLanguageMarker.hasMatch(lower) ||
      fileName.contains('繁體') ||
      fileName.contains('繁体');
  final bool genericChinese =
      _genericChineseLanguageMarker.hasMatch(lower) || fileName.contains('中文');
  final bool chinese = simplified || traditional || genericChinese;

  // 多个显式标签组合成双语/多语；单一标签保持单语。
  if (japanese && chinese && english) return 'multilingual-ja-zh-en';
  if (japanese && chinese) return 'bilingual';
  if (japanese && english) return 'bilingual-ja-en';
  if (chinese && english) return 'bilingual-zh-en';
  if (traditional) return 'zh-hant';
  if (simplified || genericChinese) return 'zh-hans';
  if (english) return 'en';
  return 'ja';
}

final RegExp _leadingGroup = RegExp(r'^\s*\[(?<group>[^\]]{2,40})\]');
final RegExp _technicalLeadingGroup = RegExp(
  r'^(?:[0-9a-f]{6,64}|\d{3,4}p|hevc|x26[45]|h\.?26[45]|avc|aac|flac|opus|mkv|mp4|web-?dl|webrip|bluray|bdrip|10bit|8bit|jpn|chs|cht|eng)$',
  caseSensitive: false,
);

final List<({String key, String name, RegExp pattern})> _sources =
    <({String key, String name, RegExp pattern})>[
      (
        key: 'source:abema',
        name: 'ABEMA',
        pattern: RegExp(r'\bABEMA\b', caseSensitive: false),
      ),
      (
        key: 'source:netflix',
        name: 'Netflix',
        pattern: RegExp(
          r'(?:\bNetflix\b|(?:^|[\s._\-\[])NF(?:$|[\s._\-\]]))',
          caseSensitive: false,
        ),
      ),
      (
        key: 'source:amazon',
        name: 'Amazon / AMZN',
        pattern: RegExp(r'(?:\bAmazon\b|\bAMZN\b)', caseSensitive: false),
      ),
      (
        key: 'source:crunchyroll',
        name: 'Crunchyroll / CR',
        pattern: RegExp(
          r'(?:\bCrunchyroll\b|(?:^|[\s._\-\[])CR(?:$|[\s._\-\]]))',
          caseSensitive: false,
        ),
      ),
      (
        key: 'source:baha',
        name: 'Baha',
        pattern: RegExp(r'\bBaha\b', caseSensitive: false),
      ),
      (
        key: 'source:atx',
        name: 'AT-X',
        pattern: RegExp(r'\bAT[\s._-]*X\b', caseSensitive: false),
      ),
      (
        key: 'source:disney',
        name: 'Disney+',
        pattern: RegExp(r'(?:Disney\+|\bDSNP\b)', caseSensitive: false),
      ),
      (
        key: 'source:hulu',
        name: 'Hulu',
        pattern: RegExp(r'\bHulu\b', caseSensitive: false),
      ),
      (
        key: 'source:bluray',
        name: 'Blu-ray',
        pattern: RegExp(
          r'(?:Blu[\s._-]*ray|\bBDRip\b|\bBDMV\b)',
          caseSensitive: false,
        ),
      ),
    ];

String _leadingReleaseGroup(String name) {
  final RegExpMatch? match = _leadingGroup.firstMatch(name);
  final String group = match?.namedGroup('group')?.trim() ?? '';
  return group.isNotEmpty && !_technicalLeadingGroup.hasMatch(group)
      ? group
      : '';
}

String _categoryKey(JimakuFile file) {
  final String group = _leadingReleaseGroup(file.name);
  if (group.isNotEmpty) return 'group:${group.toLowerCase()}';
  for (final ({String key, String name, RegExp pattern}) source in _sources) {
    if (source.pattern.hasMatch(file.name)) return source.key;
  }
  if (RegExp(
    r'\b(?:WEBRip|WEB[\s._-]*DL|HDTV)\b',
    caseSensitive: false,
  ).hasMatch(file.name)) {
    return 'source:web-other';
  }
  return 'other';
}

String _categoryName(String key, JimakuFile sample) {
  for (final ({String key, String name, RegExp pattern}) source in _sources) {
    if (source.key == key) return source.name;
  }
  if (key == 'source:web-other') return '其他 Web / HDTV';
  if (key.startsWith('group:')) {
    final String group = _leadingReleaseGroup(sample.name);
    return group.isNotEmpty ? group : key.substring(6);
  }
  return '其他';
}

String _languageName(String? language) => switch (language) {
  'en' => '英语',
  'ja' => '日语',
  'bilingual' => '中日双语',
  'bilingual-ja-en' => '英日双语',
  'bilingual-zh-en' => '中英双语',
  'multilingual-ja-zh-en' => '中日英多语',
  'zh-hant' => '繁体中文',
  'zh-hans' => '简体中文',
  _ => '内容语言未知',
};

String _variantName(String key) {
  final int separator = key.indexOf(':');
  final String extension = key.substring(0, separator);
  final String language = key.substring(separator + 1);
  return '${extension.toUpperCase()} · ${_languageName(language)}';
}

String _portableLeaf(String path) {
  final int slash = path.lastIndexOf('/');
  final int backslash = path.lastIndexOf(r'\');
  return path.substring((slash > backslash ? slash : backslash) + 1);
}

/// 复刻原项目的有效文件夹选择：只取 torrent 第一层和第二层的 MKV；
/// 根目录与每个一级子目录分别作为一个选择单元，更深层目录不混进主动画。
List<ResourceTorrentVideoFolder> classifyResourceTorrentVideoFolders(
  Iterable<TorrentMetainfoFile> sourceFiles,
) {
  final Map<String, List<TorrentMetainfoFile>> grouped =
      <String, List<TorrentMetainfoFile>>{};
  for (final TorrentMetainfoFile file in sourceFiles) {
    final String normalized = file.path.replaceAll('\\', '/').trim();
    if (!normalized.toLowerCase().endsWith('.mkv')) continue;
    final List<String> parts = normalized
        .split('/')
        .where((String part) => part.trim().isNotEmpty)
        .toList(growable: false);
    if (parts.isEmpty || parts.length > 2) continue;
    final String key = parts.length == 1 ? '' : parts.first;
    grouped.putIfAbsent(key, () => <TorrentMetainfoFile>[]).add(file);
  }
  return <ResourceTorrentVideoFolder>[
    for (final MapEntry<String, List<TorrentMetainfoFile>> entry
        in grouped.entries)
      _resourceTorrentVideoFolder(entry.key, entry.value),
  ];
}

final RegExp _resourceOvaMarker = RegExp(
  r'(?<![\p{L}\p{Nd}])(?:OVA|OAD|ONA|OAV|SPECIAL)(?![\p{L}\p{Nd}])|'
  r'特别篇|特別篇|番外篇|特典',
  caseSensitive: false,
  unicode: true,
);

typedef _ParsedTorrentVideo = ({
  TorrentMetainfoFile file,
  VideoNameInfo videoName,
  ParsedMediaName parsed,
  String lowerPath,
});

ResourceTorrentVideoFolder _resourceTorrentVideoFolder(
  String key,
  List<TorrentMetainfoFile> sourceFiles,
) {
  final List<_ParsedTorrentVideo> parsed =
      <_ParsedTorrentVideo>[
        for (final TorrentMetainfoFile file in sourceFiles)
          (
            file: file,
            videoName: parseVideoFilename(file.path),
            parsed: FilenameParser.parse(_portableLeaf(file.path)),
            lowerPath: file.path.toLowerCase(),
          ),
      ]..sort((left, right) {
        final int bySeason = (left.videoName.season ?? 0x7fffffff).compareTo(
          right.videoName.season ?? 0x7fffffff,
        );
        if (bySeason != 0) return bySeason;
        final int byEpisode = (left.videoName.episode ?? 0x7fffffff).compareTo(
          right.videoName.episode ?? 0x7fffffff,
        );
        if (byEpisode != 0) return byEpisode;
        return left.lowerPath.compareTo(right.lowerPath);
      });
  final List<TorrentMetainfoFile> files = <TorrentMetainfoFile>[
    for (final item in parsed) item.file,
  ];
  final String folderName = key.isEmpty ? '种子主目录' : key;
  final ParsedMediaName parsedFolder = FilenameParser.parse(folderName);
  final List<ParsedMediaName> parsedFiles = <ParsedMediaName>[
    for (final item in parsed) item.parsed,
  ];
  final int episodeFiles = parsedFiles
      .where((ParsedMediaName file) => file.episode != null)
      .length;
  final String mediaType;
  if (episodeFiles >= 5) {
    mediaType = 'TV';
  } else if (parsedFolder.isMovieHint ||
      parsedFiles.any((ParsedMediaName file) => file.isMovieHint)) {
    mediaType = '剧场版';
  } else if (_resourceOvaMarker.hasMatch(folderName) ||
      files.any(
        (TorrentMetainfoFile file) => _resourceOvaMarker.hasMatch(file.path),
      )) {
    mediaType = 'OVA';
  } else {
    mediaType = '未知';
  }

  int? season;
  if (mediaType == 'TV') {
    season = parsedFolder.season;
    if (season == null) {
      final Map<int, int> counts = <int, int>{};
      for (final ParsedMediaName file in parsedFiles) {
        final int? value = file.season;
        if (value != null && value > 0) {
          counts[value] = (counts[value] ?? 0) + 1;
        }
      }
      MapEntry<int, int>? mostCommon;
      for (final MapEntry<int, int> candidate in counts.entries) {
        final MapEntry<int, int>? current = mostCommon;
        if (current == null ||
            candidate.value > current.value ||
            (candidate.value == current.value && candidate.key < current.key)) {
          mostCommon = candidate;
        }
      }
      season = mostCommon?.key;
    }
  }
  return ResourceTorrentVideoFolder(
    key: key,
    name: folderName,
    files: List<TorrentMetainfoFile>.unmodifiable(files),
    mediaType: mediaType,
    season: season,
  );
}

int _episodeCompare(JimakuFile left, JimakuFile right) {
  final int leftEpisode = left.episode ?? 0x7fffffff;
  final int rightEpisode = right.episode ?? 0x7fffffff;
  final int byEpisode = leftEpisode.compareTo(rightEpisode);
  if (byEpisode != 0) return byEpisode;
  return left.name.toLowerCase().compareTo(right.name.toLowerCase());
}

/// 按原项目的“发布来源 → 格式/语言”规则整理 Jimaku 文件。
List<ResourceJimakuCategory> classifyResourceJimakuFiles(
  Iterable<JimakuFile> sourceFiles,
) {
  final List<JimakuFile> files =
      sourceFiles
          .where(
            (JimakuFile file) =>
                file.extension == 'ass' || file.extension == 'srt',
          )
          .toList(growable: false)
        ..sort(_episodeCompare);
  final Map<String, List<JimakuFile>> categoryFiles =
      <String, List<JimakuFile>>{};
  for (final JimakuFile file in files) {
    categoryFiles
        .putIfAbsent(_categoryKey(file), () => <JimakuFile>[])
        .add(file);
  }
  final List<MapEntry<String, List<JimakuFile>>> categories =
      categoryFiles.entries.toList(growable: false)..sort(_compareFileGroups);
  return <ResourceJimakuCategory>[
    for (final MapEntry<String, List<JimakuFile>> category in categories)
      ResourceJimakuCategory(
        key: category.key,
        name: _categoryName(category.key, category.value.first),
        files: List<JimakuFile>.unmodifiable(category.value),
        variants: _classifyVariants(category.value),
      ),
  ];
}

List<ResourceJimakuVariant> _classifyVariants(List<JimakuFile> files) {
  final Map<String, List<JimakuFile>> variantFiles =
      <String, List<JimakuFile>>{};
  for (final JimakuFile file in files) {
    final String language = resourceJimakuSubtitleLanguage(file.name);
    final String key = '${file.extension}:$language';
    variantFiles.putIfAbsent(key, () => <JimakuFile>[]).add(file);
  }
  final List<MapEntry<String, List<JimakuFile>>> variants =
      variantFiles.entries.toList(growable: false)..sort(_compareFileGroups);
  return <ResourceJimakuVariant>[
    for (final MapEntry<String, List<JimakuFile>> variant in variants)
      ResourceJimakuVariant(
        key: variant.key,
        name: _variantName(variant.key),
        files: List<JimakuFile>.unmodifiable(variant.value),
      ),
  ];
}

/// 复刻原项目基于 torrent 元数据的合集判断，不相信标题中的 Batch/全集字样。
///
/// 两个以上 MKV 一定是合集；单个 MKV 能解析出集号时是单集，无法识别集号的
/// 电影/未知项目继续保留；没有 MKV 不是可用动画合集。
bool resourceTorrentMetainfoIsCollection(Iterable<TorrentMetainfoFile> files) {
  String? video;
  for (final TorrentMetainfoFile file in files) {
    if (!file.path.toLowerCase().endsWith('.mkv')) continue;
    if (video != null) return true;
    video = file.path;
  }
  return video != null && parseVideoFilename(video).episode == null;
}

int _compareFileGroups(
  MapEntry<String, List<JimakuFile>> left,
  MapEntry<String, List<JimakuFile>> right,
) {
  final int byCount = right.value.length.compareTo(left.value.length);
  return byCount != 0 ? byCount : left.key.compareTo(right.key);
}
