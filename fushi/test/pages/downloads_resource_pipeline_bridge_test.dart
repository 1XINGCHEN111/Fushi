import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/torrent/nyaa_client.dart';
import 'package:fushi/src/media/tracking/bangumi_api_client.dart';
import 'package:fushi/src/media/video/anilist_client.dart';
import 'package:fushi/src/media/video/download/video_download_backend_identity.dart';
import 'package:fushi/src/media/video/download/video_download_pipeline_service.dart';
import 'package:fushi/src/media/video/jimaku_client.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_models.dart';
import 'package:fushi/src/pages/implementations/anime_download_dialog.dart';
import 'package:fushi/src/pages/implementations/downloads_page.dart';
import 'package:fushi_core/fushi_core.dart' show MediaSourceRow;
import 'package:path/path.dart' as p;

const MediaSourceRow _source = MediaSourceRow(
  id: 9,
  label: 'Anime',
  mediaKind: 'video',
  transport: 'local',
  rootPath: r'D:\Anime',
  mediaCount: 0,
  recursive: true,
  sortOrder: 0,
  createdAt: 1,
);

const VideoDownloadBackendIdentity _backend = VideoDownloadBackendIdentity(
  kind: 'embedded',
  profileId: 'embedded',
  fingerprint: 'test-backend',
);

const VideoDownloadBackendTarget _backendTarget = VideoDownloadBackendTarget(
  identity: _backend,
  category: 'fushi',
);

NyaaTorrent _torrent(String title) => NyaaTorrent(
  title: title,
  torrentUrl: 'https://nyaa.si/download/1.torrent',
  pageUrl: 'https://nyaa.si/view/1',
  infoHash: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  seeders: 20,
  leechers: 1,
  downloads: 100,
  sizeText: '1.0 GiB',
  sizeBytes: 1073741824,
  categoryId: '1_2',
  trusted: true,
  remake: false,
  pubDate: null,
);

void main() {
  test('TV 使用 Bangumi 名称建立独立目录并保留字幕选择', () {
    const AniListMedia media = AniListMedia(
      id: 42,
      romaji: 'Hibike Euphonium',
      native: '響け！ユーフォニアム',
      episodes: 13,
      seasonYear: 2015,
    );
    const JimakuEntry entry = JimakuEntry(
      id: 77,
      name: '響け！ユーフォニアム 2',
      anilistId: 42,
    );
    const JimakuFile file = JimakuFile(
      name: 'Hibike Euphonium S02E03.ja.ass',
      url: 'https://jimaku.invalid/file',
      size: 1234,
    );
    const BangumiSubject bangumi = BangumiSubject(
      id: 12544,
      type: 2,
      name: '響け！ユーフォニアム',
      nameCn: '吹响！上低音号',
      platform: 'TV',
      episodeCount: 13,
      volumeCount: 0,
    );
    final VideoDownloadEnqueueRequest request =
        buildAnimeDownloadEnqueueRequest(
          selection: AnimeDownloadPipelineSelection(
            media: media,
            torrent: _torrent('[Group] Hibike Euphonium S02E03 [1080p]'),
            source: _source,
            includeSubtitles: true,
            jimakuEntry: entry,
            subtitles: const <(int?, JimakuFile)>[(3, file)],
            preferredSubtitleLanguage: 'ja',
            bangumiSubject: bangumi,
            fileSelections: const <AnimeDownloadFileSelection>[
              AnimeDownloadFileSelection(
                path: 'Season 02/E03.mkv',
                sizeBytes: 1024,
                selected: true,
              ),
              AnimeDownloadFileSelection(
                path: 'Season 02/E04.mkv',
                sizeBytes: 2048,
                selected: false,
              ),
            ],
          ),
          backendTarget: _backendTarget,
        );

    expect(request.media.title, '吹响！上低音号');
    expect(request.media.mediaKind, VideoMetadataMediaKind.tv);
    expect(request.media.season, 2);
    expect(request.targetSourceId, _source.id);
    expect(request.resource.providerId, 'nyaa');
    expect(request.subtitlePolicy, VideoDownloadSubtitlePolicy.bestEffort);
    expect(request.subtitleSelections, hasLength(1));
    expect(request.subtitleSelections.single.episode, 3);
    expect(
      request.organizationPolicy,
      kBangumiNamedVideoDownloadOrganizationPolicy,
    );
    expect(request.fileSelections, hasLength(2));
    expect(request.fileSelections.first.relativePath, 'Season 02/E03.mkv');
    expect(request.fileSelections.last.selected, isFalse);
    expect(
      request.subtitleSelections.single.candidate.remoteId,
      '77:${file.name}',
    );
  });

  test('电影优先英文名且关闭字幕时不持久化字幕选择', () {
    const AniListMedia media = AniListMedia(
      id: 99,
      romaji: 'Kimi no Na wa.',
      english: 'Your Name.',
      native: '君の名は。',
      episodes: 1,
      seasonYear: 2016,
    );
    final VideoDownloadEnqueueRequest request =
        buildAnimeDownloadEnqueueRequest(
          selection: AnimeDownloadPipelineSelection(
            media: media,
            torrent: _torrent('[Group] Your Name [1080p]'),
            source: _source,
            includeSubtitles: false,
            jimakuEntry: null,
            subtitles: const <(int?, JimakuFile)>[],
            preferredSubtitleLanguage: null,
          ),
          backendTarget: _backendTarget,
        );

    expect(request.media.title, 'Your Name.');
    expect(request.media.mediaKind, VideoMetadataMediaKind.movie);
    expect(request.media.season, isNull);
    expect(request.subtitlePolicy, VideoDownloadSubtitlePolicy.none);
    expect(request.subtitleSelections, isEmpty);
  });

  test('Jimaku 文件没有明显语言标记时按日语提交并下载', () {
    const AniListMedia media = AniListMedia(
      id: 42,
      romaji: 'Hibike Euphonium',
      native: '響け！ユーフォニアム',
      episodes: 13,
    );
    const JimakuEntry entry = JimakuEntry(
      id: 77,
      name: '響け！ユーフォニアム',
      anilistId: 42,
    );
    const JimakuFile file = JimakuFile(
      name: 'Hibike Euphonium S01E03.ass',
      url: 'https://jimaku.invalid/file',
    );
    final VideoDownloadEnqueueRequest request =
        buildAnimeDownloadEnqueueRequest(
          selection: AnimeDownloadPipelineSelection(
            media: media,
            torrent: _torrent('[Group] Hibike Euphonium S01E03 [1080p]'),
            source: _source,
            includeSubtitles: true,
            jimakuEntry: entry,
            subtitles: const <(int?, JimakuFile)>[(3, file)],
            preferredSubtitleLanguage: 'ja',
          ),
          backendTarget: _backendTarget,
        );

    expect(request.subtitlePolicy, VideoDownloadSubtitlePolicy.bestEffort);
    expect(request.subtitleSelections, hasLength(1));
    expect(request.subtitleSelections.single.candidate.language, 'ja');
  });

  test('字幕已经预先落盘时动画任务不再重复进入字幕下载阶段', () {
    const AniListMedia media = AniListMedia(
      id: 42,
      english: 'Hibike Euphonium',
      episodes: 13,
    );
    const JimakuEntry entry = JimakuEntry(id: 77, name: 'Hibike Euphonium');
    const JimakuFile file = JimakuFile(
      name: 'Hibike Euphonium S01E03.ass',
      url: 'https://jimaku.invalid/file',
    );
    final VideoDownloadEnqueueRequest request =
        buildAnimeDownloadEnqueueRequest(
          selection: AnimeDownloadPipelineSelection(
            media: media,
            torrent: _torrent('[Group] Hibike Euphonium S01E03 [1080p]'),
            source: _source,
            includeSubtitles: true,
            jimakuEntry: entry,
            subtitles: const <(int?, JimakuFile)>[(3, file)],
            preferredSubtitleLanguage: 'ja',
            contentMode: AnimeDownloadContentMode.both,
          ),
          backendTarget: _backendTarget,
          subtitlesPreinstalled: true,
        );

    expect(request.subtitlePolicy, VideoDownloadSubtitlePolicy.none);
    expect(request.subtitleSelections, isEmpty);
  });

  test('预下载字幕会先创建 Bangumi 独立目录并写入最终文件名', () async {
    final Directory root = await Directory.systemTemp.createTemp(
      'fushi-resource-subtitle-',
    );
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final MediaSourceRow source = MediaSourceRow(
      id: 10,
      label: 'Anime',
      mediaKind: 'video',
      transport: 'local',
      rootPath: root.path,
      mediaCount: 0,
      recursive: true,
      sortOrder: 0,
      createdAt: 1,
    );
    const AniListMedia media = AniListMedia(
      id: 42,
      english: 'Hibike Euphonium',
      episodes: 13,
      seasonYear: 2015,
    );
    const BangumiSubject bangumi = BangumiSubject(
      id: 12544,
      type: 2,
      name: '響け！ユーフォニアム',
      nameCn: '吹响！上低音号',
      platform: 'TV',
      episodeCount: 13,
      volumeCount: 0,
    );
    const JimakuEntry entry = JimakuEntry(id: 77, name: 'Hibike Euphonium');
    const JimakuFile file = JimakuFile(
      name: 'Hibike Euphonium S02E03.ja.ass',
      url: 'https://jimaku.invalid/file',
      size: 4,
    );
    final AnimeDownloadPipelineSelection selection =
        AnimeDownloadPipelineSelection(
          media: media,
          torrent: _torrent('[Group] Hibike Euphonium S02E03 [1080p]'),
          source: source,
          includeSubtitles: true,
          jimakuEntry: entry,
          subtitles: const <(int?, JimakuFile)>[(3, file)],
          preferredSubtitleLanguage: 'ja',
          bangumiSubject: bangumi,
        );

    final List<String> installed = await downloadAnimeSelectionSubtitles(
      selection: selection,
      downloader: (JimakuFile _) async => <int>[1, 2, 3, 4],
    );

    expect(animeDownloadTaskRootPath(selection), p.join(root.path, '吹响！上低音号'));
    expect(installed, hasLength(1));
    expect(
      installed.single,
      p.join(root.path, '吹响！上低音号', '吹响！上低音号 - S02E03.ja.ass'),
    );
    expect(await File(installed.single).readAsBytes(), <int>[1, 2, 3, 4]);
  });
}
