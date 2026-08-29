import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/torrent/resource_download_presentation.dart';
import 'package:fushi/src/media/torrent/torrent_metainfo.dart';
import 'package:fushi/src/media/video/jimaku_client.dart';

void main() {
  test('Jimaku 按发布来源和格式语言版本分组', () {
    final List<ResourceJimakuCategory> groups =
        classifyResourceJimakuFiles(const <JimakuFile>[
          JimakuFile(name: '[VCB-Studio] Show - 01 [ja].ass', url: '1'),
          JimakuFile(name: '[VCB-Studio] Show - 02 [ja].ass', url: '2'),
          JimakuFile(name: 'Show - 01 Netflix.en.srt', url: '3'),
          JimakuFile(name: 'notes.zip', url: '4'),
        ]);

    expect(
      groups.map((ResourceJimakuCategory group) => group.name),
      containsAll(<String>['VCB-Studio', 'Netflix']),
    );
    final ResourceJimakuCategory vcb = groups.firstWhere(
      (ResourceJimakuCategory group) => group.name == 'VCB-Studio',
    );
    expect(vcb.files, hasLength(2));
    expect(vcb.variants, hasLength(1));
    expect(vcb.variants.single.name, contains('ASS'));
    expect(resourceJimakuSubtitleLanguage('Show - 03.ass'), 'ja');
    expect(
      classifyResourceJimakuFiles(const <JimakuFile>[
        JimakuFile(name: 'Show - 03.ass', url: '5'),
      ]).single.variants.single.name,
      contains('日语'),
    );
  });

  test('Jimaku 按原项目的文件名组合标签识别双语字幕', () {
    expect(
      resourceJimakuSubtitleLanguage('[KitaujiSub] Show [CHS, JPN].ass'),
      'bilingual',
    );
    expect(
      resourceJimakuSubtitleLanguage('[SubsPlease] Show [JPN, ENG].ass'),
      'bilingual-ja-en',
    );
    final Iterable<String> names =
        classifyResourceJimakuFiles(const <JimakuFile>[
              JimakuFile(name: '[KitaujiSub] Show [CHS, JPN].ass', url: '1'),
              JimakuFile(name: '[SubsPlease] Show [JPN, ENG].ass', url: '2'),
            ])
            .expand((ResourceJimakuCategory group) => group.variants)
            .map((ResourceJimakuVariant variant) => variant.name);
    expect(names.any((String name) => name.contains('中日双语')), isTrue);
    expect(names.any((String name) => name.contains('英日双语')), isTrue);
  });

  test('Jimaku 分组标题只保留字幕格式、语言并合并文件名后缀', () {
    final List<ResourceJimakuVariant> variants =
        classifyResourceJimakuFiles(const <JimakuFile>[
          JimakuFile(name: '[Group] Show - 01 [JPN].ass', url: '1'),
          JimakuFile(name: '[Group] Show - 02 [JPN][CC].ass', url: '2'),
        ]).single.variants;
    expect(variants, hasLength(1));
    expect(variants.single.name, 'ASS · 日语');
    expect(variants.single.files, hasLength(2));
  });

  test('Nyaa 合集只由 torrent 内部 MKV 结构决定', () {
    expect(
      resourceTorrentMetainfoIsCollection(const <TorrentMetainfoFile>[
        TorrentMetainfoFile(path: 'Show/Show - 01.mkv', length: 1),
        TorrentMetainfoFile(path: 'Show/Show - 02.mkv', length: 1),
      ]),
      isTrue,
    );
    expect(
      resourceTorrentMetainfoIsCollection(const <TorrentMetainfoFile>[
        TorrentMetainfoFile(path: 'Show/Show - 01.mkv', length: 1),
      ]),
      isFalse,
    );
    expect(
      resourceTorrentMetainfoIsCollection(const <TorrentMetainfoFile>[
        TorrentMetainfoFile(path: 'Movie/Movie.mkv', length: 1),
      ]),
      isTrue,
    );
    expect(
      resourceTorrentMetainfoIsCollection(const <TorrentMetainfoFile>[
        TorrentMetainfoFile(path: 'Show/Show - 01.mp4', length: 1),
      ]),
      isFalse,
    );
  });

  test('有效文件夹只保留 torrent 第一层和第二层 MKV', () {
    final List<ResourceTorrentVideoFolder> folders =
        classifyResourceTorrentVideoFolders(const <TorrentMetainfoFile>[
          TorrentMetainfoFile(path: 'Movie.mkv', length: 1),
          TorrentMetainfoFile(path: 'Season 1/E01.mkv', length: 2),
          TorrentMetainfoFile(path: 'Season 1/E02.mkv', length: 3),
          TorrentMetainfoFile(path: 'Season 2/E01.mkv', length: 4),
          TorrentMetainfoFile(path: 'Extras/NCOP/NCOP.mkv', length: 5),
          TorrentMetainfoFile(path: 'Season 1/cover.jpg', length: 6),
        ]);

    expect(
      folders.map((ResourceTorrentVideoFolder folder) => folder.name),
      <String>['种子主目录', 'Season 1', 'Season 2'],
    );
    expect(folders[1].files, hasLength(2));
    expect(folders[0].mediaType, '剧场版');
    expect(folders[1].mediaType, '未知');
    expect(folders[1].typeSeasonLabel, '类型：未知');
  });

  test('有效文件夹按原项目规则标记 TV 类型和季度', () {
    final List<ResourceTorrentVideoFolder>
    folders = classifyResourceTorrentVideoFolders(<TorrentMetainfoFile>[
      for (int episode = 1; episode <= 5; episode++)
        TorrentMetainfoFile(
          path:
              'Hibike! Euphonium Season 2/'
              'Hibike! Euphonium S02E${episode.toString().padLeft(2, '0')}.mkv',
          length: episode,
        ),
    ]);

    expect(folders, hasLength(1));
    expect(folders.single.mediaType, 'TV');
    expect(folders.single.season, 2);
    expect(folders.single.annotatedName, '[TV 第2季] Hibike! Euphonium Season 2');
    expect(folders.single.typeSeasonLabel, '类型：TV  ·  季度：第 2 季');
  });
}
