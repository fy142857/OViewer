// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'database.dart';

// ignore_for_file: type=lint
class $HistoryEntriesTable extends HistoryEntries
    with TableInfo<$HistoryEntriesTable, HistoryEntry> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $HistoryEntriesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _gidMeta = const VerificationMeta('gid');
  @override
  late final GeneratedColumn<int> gid = GeneratedColumn<int>(
      'gid', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _tokenMeta = const VerificationMeta('token');
  @override
  late final GeneratedColumn<String> token = GeneratedColumn<String>(
      'token', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
      'title', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _thumbUrlMeta =
      const VerificationMeta('thumbUrl');
  @override
  late final GeneratedColumn<String> thumbUrl = GeneratedColumn<String>(
      'thumb_url', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _categoryMeta =
      const VerificationMeta('category');
  @override
  late final GeneratedColumn<String> category = GeneratedColumn<String>(
      'category', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant('Misc'));
  static const VerificationMeta _ratingMeta = const VerificationMeta('rating');
  @override
  late final GeneratedColumn<double> rating = GeneratedColumn<double>(
      'rating', aliasedName, false,
      type: DriftSqlType.double,
      requiredDuringInsert: false,
      defaultValue: const Constant(0.0));
  static const VerificationMeta _fileCountMeta =
      const VerificationMeta('fileCount');
  @override
  late final GeneratedColumn<int> fileCount = GeneratedColumn<int>(
      'file_count', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _lastReadPageMeta =
      const VerificationMeta('lastReadPage');
  @override
  late final GeneratedColumn<int> lastReadPage = GeneratedColumn<int>(
      'last_read_page', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _totalPagesMeta =
      const VerificationMeta('totalPages');
  @override
  late final GeneratedColumn<int> totalPages = GeneratedColumn<int>(
      'total_pages', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _lastReadAtMeta =
      const VerificationMeta('lastReadAt');
  @override
  late final GeneratedColumn<DateTime> lastReadAt = GeneratedColumn<DateTime>(
      'last_read_at', aliasedName, false,
      type: DriftSqlType.dateTime, requiredDuringInsert: true);
  static const VerificationMeta _sourceMeta = const VerificationMeta('source');
  @override
  late final GeneratedColumn<String> source = GeneratedColumn<String>(
      'source', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  @override
  List<GeneratedColumn> get $columns => [
        gid,
        token,
        title,
        thumbUrl,
        category,
        rating,
        fileCount,
        lastReadPage,
        totalPages,
        lastReadAt,
        source
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'history_entries';
  @override
  VerificationContext validateIntegrity(Insertable<HistoryEntry> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('gid')) {
      context.handle(
          _gidMeta, gid.isAcceptableOrUnknown(data['gid']!, _gidMeta));
    }
    if (data.containsKey('token')) {
      context.handle(
          _tokenMeta, token.isAcceptableOrUnknown(data['token']!, _tokenMeta));
    } else if (isInserting) {
      context.missing(_tokenMeta);
    }
    if (data.containsKey('title')) {
      context.handle(
          _titleMeta, title.isAcceptableOrUnknown(data['title']!, _titleMeta));
    } else if (isInserting) {
      context.missing(_titleMeta);
    }
    if (data.containsKey('thumb_url')) {
      context.handle(_thumbUrlMeta,
          thumbUrl.isAcceptableOrUnknown(data['thumb_url']!, _thumbUrlMeta));
    } else if (isInserting) {
      context.missing(_thumbUrlMeta);
    }
    if (data.containsKey('category')) {
      context.handle(_categoryMeta,
          category.isAcceptableOrUnknown(data['category']!, _categoryMeta));
    }
    if (data.containsKey('rating')) {
      context.handle(_ratingMeta,
          rating.isAcceptableOrUnknown(data['rating']!, _ratingMeta));
    }
    if (data.containsKey('file_count')) {
      context.handle(_fileCountMeta,
          fileCount.isAcceptableOrUnknown(data['file_count']!, _fileCountMeta));
    }
    if (data.containsKey('last_read_page')) {
      context.handle(
          _lastReadPageMeta,
          lastReadPage.isAcceptableOrUnknown(
              data['last_read_page']!, _lastReadPageMeta));
    }
    if (data.containsKey('total_pages')) {
      context.handle(
          _totalPagesMeta,
          totalPages.isAcceptableOrUnknown(
              data['total_pages']!, _totalPagesMeta));
    }
    if (data.containsKey('last_read_at')) {
      context.handle(
          _lastReadAtMeta,
          lastReadAt.isAcceptableOrUnknown(
              data['last_read_at']!, _lastReadAtMeta));
    } else if (isInserting) {
      context.missing(_lastReadAtMeta);
    }
    if (data.containsKey('source')) {
      context.handle(_sourceMeta,
          source.isAcceptableOrUnknown(data['source']!, _sourceMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {gid};
  @override
  HistoryEntry map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return HistoryEntry(
      gid: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}gid'])!,
      token: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}token'])!,
      title: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}title'])!,
      thumbUrl: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}thumb_url'])!,
      category: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}category'])!,
      rating: attachedDatabase.typeMapping
          .read(DriftSqlType.double, data['${effectivePrefix}rating'])!,
      fileCount: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}file_count'])!,
      lastReadPage: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}last_read_page'])!,
      totalPages: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}total_pages'])!,
      lastReadAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}last_read_at'])!,
      source: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}source']),
    );
  }

  @override
  $HistoryEntriesTable createAlias(String alias) {
    return $HistoryEntriesTable(attachedDatabase, alias);
  }
}

class HistoryEntry extends DataClass implements Insertable<HistoryEntry> {
  final int gid;
  final String token;
  final String title;
  final String thumbUrl;
  final String category;
  final double rating;
  final int fileCount;
  final int lastReadPage;
  final int totalPages;
  final DateTime lastReadAt;
  final String? source;
  const HistoryEntry(
      {required this.gid,
      required this.token,
      required this.title,
      required this.thumbUrl,
      required this.category,
      required this.rating,
      required this.fileCount,
      required this.lastReadPage,
      required this.totalPages,
      required this.lastReadAt,
      this.source});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['gid'] = Variable<int>(gid);
    map['token'] = Variable<String>(token);
    map['title'] = Variable<String>(title);
    map['thumb_url'] = Variable<String>(thumbUrl);
    map['category'] = Variable<String>(category);
    map['rating'] = Variable<double>(rating);
    map['file_count'] = Variable<int>(fileCount);
    map['last_read_page'] = Variable<int>(lastReadPage);
    map['total_pages'] = Variable<int>(totalPages);
    map['last_read_at'] = Variable<DateTime>(lastReadAt);
    if (!nullToAbsent || source != null) {
      map['source'] = Variable<String>(source);
    }
    return map;
  }

  HistoryEntriesCompanion toCompanion(bool nullToAbsent) {
    return HistoryEntriesCompanion(
      gid: Value(gid),
      token: Value(token),
      title: Value(title),
      thumbUrl: Value(thumbUrl),
      category: Value(category),
      rating: Value(rating),
      fileCount: Value(fileCount),
      lastReadPage: Value(lastReadPage),
      totalPages: Value(totalPages),
      lastReadAt: Value(lastReadAt),
      source:
          source == null && nullToAbsent ? const Value.absent() : Value(source),
    );
  }

  factory HistoryEntry.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return HistoryEntry(
      gid: serializer.fromJson<int>(json['gid']),
      token: serializer.fromJson<String>(json['token']),
      title: serializer.fromJson<String>(json['title']),
      thumbUrl: serializer.fromJson<String>(json['thumbUrl']),
      category: serializer.fromJson<String>(json['category']),
      rating: serializer.fromJson<double>(json['rating']),
      fileCount: serializer.fromJson<int>(json['fileCount']),
      lastReadPage: serializer.fromJson<int>(json['lastReadPage']),
      totalPages: serializer.fromJson<int>(json['totalPages']),
      lastReadAt: serializer.fromJson<DateTime>(json['lastReadAt']),
      source: serializer.fromJson<String?>(json['source']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'gid': serializer.toJson<int>(gid),
      'token': serializer.toJson<String>(token),
      'title': serializer.toJson<String>(title),
      'thumbUrl': serializer.toJson<String>(thumbUrl),
      'category': serializer.toJson<String>(category),
      'rating': serializer.toJson<double>(rating),
      'fileCount': serializer.toJson<int>(fileCount),
      'lastReadPage': serializer.toJson<int>(lastReadPage),
      'totalPages': serializer.toJson<int>(totalPages),
      'lastReadAt': serializer.toJson<DateTime>(lastReadAt),
      'source': serializer.toJson<String?>(source),
    };
  }

  HistoryEntry copyWith(
          {int? gid,
          String? token,
          String? title,
          String? thumbUrl,
          String? category,
          double? rating,
          int? fileCount,
          int? lastReadPage,
          int? totalPages,
          DateTime? lastReadAt,
          Value<String?> source = const Value.absent()}) =>
      HistoryEntry(
        gid: gid ?? this.gid,
        token: token ?? this.token,
        title: title ?? this.title,
        thumbUrl: thumbUrl ?? this.thumbUrl,
        category: category ?? this.category,
        rating: rating ?? this.rating,
        fileCount: fileCount ?? this.fileCount,
        lastReadPage: lastReadPage ?? this.lastReadPage,
        totalPages: totalPages ?? this.totalPages,
        lastReadAt: lastReadAt ?? this.lastReadAt,
        source: source.present ? source.value : this.source,
      );
  @override
  String toString() {
    return (StringBuffer('HistoryEntry(')
          ..write('gid: $gid, ')
          ..write('token: $token, ')
          ..write('title: $title, ')
          ..write('thumbUrl: $thumbUrl, ')
          ..write('category: $category, ')
          ..write('rating: $rating, ')
          ..write('fileCount: $fileCount, ')
          ..write('lastReadPage: $lastReadPage, ')
          ..write('totalPages: $totalPages, ')
          ..write('lastReadAt: $lastReadAt, ')
          ..write('source: $source')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(gid, token, title, thumbUrl, category, rating,
      fileCount, lastReadPage, totalPages, lastReadAt, source);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is HistoryEntry &&
          other.gid == this.gid &&
          other.token == this.token &&
          other.title == this.title &&
          other.thumbUrl == this.thumbUrl &&
          other.category == this.category &&
          other.rating == this.rating &&
          other.fileCount == this.fileCount &&
          other.lastReadPage == this.lastReadPage &&
          other.totalPages == this.totalPages &&
          other.lastReadAt == this.lastReadAt &&
          other.source == this.source);
}

class HistoryEntriesCompanion extends UpdateCompanion<HistoryEntry> {
  final Value<int> gid;
  final Value<String> token;
  final Value<String> title;
  final Value<String> thumbUrl;
  final Value<String> category;
  final Value<double> rating;
  final Value<int> fileCount;
  final Value<int> lastReadPage;
  final Value<int> totalPages;
  final Value<DateTime> lastReadAt;
  final Value<String?> source;
  const HistoryEntriesCompanion({
    this.gid = const Value.absent(),
    this.token = const Value.absent(),
    this.title = const Value.absent(),
    this.thumbUrl = const Value.absent(),
    this.category = const Value.absent(),
    this.rating = const Value.absent(),
    this.fileCount = const Value.absent(),
    this.lastReadPage = const Value.absent(),
    this.totalPages = const Value.absent(),
    this.lastReadAt = const Value.absent(),
    this.source = const Value.absent(),
  });
  HistoryEntriesCompanion.insert({
    this.gid = const Value.absent(),
    required String token,
    required String title,
    required String thumbUrl,
    this.category = const Value.absent(),
    this.rating = const Value.absent(),
    this.fileCount = const Value.absent(),
    this.lastReadPage = const Value.absent(),
    this.totalPages = const Value.absent(),
    required DateTime lastReadAt,
    this.source = const Value.absent(),
  })  : token = Value(token),
        title = Value(title),
        thumbUrl = Value(thumbUrl),
        lastReadAt = Value(lastReadAt);
  static Insertable<HistoryEntry> custom({
    Expression<int>? gid,
    Expression<String>? token,
    Expression<String>? title,
    Expression<String>? thumbUrl,
    Expression<String>? category,
    Expression<double>? rating,
    Expression<int>? fileCount,
    Expression<int>? lastReadPage,
    Expression<int>? totalPages,
    Expression<DateTime>? lastReadAt,
    Expression<String>? source,
  }) {
    return RawValuesInsertable({
      if (gid != null) 'gid': gid,
      if (token != null) 'token': token,
      if (title != null) 'title': title,
      if (thumbUrl != null) 'thumb_url': thumbUrl,
      if (category != null) 'category': category,
      if (rating != null) 'rating': rating,
      if (fileCount != null) 'file_count': fileCount,
      if (lastReadPage != null) 'last_read_page': lastReadPage,
      if (totalPages != null) 'total_pages': totalPages,
      if (lastReadAt != null) 'last_read_at': lastReadAt,
      if (source != null) 'source': source,
    });
  }

  HistoryEntriesCompanion copyWith(
      {Value<int>? gid,
      Value<String>? token,
      Value<String>? title,
      Value<String>? thumbUrl,
      Value<String>? category,
      Value<double>? rating,
      Value<int>? fileCount,
      Value<int>? lastReadPage,
      Value<int>? totalPages,
      Value<DateTime>? lastReadAt,
      Value<String?>? source}) {
    return HistoryEntriesCompanion(
      gid: gid ?? this.gid,
      token: token ?? this.token,
      title: title ?? this.title,
      thumbUrl: thumbUrl ?? this.thumbUrl,
      category: category ?? this.category,
      rating: rating ?? this.rating,
      fileCount: fileCount ?? this.fileCount,
      lastReadPage: lastReadPage ?? this.lastReadPage,
      totalPages: totalPages ?? this.totalPages,
      lastReadAt: lastReadAt ?? this.lastReadAt,
      source: source ?? this.source,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (gid.present) {
      map['gid'] = Variable<int>(gid.value);
    }
    if (token.present) {
      map['token'] = Variable<String>(token.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (thumbUrl.present) {
      map['thumb_url'] = Variable<String>(thumbUrl.value);
    }
    if (category.present) {
      map['category'] = Variable<String>(category.value);
    }
    if (rating.present) {
      map['rating'] = Variable<double>(rating.value);
    }
    if (fileCount.present) {
      map['file_count'] = Variable<int>(fileCount.value);
    }
    if (lastReadPage.present) {
      map['last_read_page'] = Variable<int>(lastReadPage.value);
    }
    if (totalPages.present) {
      map['total_pages'] = Variable<int>(totalPages.value);
    }
    if (lastReadAt.present) {
      map['last_read_at'] = Variable<DateTime>(lastReadAt.value);
    }
    if (source.present) {
      map['source'] = Variable<String>(source.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('HistoryEntriesCompanion(')
          ..write('gid: $gid, ')
          ..write('token: $token, ')
          ..write('title: $title, ')
          ..write('thumbUrl: $thumbUrl, ')
          ..write('category: $category, ')
          ..write('rating: $rating, ')
          ..write('fileCount: $fileCount, ')
          ..write('lastReadPage: $lastReadPage, ')
          ..write('totalPages: $totalPages, ')
          ..write('lastReadAt: $lastReadAt, ')
          ..write('source: $source')
          ..write(')'))
        .toString();
  }
}

class $LocalFavoritesTable extends LocalFavorites
    with TableInfo<$LocalFavoritesTable, LocalFavorite> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $LocalFavoritesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _gidMeta = const VerificationMeta('gid');
  @override
  late final GeneratedColumn<int> gid = GeneratedColumn<int>(
      'gid', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _tokenMeta = const VerificationMeta('token');
  @override
  late final GeneratedColumn<String> token = GeneratedColumn<String>(
      'token', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
      'title', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _thumbUrlMeta =
      const VerificationMeta('thumbUrl');
  @override
  late final GeneratedColumn<String> thumbUrl = GeneratedColumn<String>(
      'thumb_url', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _categoryMeta =
      const VerificationMeta('category');
  @override
  late final GeneratedColumn<String> category = GeneratedColumn<String>(
      'category', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant('Misc'));
  static const VerificationMeta _ratingMeta = const VerificationMeta('rating');
  @override
  late final GeneratedColumn<double> rating = GeneratedColumn<double>(
      'rating', aliasedName, false,
      type: DriftSqlType.double,
      requiredDuringInsert: false,
      defaultValue: const Constant(0.0));
  static const VerificationMeta _fileCountMeta =
      const VerificationMeta('fileCount');
  @override
  late final GeneratedColumn<int> fileCount = GeneratedColumn<int>(
      'file_count', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _slotMeta = const VerificationMeta('slot');
  @override
  late final GeneratedColumn<int> slot = GeneratedColumn<int>(
      'slot', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _addedAtMeta =
      const VerificationMeta('addedAt');
  @override
  late final GeneratedColumn<DateTime> addedAt = GeneratedColumn<DateTime>(
      'added_at', aliasedName, false,
      type: DriftSqlType.dateTime, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns =>
      [gid, token, title, thumbUrl, category, rating, fileCount, slot, addedAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'local_favorites';
  @override
  VerificationContext validateIntegrity(Insertable<LocalFavorite> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('gid')) {
      context.handle(
          _gidMeta, gid.isAcceptableOrUnknown(data['gid']!, _gidMeta));
    }
    if (data.containsKey('token')) {
      context.handle(
          _tokenMeta, token.isAcceptableOrUnknown(data['token']!, _tokenMeta));
    } else if (isInserting) {
      context.missing(_tokenMeta);
    }
    if (data.containsKey('title')) {
      context.handle(
          _titleMeta, title.isAcceptableOrUnknown(data['title']!, _titleMeta));
    } else if (isInserting) {
      context.missing(_titleMeta);
    }
    if (data.containsKey('thumb_url')) {
      context.handle(_thumbUrlMeta,
          thumbUrl.isAcceptableOrUnknown(data['thumb_url']!, _thumbUrlMeta));
    } else if (isInserting) {
      context.missing(_thumbUrlMeta);
    }
    if (data.containsKey('category')) {
      context.handle(_categoryMeta,
          category.isAcceptableOrUnknown(data['category']!, _categoryMeta));
    }
    if (data.containsKey('rating')) {
      context.handle(_ratingMeta,
          rating.isAcceptableOrUnknown(data['rating']!, _ratingMeta));
    }
    if (data.containsKey('file_count')) {
      context.handle(_fileCountMeta,
          fileCount.isAcceptableOrUnknown(data['file_count']!, _fileCountMeta));
    }
    if (data.containsKey('slot')) {
      context.handle(
          _slotMeta, slot.isAcceptableOrUnknown(data['slot']!, _slotMeta));
    }
    if (data.containsKey('added_at')) {
      context.handle(_addedAtMeta,
          addedAt.isAcceptableOrUnknown(data['added_at']!, _addedAtMeta));
    } else if (isInserting) {
      context.missing(_addedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {gid};
  @override
  LocalFavorite map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return LocalFavorite(
      gid: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}gid'])!,
      token: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}token'])!,
      title: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}title'])!,
      thumbUrl: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}thumb_url'])!,
      category: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}category'])!,
      rating: attachedDatabase.typeMapping
          .read(DriftSqlType.double, data['${effectivePrefix}rating'])!,
      fileCount: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}file_count'])!,
      slot: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}slot'])!,
      addedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}added_at'])!,
    );
  }

  @override
  $LocalFavoritesTable createAlias(String alias) {
    return $LocalFavoritesTable(attachedDatabase, alias);
  }
}

class LocalFavorite extends DataClass implements Insertable<LocalFavorite> {
  final int gid;
  final String token;
  final String title;
  final String thumbUrl;
  final String category;
  final double rating;
  final int fileCount;
  final int slot;
  final DateTime addedAt;
  const LocalFavorite(
      {required this.gid,
      required this.token,
      required this.title,
      required this.thumbUrl,
      required this.category,
      required this.rating,
      required this.fileCount,
      required this.slot,
      required this.addedAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['gid'] = Variable<int>(gid);
    map['token'] = Variable<String>(token);
    map['title'] = Variable<String>(title);
    map['thumb_url'] = Variable<String>(thumbUrl);
    map['category'] = Variable<String>(category);
    map['rating'] = Variable<double>(rating);
    map['file_count'] = Variable<int>(fileCount);
    map['slot'] = Variable<int>(slot);
    map['added_at'] = Variable<DateTime>(addedAt);
    return map;
  }

  LocalFavoritesCompanion toCompanion(bool nullToAbsent) {
    return LocalFavoritesCompanion(
      gid: Value(gid),
      token: Value(token),
      title: Value(title),
      thumbUrl: Value(thumbUrl),
      category: Value(category),
      rating: Value(rating),
      fileCount: Value(fileCount),
      slot: Value(slot),
      addedAt: Value(addedAt),
    );
  }

  factory LocalFavorite.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return LocalFavorite(
      gid: serializer.fromJson<int>(json['gid']),
      token: serializer.fromJson<String>(json['token']),
      title: serializer.fromJson<String>(json['title']),
      thumbUrl: serializer.fromJson<String>(json['thumbUrl']),
      category: serializer.fromJson<String>(json['category']),
      rating: serializer.fromJson<double>(json['rating']),
      fileCount: serializer.fromJson<int>(json['fileCount']),
      slot: serializer.fromJson<int>(json['slot']),
      addedAt: serializer.fromJson<DateTime>(json['addedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'gid': serializer.toJson<int>(gid),
      'token': serializer.toJson<String>(token),
      'title': serializer.toJson<String>(title),
      'thumbUrl': serializer.toJson<String>(thumbUrl),
      'category': serializer.toJson<String>(category),
      'rating': serializer.toJson<double>(rating),
      'fileCount': serializer.toJson<int>(fileCount),
      'slot': serializer.toJson<int>(slot),
      'addedAt': serializer.toJson<DateTime>(addedAt),
    };
  }

  LocalFavorite copyWith(
          {int? gid,
          String? token,
          String? title,
          String? thumbUrl,
          String? category,
          double? rating,
          int? fileCount,
          int? slot,
          DateTime? addedAt}) =>
      LocalFavorite(
        gid: gid ?? this.gid,
        token: token ?? this.token,
        title: title ?? this.title,
        thumbUrl: thumbUrl ?? this.thumbUrl,
        category: category ?? this.category,
        rating: rating ?? this.rating,
        fileCount: fileCount ?? this.fileCount,
        slot: slot ?? this.slot,
        addedAt: addedAt ?? this.addedAt,
      );
  @override
  String toString() {
    return (StringBuffer('LocalFavorite(')
          ..write('gid: $gid, ')
          ..write('token: $token, ')
          ..write('title: $title, ')
          ..write('thumbUrl: $thumbUrl, ')
          ..write('category: $category, ')
          ..write('rating: $rating, ')
          ..write('fileCount: $fileCount, ')
          ..write('slot: $slot, ')
          ..write('addedAt: $addedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
      gid, token, title, thumbUrl, category, rating, fileCount, slot, addedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is LocalFavorite &&
          other.gid == this.gid &&
          other.token == this.token &&
          other.title == this.title &&
          other.thumbUrl == this.thumbUrl &&
          other.category == this.category &&
          other.rating == this.rating &&
          other.fileCount == this.fileCount &&
          other.slot == this.slot &&
          other.addedAt == this.addedAt);
}

class LocalFavoritesCompanion extends UpdateCompanion<LocalFavorite> {
  final Value<int> gid;
  final Value<String> token;
  final Value<String> title;
  final Value<String> thumbUrl;
  final Value<String> category;
  final Value<double> rating;
  final Value<int> fileCount;
  final Value<int> slot;
  final Value<DateTime> addedAt;
  const LocalFavoritesCompanion({
    this.gid = const Value.absent(),
    this.token = const Value.absent(),
    this.title = const Value.absent(),
    this.thumbUrl = const Value.absent(),
    this.category = const Value.absent(),
    this.rating = const Value.absent(),
    this.fileCount = const Value.absent(),
    this.slot = const Value.absent(),
    this.addedAt = const Value.absent(),
  });
  LocalFavoritesCompanion.insert({
    this.gid = const Value.absent(),
    required String token,
    required String title,
    required String thumbUrl,
    this.category = const Value.absent(),
    this.rating = const Value.absent(),
    this.fileCount = const Value.absent(),
    this.slot = const Value.absent(),
    required DateTime addedAt,
  })  : token = Value(token),
        title = Value(title),
        thumbUrl = Value(thumbUrl),
        addedAt = Value(addedAt);
  static Insertable<LocalFavorite> custom({
    Expression<int>? gid,
    Expression<String>? token,
    Expression<String>? title,
    Expression<String>? thumbUrl,
    Expression<String>? category,
    Expression<double>? rating,
    Expression<int>? fileCount,
    Expression<int>? slot,
    Expression<DateTime>? addedAt,
  }) {
    return RawValuesInsertable({
      if (gid != null) 'gid': gid,
      if (token != null) 'token': token,
      if (title != null) 'title': title,
      if (thumbUrl != null) 'thumb_url': thumbUrl,
      if (category != null) 'category': category,
      if (rating != null) 'rating': rating,
      if (fileCount != null) 'file_count': fileCount,
      if (slot != null) 'slot': slot,
      if (addedAt != null) 'added_at': addedAt,
    });
  }

  LocalFavoritesCompanion copyWith(
      {Value<int>? gid,
      Value<String>? token,
      Value<String>? title,
      Value<String>? thumbUrl,
      Value<String>? category,
      Value<double>? rating,
      Value<int>? fileCount,
      Value<int>? slot,
      Value<DateTime>? addedAt}) {
    return LocalFavoritesCompanion(
      gid: gid ?? this.gid,
      token: token ?? this.token,
      title: title ?? this.title,
      thumbUrl: thumbUrl ?? this.thumbUrl,
      category: category ?? this.category,
      rating: rating ?? this.rating,
      fileCount: fileCount ?? this.fileCount,
      slot: slot ?? this.slot,
      addedAt: addedAt ?? this.addedAt,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (gid.present) {
      map['gid'] = Variable<int>(gid.value);
    }
    if (token.present) {
      map['token'] = Variable<String>(token.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (thumbUrl.present) {
      map['thumb_url'] = Variable<String>(thumbUrl.value);
    }
    if (category.present) {
      map['category'] = Variable<String>(category.value);
    }
    if (rating.present) {
      map['rating'] = Variable<double>(rating.value);
    }
    if (fileCount.present) {
      map['file_count'] = Variable<int>(fileCount.value);
    }
    if (slot.present) {
      map['slot'] = Variable<int>(slot.value);
    }
    if (addedAt.present) {
      map['added_at'] = Variable<DateTime>(addedAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('LocalFavoritesCompanion(')
          ..write('gid: $gid, ')
          ..write('token: $token, ')
          ..write('title: $title, ')
          ..write('thumbUrl: $thumbUrl, ')
          ..write('category: $category, ')
          ..write('rating: $rating, ')
          ..write('fileCount: $fileCount, ')
          ..write('slot: $slot, ')
          ..write('addedAt: $addedAt')
          ..write(')'))
        .toString();
  }
}

class $DownloadTasksTable extends DownloadTasks
    with TableInfo<$DownloadTasksTable, DownloadTask> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $DownloadTasksTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _gidMeta = const VerificationMeta('gid');
  @override
  late final GeneratedColumn<int> gid = GeneratedColumn<int>(
      'gid', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _tokenMeta = const VerificationMeta('token');
  @override
  late final GeneratedColumn<String> token = GeneratedColumn<String>(
      'token', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
      'title', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _thumbUrlMeta =
      const VerificationMeta('thumbUrl');
  @override
  late final GeneratedColumn<String> thumbUrl = GeneratedColumn<String>(
      'thumb_url', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _totalPagesMeta =
      const VerificationMeta('totalPages');
  @override
  late final GeneratedColumn<int> totalPages = GeneratedColumn<int>(
      'total_pages', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _downloadedPagesMeta =
      const VerificationMeta('downloadedPages');
  @override
  late final GeneratedColumn<int> downloadedPages = GeneratedColumn<int>(
      'downloaded_pages', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _statusMeta = const VerificationMeta('status');
  @override
  late final GeneratedColumn<int> status = GeneratedColumn<int>(
      'status', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _createdAtMeta =
      const VerificationMeta('createdAt');
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
      'created_at', aliasedName, false,
      type: DriftSqlType.dateTime, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns => [
        gid,
        token,
        title,
        thumbUrl,
        totalPages,
        downloadedPages,
        status,
        createdAt
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'download_tasks';
  @override
  VerificationContext validateIntegrity(Insertable<DownloadTask> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('gid')) {
      context.handle(
          _gidMeta, gid.isAcceptableOrUnknown(data['gid']!, _gidMeta));
    }
    if (data.containsKey('token')) {
      context.handle(
          _tokenMeta, token.isAcceptableOrUnknown(data['token']!, _tokenMeta));
    } else if (isInserting) {
      context.missing(_tokenMeta);
    }
    if (data.containsKey('title')) {
      context.handle(
          _titleMeta, title.isAcceptableOrUnknown(data['title']!, _titleMeta));
    } else if (isInserting) {
      context.missing(_titleMeta);
    }
    if (data.containsKey('thumb_url')) {
      context.handle(_thumbUrlMeta,
          thumbUrl.isAcceptableOrUnknown(data['thumb_url']!, _thumbUrlMeta));
    } else if (isInserting) {
      context.missing(_thumbUrlMeta);
    }
    if (data.containsKey('total_pages')) {
      context.handle(
          _totalPagesMeta,
          totalPages.isAcceptableOrUnknown(
              data['total_pages']!, _totalPagesMeta));
    } else if (isInserting) {
      context.missing(_totalPagesMeta);
    }
    if (data.containsKey('downloaded_pages')) {
      context.handle(
          _downloadedPagesMeta,
          downloadedPages.isAcceptableOrUnknown(
              data['downloaded_pages']!, _downloadedPagesMeta));
    }
    if (data.containsKey('status')) {
      context.handle(_statusMeta,
          status.isAcceptableOrUnknown(data['status']!, _statusMeta));
    }
    if (data.containsKey('created_at')) {
      context.handle(_createdAtMeta,
          createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta));
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {gid};
  @override
  DownloadTask map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return DownloadTask(
      gid: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}gid'])!,
      token: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}token'])!,
      title: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}title'])!,
      thumbUrl: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}thumb_url'])!,
      totalPages: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}total_pages'])!,
      downloadedPages: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}downloaded_pages'])!,
      status: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}status'])!,
      createdAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}created_at'])!,
    );
  }

  @override
  $DownloadTasksTable createAlias(String alias) {
    return $DownloadTasksTable(attachedDatabase, alias);
  }
}

class DownloadTask extends DataClass implements Insertable<DownloadTask> {
  final int gid;
  final String token;
  final String title;
  final String thumbUrl;
  final int totalPages;
  final int downloadedPages;
  final int status;
  final DateTime createdAt;
  const DownloadTask(
      {required this.gid,
      required this.token,
      required this.title,
      required this.thumbUrl,
      required this.totalPages,
      required this.downloadedPages,
      required this.status,
      required this.createdAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['gid'] = Variable<int>(gid);
    map['token'] = Variable<String>(token);
    map['title'] = Variable<String>(title);
    map['thumb_url'] = Variable<String>(thumbUrl);
    map['total_pages'] = Variable<int>(totalPages);
    map['downloaded_pages'] = Variable<int>(downloadedPages);
    map['status'] = Variable<int>(status);
    map['created_at'] = Variable<DateTime>(createdAt);
    return map;
  }

  DownloadTasksCompanion toCompanion(bool nullToAbsent) {
    return DownloadTasksCompanion(
      gid: Value(gid),
      token: Value(token),
      title: Value(title),
      thumbUrl: Value(thumbUrl),
      totalPages: Value(totalPages),
      downloadedPages: Value(downloadedPages),
      status: Value(status),
      createdAt: Value(createdAt),
    );
  }

  factory DownloadTask.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return DownloadTask(
      gid: serializer.fromJson<int>(json['gid']),
      token: serializer.fromJson<String>(json['token']),
      title: serializer.fromJson<String>(json['title']),
      thumbUrl: serializer.fromJson<String>(json['thumbUrl']),
      totalPages: serializer.fromJson<int>(json['totalPages']),
      downloadedPages: serializer.fromJson<int>(json['downloadedPages']),
      status: serializer.fromJson<int>(json['status']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'gid': serializer.toJson<int>(gid),
      'token': serializer.toJson<String>(token),
      'title': serializer.toJson<String>(title),
      'thumbUrl': serializer.toJson<String>(thumbUrl),
      'totalPages': serializer.toJson<int>(totalPages),
      'downloadedPages': serializer.toJson<int>(downloadedPages),
      'status': serializer.toJson<int>(status),
      'createdAt': serializer.toJson<DateTime>(createdAt),
    };
  }

  DownloadTask copyWith(
          {int? gid,
          String? token,
          String? title,
          String? thumbUrl,
          int? totalPages,
          int? downloadedPages,
          int? status,
          DateTime? createdAt}) =>
      DownloadTask(
        gid: gid ?? this.gid,
        token: token ?? this.token,
        title: title ?? this.title,
        thumbUrl: thumbUrl ?? this.thumbUrl,
        totalPages: totalPages ?? this.totalPages,
        downloadedPages: downloadedPages ?? this.downloadedPages,
        status: status ?? this.status,
        createdAt: createdAt ?? this.createdAt,
      );
  @override
  String toString() {
    return (StringBuffer('DownloadTask(')
          ..write('gid: $gid, ')
          ..write('token: $token, ')
          ..write('title: $title, ')
          ..write('thumbUrl: $thumbUrl, ')
          ..write('totalPages: $totalPages, ')
          ..write('downloadedPages: $downloadedPages, ')
          ..write('status: $status, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(gid, token, title, thumbUrl, totalPages,
      downloadedPages, status, createdAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is DownloadTask &&
          other.gid == this.gid &&
          other.token == this.token &&
          other.title == this.title &&
          other.thumbUrl == this.thumbUrl &&
          other.totalPages == this.totalPages &&
          other.downloadedPages == this.downloadedPages &&
          other.status == this.status &&
          other.createdAt == this.createdAt);
}

class DownloadTasksCompanion extends UpdateCompanion<DownloadTask> {
  final Value<int> gid;
  final Value<String> token;
  final Value<String> title;
  final Value<String> thumbUrl;
  final Value<int> totalPages;
  final Value<int> downloadedPages;
  final Value<int> status;
  final Value<DateTime> createdAt;
  const DownloadTasksCompanion({
    this.gid = const Value.absent(),
    this.token = const Value.absent(),
    this.title = const Value.absent(),
    this.thumbUrl = const Value.absent(),
    this.totalPages = const Value.absent(),
    this.downloadedPages = const Value.absent(),
    this.status = const Value.absent(),
    this.createdAt = const Value.absent(),
  });
  DownloadTasksCompanion.insert({
    this.gid = const Value.absent(),
    required String token,
    required String title,
    required String thumbUrl,
    required int totalPages,
    this.downloadedPages = const Value.absent(),
    this.status = const Value.absent(),
    required DateTime createdAt,
  })  : token = Value(token),
        title = Value(title),
        thumbUrl = Value(thumbUrl),
        totalPages = Value(totalPages),
        createdAt = Value(createdAt);
  static Insertable<DownloadTask> custom({
    Expression<int>? gid,
    Expression<String>? token,
    Expression<String>? title,
    Expression<String>? thumbUrl,
    Expression<int>? totalPages,
    Expression<int>? downloadedPages,
    Expression<int>? status,
    Expression<DateTime>? createdAt,
  }) {
    return RawValuesInsertable({
      if (gid != null) 'gid': gid,
      if (token != null) 'token': token,
      if (title != null) 'title': title,
      if (thumbUrl != null) 'thumb_url': thumbUrl,
      if (totalPages != null) 'total_pages': totalPages,
      if (downloadedPages != null) 'downloaded_pages': downloadedPages,
      if (status != null) 'status': status,
      if (createdAt != null) 'created_at': createdAt,
    });
  }

  DownloadTasksCompanion copyWith(
      {Value<int>? gid,
      Value<String>? token,
      Value<String>? title,
      Value<String>? thumbUrl,
      Value<int>? totalPages,
      Value<int>? downloadedPages,
      Value<int>? status,
      Value<DateTime>? createdAt}) {
    return DownloadTasksCompanion(
      gid: gid ?? this.gid,
      token: token ?? this.token,
      title: title ?? this.title,
      thumbUrl: thumbUrl ?? this.thumbUrl,
      totalPages: totalPages ?? this.totalPages,
      downloadedPages: downloadedPages ?? this.downloadedPages,
      status: status ?? this.status,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (gid.present) {
      map['gid'] = Variable<int>(gid.value);
    }
    if (token.present) {
      map['token'] = Variable<String>(token.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (thumbUrl.present) {
      map['thumb_url'] = Variable<String>(thumbUrl.value);
    }
    if (totalPages.present) {
      map['total_pages'] = Variable<int>(totalPages.value);
    }
    if (downloadedPages.present) {
      map['downloaded_pages'] = Variable<int>(downloadedPages.value);
    }
    if (status.present) {
      map['status'] = Variable<int>(status.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('DownloadTasksCompanion(')
          ..write('gid: $gid, ')
          ..write('token: $token, ')
          ..write('title: $title, ')
          ..write('thumbUrl: $thumbUrl, ')
          ..write('totalPages: $totalPages, ')
          ..write('downloadedPages: $downloadedPages, ')
          ..write('status: $status, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }
}

class $GalleryWarningAcceptancesTable extends GalleryWarningAcceptances
    with TableInfo<$GalleryWarningAcceptancesTable, GalleryWarningAcceptance> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $GalleryWarningAcceptancesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _gidMeta = const VerificationMeta('gid');
  @override
  late final GeneratedColumn<int> gid = GeneratedColumn<int>(
      'gid', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _tokenMeta = const VerificationMeta('token');
  @override
  late final GeneratedColumn<String> token = GeneratedColumn<String>(
      'token', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns => [gid, token];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'gallery_warning_acceptances';
  @override
  VerificationContext validateIntegrity(
      Insertable<GalleryWarningAcceptance> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('gid')) {
      context.handle(
          _gidMeta, gid.isAcceptableOrUnknown(data['gid']!, _gidMeta));
    }
    if (data.containsKey('token')) {
      context.handle(
          _tokenMeta, token.isAcceptableOrUnknown(data['token']!, _tokenMeta));
    } else if (isInserting) {
      context.missing(_tokenMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {gid};
  @override
  GalleryWarningAcceptance map(Map<String, dynamic> data,
      {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return GalleryWarningAcceptance(
      gid: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}gid'])!,
      token: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}token'])!,
    );
  }

  @override
  $GalleryWarningAcceptancesTable createAlias(String alias) {
    return $GalleryWarningAcceptancesTable(attachedDatabase, alias);
  }
}

class GalleryWarningAcceptance extends DataClass
    implements Insertable<GalleryWarningAcceptance> {
  final int gid;
  final String token;
  const GalleryWarningAcceptance({required this.gid, required this.token});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['gid'] = Variable<int>(gid);
    map['token'] = Variable<String>(token);
    return map;
  }

  GalleryWarningAcceptancesCompanion toCompanion(bool nullToAbsent) {
    return GalleryWarningAcceptancesCompanion(
      gid: Value(gid),
      token: Value(token),
    );
  }

  factory GalleryWarningAcceptance.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return GalleryWarningAcceptance(
      gid: serializer.fromJson<int>(json['gid']),
      token: serializer.fromJson<String>(json['token']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'gid': serializer.toJson<int>(gid),
      'token': serializer.toJson<String>(token),
    };
  }

  GalleryWarningAcceptance copyWith({int? gid, String? token}) =>
      GalleryWarningAcceptance(
        gid: gid ?? this.gid,
        token: token ?? this.token,
      );
  @override
  String toString() {
    return (StringBuffer('GalleryWarningAcceptance(')
          ..write('gid: $gid, ')
          ..write('token: $token')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(gid, token);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is GalleryWarningAcceptance &&
          other.gid == this.gid &&
          other.token == this.token);
}

class GalleryWarningAcceptancesCompanion
    extends UpdateCompanion<GalleryWarningAcceptance> {
  final Value<int> gid;
  final Value<String> token;
  const GalleryWarningAcceptancesCompanion({
    this.gid = const Value.absent(),
    this.token = const Value.absent(),
  });
  GalleryWarningAcceptancesCompanion.insert({
    this.gid = const Value.absent(),
    required String token,
  }) : token = Value(token);
  static Insertable<GalleryWarningAcceptance> custom({
    Expression<int>? gid,
    Expression<String>? token,
  }) {
    return RawValuesInsertable({
      if (gid != null) 'gid': gid,
      if (token != null) 'token': token,
    });
  }

  GalleryWarningAcceptancesCompanion copyWith(
      {Value<int>? gid, Value<String>? token}) {
    return GalleryWarningAcceptancesCompanion(
      gid: gid ?? this.gid,
      token: token ?? this.token,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (gid.present) {
      map['gid'] = Variable<int>(gid.value);
    }
    if (token.present) {
      map['token'] = Variable<String>(token.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('GalleryWarningAcceptancesCompanion(')
          ..write('gid: $gid, ')
          ..write('token: $token')
          ..write(')'))
        .toString();
  }
}

class $OfflineGalleriesTable extends OfflineGalleries
    with TableInfo<$OfflineGalleriesTable, OfflineGallery> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $OfflineGalleriesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
      'id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _sourceMeta = const VerificationMeta('source');
  @override
  late final GeneratedColumn<String> source = GeneratedColumn<String>(
      'source', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _gidMeta = const VerificationMeta('gid');
  @override
  late final GeneratedColumn<int> gid = GeneratedColumn<int>(
      'gid', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _tokenMeta = const VerificationMeta('token');
  @override
  late final GeneratedColumn<String> token = GeneratedColumn<String>(
      'token', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
      'title', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _totalPagesMeta =
      const VerificationMeta('totalPages');
  @override
  late final GeneratedColumn<int> totalPages = GeneratedColumn<int>(
      'total_pages', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _statusMeta = const VerificationMeta('status');
  @override
  late final GeneratedColumn<String> status = GeneratedColumn<String>(
      'status', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant('paused'));
  static const VerificationMeta _reasonMeta = const VerificationMeta('reason');
  @override
  late final GeneratedColumn<String> reason = GeneratedColumn<String>(
      'reason', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _createdAtMeta =
      const VerificationMeta('createdAt');
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
      'created_at', aliasedName, false,
      type: DriftSqlType.dateTime, requiredDuringInsert: true);
  static const VerificationMeta _lastReadPageMeta =
      const VerificationMeta('lastReadPage');
  @override
  late final GeneratedColumn<int> lastReadPage = GeneratedColumn<int>(
      'last_read_page', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _indexReadyMeta =
      const VerificationMeta('indexReady');
  @override
  late final GeneratedColumn<bool> indexReady = GeneratedColumn<bool>(
      'index_ready', aliasedName, false,
      type: DriftSqlType.bool,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('CHECK ("index_ready" IN (0, 1))'),
      defaultValue: const Constant(false));
  static const VerificationMeta _indexNeedsRefreshMeta =
      const VerificationMeta('indexNeedsRefresh');
  @override
  late final GeneratedColumn<bool> indexNeedsRefresh = GeneratedColumn<bool>(
      'index_needs_refresh', aliasedName, false,
      type: DriftSqlType.bool,
      requiredDuringInsert: false,
      defaultConstraints: GeneratedColumn.constraintIsAlways(
          'CHECK ("index_needs_refresh" IN (0, 1))'),
      defaultValue: const Constant(false));
  static const VerificationMeta _everCompletedMeta =
      const VerificationMeta('everCompleted');
  @override
  late final GeneratedColumn<bool> everCompleted = GeneratedColumn<bool>(
      'ever_completed', aliasedName, false,
      type: DriftSqlType.bool,
      requiredDuringInsert: false,
      defaultConstraints: GeneratedColumn.constraintIsAlways(
          'CHECK ("ever_completed" IN (0, 1))'),
      defaultValue: const Constant(false));
  static const VerificationMeta _legacyGidMeta =
      const VerificationMeta('legacyGid');
  @override
  late final GeneratedColumn<int> legacyGid = GeneratedColumn<int>(
      'legacy_gid', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  @override
  List<GeneratedColumn> get $columns => [
        id,
        source,
        gid,
        token,
        title,
        totalPages,
        status,
        reason,
        createdAt,
        lastReadPage,
        indexReady,
        indexNeedsRefresh,
        everCompleted,
        legacyGid
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'offline_galleries';
  @override
  VerificationContext validateIntegrity(Insertable<OfflineGallery> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('source')) {
      context.handle(_sourceMeta,
          source.isAcceptableOrUnknown(data['source']!, _sourceMeta));
    }
    if (data.containsKey('gid')) {
      context.handle(
          _gidMeta, gid.isAcceptableOrUnknown(data['gid']!, _gidMeta));
    } else if (isInserting) {
      context.missing(_gidMeta);
    }
    if (data.containsKey('token')) {
      context.handle(
          _tokenMeta, token.isAcceptableOrUnknown(data['token']!, _tokenMeta));
    } else if (isInserting) {
      context.missing(_tokenMeta);
    }
    if (data.containsKey('title')) {
      context.handle(
          _titleMeta, title.isAcceptableOrUnknown(data['title']!, _titleMeta));
    } else if (isInserting) {
      context.missing(_titleMeta);
    }
    if (data.containsKey('total_pages')) {
      context.handle(
          _totalPagesMeta,
          totalPages.isAcceptableOrUnknown(
              data['total_pages']!, _totalPagesMeta));
    } else if (isInserting) {
      context.missing(_totalPagesMeta);
    }
    if (data.containsKey('status')) {
      context.handle(_statusMeta,
          status.isAcceptableOrUnknown(data['status']!, _statusMeta));
    }
    if (data.containsKey('reason')) {
      context.handle(_reasonMeta,
          reason.isAcceptableOrUnknown(data['reason']!, _reasonMeta));
    }
    if (data.containsKey('created_at')) {
      context.handle(_createdAtMeta,
          createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta));
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('last_read_page')) {
      context.handle(
          _lastReadPageMeta,
          lastReadPage.isAcceptableOrUnknown(
              data['last_read_page']!, _lastReadPageMeta));
    }
    if (data.containsKey('index_ready')) {
      context.handle(
          _indexReadyMeta,
          indexReady.isAcceptableOrUnknown(
              data['index_ready']!, _indexReadyMeta));
    }
    if (data.containsKey('index_needs_refresh')) {
      context.handle(
          _indexNeedsRefreshMeta,
          indexNeedsRefresh.isAcceptableOrUnknown(
              data['index_needs_refresh']!, _indexNeedsRefreshMeta));
    }
    if (data.containsKey('ever_completed')) {
      context.handle(
          _everCompletedMeta,
          everCompleted.isAcceptableOrUnknown(
              data['ever_completed']!, _everCompletedMeta));
    }
    if (data.containsKey('legacy_gid')) {
      context.handle(_legacyGidMeta,
          legacyGid.isAcceptableOrUnknown(data['legacy_gid']!, _legacyGidMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  OfflineGallery map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return OfflineGallery(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}id'])!,
      source: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}source']),
      gid: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}gid'])!,
      token: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}token'])!,
      title: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}title'])!,
      totalPages: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}total_pages'])!,
      status: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}status'])!,
      reason: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}reason']),
      createdAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}created_at'])!,
      lastReadPage: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}last_read_page'])!,
      indexReady: attachedDatabase.typeMapping
          .read(DriftSqlType.bool, data['${effectivePrefix}index_ready'])!,
      indexNeedsRefresh: attachedDatabase.typeMapping.read(
          DriftSqlType.bool, data['${effectivePrefix}index_needs_refresh'])!,
      everCompleted: attachedDatabase.typeMapping
          .read(DriftSqlType.bool, data['${effectivePrefix}ever_completed'])!,
      legacyGid: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}legacy_gid']),
    );
  }

  @override
  $OfflineGalleriesTable createAlias(String alias) {
    return $OfflineGalleriesTable(attachedDatabase, alias);
  }
}

class OfflineGallery extends DataClass implements Insertable<OfflineGallery> {
  final String id;
  final String? source;
  final int gid;
  final String token;
  final String title;
  final int totalPages;
  final String status;
  final String? reason;
  final DateTime createdAt;
  final int lastReadPage;
  final bool indexReady;
  final bool indexNeedsRefresh;
  final bool everCompleted;
  final int? legacyGid;
  const OfflineGallery(
      {required this.id,
      this.source,
      required this.gid,
      required this.token,
      required this.title,
      required this.totalPages,
      required this.status,
      this.reason,
      required this.createdAt,
      required this.lastReadPage,
      required this.indexReady,
      required this.indexNeedsRefresh,
      required this.everCompleted,
      this.legacyGid});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    if (!nullToAbsent || source != null) {
      map['source'] = Variable<String>(source);
    }
    map['gid'] = Variable<int>(gid);
    map['token'] = Variable<String>(token);
    map['title'] = Variable<String>(title);
    map['total_pages'] = Variable<int>(totalPages);
    map['status'] = Variable<String>(status);
    if (!nullToAbsent || reason != null) {
      map['reason'] = Variable<String>(reason);
    }
    map['created_at'] = Variable<DateTime>(createdAt);
    map['last_read_page'] = Variable<int>(lastReadPage);
    map['index_ready'] = Variable<bool>(indexReady);
    map['index_needs_refresh'] = Variable<bool>(indexNeedsRefresh);
    map['ever_completed'] = Variable<bool>(everCompleted);
    if (!nullToAbsent || legacyGid != null) {
      map['legacy_gid'] = Variable<int>(legacyGid);
    }
    return map;
  }

  OfflineGalleriesCompanion toCompanion(bool nullToAbsent) {
    return OfflineGalleriesCompanion(
      id: Value(id),
      source:
          source == null && nullToAbsent ? const Value.absent() : Value(source),
      gid: Value(gid),
      token: Value(token),
      title: Value(title),
      totalPages: Value(totalPages),
      status: Value(status),
      reason:
          reason == null && nullToAbsent ? const Value.absent() : Value(reason),
      createdAt: Value(createdAt),
      lastReadPage: Value(lastReadPage),
      indexReady: Value(indexReady),
      indexNeedsRefresh: Value(indexNeedsRefresh),
      everCompleted: Value(everCompleted),
      legacyGid: legacyGid == null && nullToAbsent
          ? const Value.absent()
          : Value(legacyGid),
    );
  }

  factory OfflineGallery.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return OfflineGallery(
      id: serializer.fromJson<String>(json['id']),
      source: serializer.fromJson<String?>(json['source']),
      gid: serializer.fromJson<int>(json['gid']),
      token: serializer.fromJson<String>(json['token']),
      title: serializer.fromJson<String>(json['title']),
      totalPages: serializer.fromJson<int>(json['totalPages']),
      status: serializer.fromJson<String>(json['status']),
      reason: serializer.fromJson<String?>(json['reason']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
      lastReadPage: serializer.fromJson<int>(json['lastReadPage']),
      indexReady: serializer.fromJson<bool>(json['indexReady']),
      indexNeedsRefresh: serializer.fromJson<bool>(json['indexNeedsRefresh']),
      everCompleted: serializer.fromJson<bool>(json['everCompleted']),
      legacyGid: serializer.fromJson<int?>(json['legacyGid']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'source': serializer.toJson<String?>(source),
      'gid': serializer.toJson<int>(gid),
      'token': serializer.toJson<String>(token),
      'title': serializer.toJson<String>(title),
      'totalPages': serializer.toJson<int>(totalPages),
      'status': serializer.toJson<String>(status),
      'reason': serializer.toJson<String?>(reason),
      'createdAt': serializer.toJson<DateTime>(createdAt),
      'lastReadPage': serializer.toJson<int>(lastReadPage),
      'indexReady': serializer.toJson<bool>(indexReady),
      'indexNeedsRefresh': serializer.toJson<bool>(indexNeedsRefresh),
      'everCompleted': serializer.toJson<bool>(everCompleted),
      'legacyGid': serializer.toJson<int?>(legacyGid),
    };
  }

  OfflineGallery copyWith(
          {String? id,
          Value<String?> source = const Value.absent(),
          int? gid,
          String? token,
          String? title,
          int? totalPages,
          String? status,
          Value<String?> reason = const Value.absent(),
          DateTime? createdAt,
          int? lastReadPage,
          bool? indexReady,
          bool? indexNeedsRefresh,
          bool? everCompleted,
          Value<int?> legacyGid = const Value.absent()}) =>
      OfflineGallery(
        id: id ?? this.id,
        source: source.present ? source.value : this.source,
        gid: gid ?? this.gid,
        token: token ?? this.token,
        title: title ?? this.title,
        totalPages: totalPages ?? this.totalPages,
        status: status ?? this.status,
        reason: reason.present ? reason.value : this.reason,
        createdAt: createdAt ?? this.createdAt,
        lastReadPage: lastReadPage ?? this.lastReadPage,
        indexReady: indexReady ?? this.indexReady,
        indexNeedsRefresh: indexNeedsRefresh ?? this.indexNeedsRefresh,
        everCompleted: everCompleted ?? this.everCompleted,
        legacyGid: legacyGid.present ? legacyGid.value : this.legacyGid,
      );
  @override
  String toString() {
    return (StringBuffer('OfflineGallery(')
          ..write('id: $id, ')
          ..write('source: $source, ')
          ..write('gid: $gid, ')
          ..write('token: $token, ')
          ..write('title: $title, ')
          ..write('totalPages: $totalPages, ')
          ..write('status: $status, ')
          ..write('reason: $reason, ')
          ..write('createdAt: $createdAt, ')
          ..write('lastReadPage: $lastReadPage, ')
          ..write('indexReady: $indexReady, ')
          ..write('indexNeedsRefresh: $indexNeedsRefresh, ')
          ..write('everCompleted: $everCompleted, ')
          ..write('legacyGid: $legacyGid')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
      id,
      source,
      gid,
      token,
      title,
      totalPages,
      status,
      reason,
      createdAt,
      lastReadPage,
      indexReady,
      indexNeedsRefresh,
      everCompleted,
      legacyGid);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is OfflineGallery &&
          other.id == this.id &&
          other.source == this.source &&
          other.gid == this.gid &&
          other.token == this.token &&
          other.title == this.title &&
          other.totalPages == this.totalPages &&
          other.status == this.status &&
          other.reason == this.reason &&
          other.createdAt == this.createdAt &&
          other.lastReadPage == this.lastReadPage &&
          other.indexReady == this.indexReady &&
          other.indexNeedsRefresh == this.indexNeedsRefresh &&
          other.everCompleted == this.everCompleted &&
          other.legacyGid == this.legacyGid);
}

class OfflineGalleriesCompanion extends UpdateCompanion<OfflineGallery> {
  final Value<String> id;
  final Value<String?> source;
  final Value<int> gid;
  final Value<String> token;
  final Value<String> title;
  final Value<int> totalPages;
  final Value<String> status;
  final Value<String?> reason;
  final Value<DateTime> createdAt;
  final Value<int> lastReadPage;
  final Value<bool> indexReady;
  final Value<bool> indexNeedsRefresh;
  final Value<bool> everCompleted;
  final Value<int?> legacyGid;
  final Value<int> rowid;
  const OfflineGalleriesCompanion({
    this.id = const Value.absent(),
    this.source = const Value.absent(),
    this.gid = const Value.absent(),
    this.token = const Value.absent(),
    this.title = const Value.absent(),
    this.totalPages = const Value.absent(),
    this.status = const Value.absent(),
    this.reason = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.lastReadPage = const Value.absent(),
    this.indexReady = const Value.absent(),
    this.indexNeedsRefresh = const Value.absent(),
    this.everCompleted = const Value.absent(),
    this.legacyGid = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  OfflineGalleriesCompanion.insert({
    required String id,
    this.source = const Value.absent(),
    required int gid,
    required String token,
    required String title,
    required int totalPages,
    this.status = const Value.absent(),
    this.reason = const Value.absent(),
    required DateTime createdAt,
    this.lastReadPage = const Value.absent(),
    this.indexReady = const Value.absent(),
    this.indexNeedsRefresh = const Value.absent(),
    this.everCompleted = const Value.absent(),
    this.legacyGid = const Value.absent(),
    this.rowid = const Value.absent(),
  })  : id = Value(id),
        gid = Value(gid),
        token = Value(token),
        title = Value(title),
        totalPages = Value(totalPages),
        createdAt = Value(createdAt);
  static Insertable<OfflineGallery> custom({
    Expression<String>? id,
    Expression<String>? source,
    Expression<int>? gid,
    Expression<String>? token,
    Expression<String>? title,
    Expression<int>? totalPages,
    Expression<String>? status,
    Expression<String>? reason,
    Expression<DateTime>? createdAt,
    Expression<int>? lastReadPage,
    Expression<bool>? indexReady,
    Expression<bool>? indexNeedsRefresh,
    Expression<bool>? everCompleted,
    Expression<int>? legacyGid,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (source != null) 'source': source,
      if (gid != null) 'gid': gid,
      if (token != null) 'token': token,
      if (title != null) 'title': title,
      if (totalPages != null) 'total_pages': totalPages,
      if (status != null) 'status': status,
      if (reason != null) 'reason': reason,
      if (createdAt != null) 'created_at': createdAt,
      if (lastReadPage != null) 'last_read_page': lastReadPage,
      if (indexReady != null) 'index_ready': indexReady,
      if (indexNeedsRefresh != null) 'index_needs_refresh': indexNeedsRefresh,
      if (everCompleted != null) 'ever_completed': everCompleted,
      if (legacyGid != null) 'legacy_gid': legacyGid,
      if (rowid != null) 'rowid': rowid,
    });
  }

  OfflineGalleriesCompanion copyWith(
      {Value<String>? id,
      Value<String?>? source,
      Value<int>? gid,
      Value<String>? token,
      Value<String>? title,
      Value<int>? totalPages,
      Value<String>? status,
      Value<String?>? reason,
      Value<DateTime>? createdAt,
      Value<int>? lastReadPage,
      Value<bool>? indexReady,
      Value<bool>? indexNeedsRefresh,
      Value<bool>? everCompleted,
      Value<int?>? legacyGid,
      Value<int>? rowid}) {
    return OfflineGalleriesCompanion(
      id: id ?? this.id,
      source: source ?? this.source,
      gid: gid ?? this.gid,
      token: token ?? this.token,
      title: title ?? this.title,
      totalPages: totalPages ?? this.totalPages,
      status: status ?? this.status,
      reason: reason ?? this.reason,
      createdAt: createdAt ?? this.createdAt,
      lastReadPage: lastReadPage ?? this.lastReadPage,
      indexReady: indexReady ?? this.indexReady,
      indexNeedsRefresh: indexNeedsRefresh ?? this.indexNeedsRefresh,
      everCompleted: everCompleted ?? this.everCompleted,
      legacyGid: legacyGid ?? this.legacyGid,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (source.present) {
      map['source'] = Variable<String>(source.value);
    }
    if (gid.present) {
      map['gid'] = Variable<int>(gid.value);
    }
    if (token.present) {
      map['token'] = Variable<String>(token.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (totalPages.present) {
      map['total_pages'] = Variable<int>(totalPages.value);
    }
    if (status.present) {
      map['status'] = Variable<String>(status.value);
    }
    if (reason.present) {
      map['reason'] = Variable<String>(reason.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (lastReadPage.present) {
      map['last_read_page'] = Variable<int>(lastReadPage.value);
    }
    if (indexReady.present) {
      map['index_ready'] = Variable<bool>(indexReady.value);
    }
    if (indexNeedsRefresh.present) {
      map['index_needs_refresh'] = Variable<bool>(indexNeedsRefresh.value);
    }
    if (everCompleted.present) {
      map['ever_completed'] = Variable<bool>(everCompleted.value);
    }
    if (legacyGid.present) {
      map['legacy_gid'] = Variable<int>(legacyGid.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('OfflineGalleriesCompanion(')
          ..write('id: $id, ')
          ..write('source: $source, ')
          ..write('gid: $gid, ')
          ..write('token: $token, ')
          ..write('title: $title, ')
          ..write('totalPages: $totalPages, ')
          ..write('status: $status, ')
          ..write('reason: $reason, ')
          ..write('createdAt: $createdAt, ')
          ..write('lastReadPage: $lastReadPage, ')
          ..write('indexReady: $indexReady, ')
          ..write('indexNeedsRefresh: $indexNeedsRefresh, ')
          ..write('everCompleted: $everCompleted, ')
          ..write('legacyGid: $legacyGid, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $OfflinePagesTable extends OfflinePages
    with TableInfo<$OfflinePagesTable, OfflinePage> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $OfflinePagesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _bookIdMeta = const VerificationMeta('bookId');
  @override
  late final GeneratedColumn<String> bookId = GeneratedColumn<String>(
      'book_id', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: true,
      defaultConstraints: GeneratedColumn.constraintIsAlways(
          'REFERENCES offline_galleries (id)'));
  static const VerificationMeta _pageIndexMeta =
      const VerificationMeta('pageIndex');
  @override
  late final GeneratedColumn<int> pageIndex = GeneratedColumn<int>(
      'page_index', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _pageTokenMeta =
      const VerificationMeta('pageToken');
  @override
  late final GeneratedColumn<String> pageToken = GeneratedColumn<String>(
      'page_token', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _relativePathMeta =
      const VerificationMeta('relativePath');
  @override
  late final GeneratedColumn<String> relativePath = GeneratedColumn<String>(
      'relative_path', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _formatMeta = const VerificationMeta('format');
  @override
  late final GeneratedColumn<String> format = GeneratedColumn<String>(
      'format', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _bytesMeta = const VerificationMeta('bytes');
  @override
  late final GeneratedColumn<int> bytes = GeneratedColumn<int>(
      'bytes', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _sha256Meta = const VerificationMeta('sha256');
  @override
  late final GeneratedColumn<String> sha256 = GeneratedColumn<String>(
      'sha256', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _statusMeta = const VerificationMeta('status');
  @override
  late final GeneratedColumn<String> status = GeneratedColumn<String>(
      'status', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant('pending'));
  static const VerificationMeta _errorMeta = const VerificationMeta('error');
  @override
  late final GeneratedColumn<String> error = GeneratedColumn<String>(
      'error', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _verificationVersionMeta =
      const VerificationMeta('verificationVersion');
  @override
  late final GeneratedColumn<int> verificationVersion = GeneratedColumn<int>(
      'verification_version', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _verifiedModifiedMicrosMeta =
      const VerificationMeta('verifiedModifiedMicros');
  @override
  late final GeneratedColumn<int> verifiedModifiedMicros = GeneratedColumn<int>(
      'verified_modified_micros', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _verifiedChangedMicrosMeta =
      const VerificationMeta('verifiedChangedMicros');
  @override
  late final GeneratedColumn<int> verifiedChangedMicros = GeneratedColumn<int>(
      'verified_changed_micros', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  @override
  List<GeneratedColumn> get $columns => [
        bookId,
        pageIndex,
        pageToken,
        relativePath,
        format,
        bytes,
        sha256,
        status,
        error,
        verificationVersion,
        verifiedModifiedMicros,
        verifiedChangedMicros
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'offline_pages';
  @override
  VerificationContext validateIntegrity(Insertable<OfflinePage> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('book_id')) {
      context.handle(_bookIdMeta,
          bookId.isAcceptableOrUnknown(data['book_id']!, _bookIdMeta));
    } else if (isInserting) {
      context.missing(_bookIdMeta);
    }
    if (data.containsKey('page_index')) {
      context.handle(_pageIndexMeta,
          pageIndex.isAcceptableOrUnknown(data['page_index']!, _pageIndexMeta));
    } else if (isInserting) {
      context.missing(_pageIndexMeta);
    }
    if (data.containsKey('page_token')) {
      context.handle(_pageTokenMeta,
          pageToken.isAcceptableOrUnknown(data['page_token']!, _pageTokenMeta));
    } else if (isInserting) {
      context.missing(_pageTokenMeta);
    }
    if (data.containsKey('relative_path')) {
      context.handle(
          _relativePathMeta,
          relativePath.isAcceptableOrUnknown(
              data['relative_path']!, _relativePathMeta));
    }
    if (data.containsKey('format')) {
      context.handle(_formatMeta,
          format.isAcceptableOrUnknown(data['format']!, _formatMeta));
    }
    if (data.containsKey('bytes')) {
      context.handle(
          _bytesMeta, bytes.isAcceptableOrUnknown(data['bytes']!, _bytesMeta));
    }
    if (data.containsKey('sha256')) {
      context.handle(_sha256Meta,
          sha256.isAcceptableOrUnknown(data['sha256']!, _sha256Meta));
    }
    if (data.containsKey('status')) {
      context.handle(_statusMeta,
          status.isAcceptableOrUnknown(data['status']!, _statusMeta));
    }
    if (data.containsKey('error')) {
      context.handle(
          _errorMeta, error.isAcceptableOrUnknown(data['error']!, _errorMeta));
    }
    if (data.containsKey('verification_version')) {
      context.handle(
          _verificationVersionMeta,
          verificationVersion.isAcceptableOrUnknown(
              data['verification_version']!, _verificationVersionMeta));
    }
    if (data.containsKey('verified_modified_micros')) {
      context.handle(
          _verifiedModifiedMicrosMeta,
          verifiedModifiedMicros.isAcceptableOrUnknown(
              data['verified_modified_micros']!, _verifiedModifiedMicrosMeta));
    }
    if (data.containsKey('verified_changed_micros')) {
      context.handle(
          _verifiedChangedMicrosMeta,
          verifiedChangedMicros.isAcceptableOrUnknown(
              data['verified_changed_micros']!, _verifiedChangedMicrosMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {bookId, pageIndex};
  @override
  OfflinePage map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return OfflinePage(
      bookId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}book_id'])!,
      pageIndex: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}page_index'])!,
      pageToken: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}page_token'])!,
      relativePath: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}relative_path']),
      format: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}format']),
      bytes: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}bytes'])!,
      sha256: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}sha256']),
      status: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}status'])!,
      error: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}error']),
      verificationVersion: attachedDatabase.typeMapping.read(
          DriftSqlType.int, data['${effectivePrefix}verification_version'])!,
      verifiedModifiedMicros: attachedDatabase.typeMapping.read(
          DriftSqlType.int, data['${effectivePrefix}verified_modified_micros']),
      verifiedChangedMicros: attachedDatabase.typeMapping.read(
          DriftSqlType.int, data['${effectivePrefix}verified_changed_micros']),
    );
  }

  @override
  $OfflinePagesTable createAlias(String alias) {
    return $OfflinePagesTable(attachedDatabase, alias);
  }
}

class OfflinePage extends DataClass implements Insertable<OfflinePage> {
  final String bookId;
  final int pageIndex;
  final String pageToken;
  final String? relativePath;
  final String? format;
  final int bytes;
  final String? sha256;
  final String status;
  final String? error;
  final int verificationVersion;
  final int? verifiedModifiedMicros;
  final int? verifiedChangedMicros;
  const OfflinePage(
      {required this.bookId,
      required this.pageIndex,
      required this.pageToken,
      this.relativePath,
      this.format,
      required this.bytes,
      this.sha256,
      required this.status,
      this.error,
      required this.verificationVersion,
      this.verifiedModifiedMicros,
      this.verifiedChangedMicros});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['book_id'] = Variable<String>(bookId);
    map['page_index'] = Variable<int>(pageIndex);
    map['page_token'] = Variable<String>(pageToken);
    if (!nullToAbsent || relativePath != null) {
      map['relative_path'] = Variable<String>(relativePath);
    }
    if (!nullToAbsent || format != null) {
      map['format'] = Variable<String>(format);
    }
    map['bytes'] = Variable<int>(bytes);
    if (!nullToAbsent || sha256 != null) {
      map['sha256'] = Variable<String>(sha256);
    }
    map['status'] = Variable<String>(status);
    if (!nullToAbsent || error != null) {
      map['error'] = Variable<String>(error);
    }
    map['verification_version'] = Variable<int>(verificationVersion);
    if (!nullToAbsent || verifiedModifiedMicros != null) {
      map['verified_modified_micros'] = Variable<int>(verifiedModifiedMicros);
    }
    if (!nullToAbsent || verifiedChangedMicros != null) {
      map['verified_changed_micros'] = Variable<int>(verifiedChangedMicros);
    }
    return map;
  }

  OfflinePagesCompanion toCompanion(bool nullToAbsent) {
    return OfflinePagesCompanion(
      bookId: Value(bookId),
      pageIndex: Value(pageIndex),
      pageToken: Value(pageToken),
      relativePath: relativePath == null && nullToAbsent
          ? const Value.absent()
          : Value(relativePath),
      format:
          format == null && nullToAbsent ? const Value.absent() : Value(format),
      bytes: Value(bytes),
      sha256:
          sha256 == null && nullToAbsent ? const Value.absent() : Value(sha256),
      status: Value(status),
      error:
          error == null && nullToAbsent ? const Value.absent() : Value(error),
      verificationVersion: Value(verificationVersion),
      verifiedModifiedMicros: verifiedModifiedMicros == null && nullToAbsent
          ? const Value.absent()
          : Value(verifiedModifiedMicros),
      verifiedChangedMicros: verifiedChangedMicros == null && nullToAbsent
          ? const Value.absent()
          : Value(verifiedChangedMicros),
    );
  }

  factory OfflinePage.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return OfflinePage(
      bookId: serializer.fromJson<String>(json['bookId']),
      pageIndex: serializer.fromJson<int>(json['pageIndex']),
      pageToken: serializer.fromJson<String>(json['pageToken']),
      relativePath: serializer.fromJson<String?>(json['relativePath']),
      format: serializer.fromJson<String?>(json['format']),
      bytes: serializer.fromJson<int>(json['bytes']),
      sha256: serializer.fromJson<String?>(json['sha256']),
      status: serializer.fromJson<String>(json['status']),
      error: serializer.fromJson<String?>(json['error']),
      verificationVersion:
          serializer.fromJson<int>(json['verificationVersion']),
      verifiedModifiedMicros:
          serializer.fromJson<int?>(json['verifiedModifiedMicros']),
      verifiedChangedMicros:
          serializer.fromJson<int?>(json['verifiedChangedMicros']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'bookId': serializer.toJson<String>(bookId),
      'pageIndex': serializer.toJson<int>(pageIndex),
      'pageToken': serializer.toJson<String>(pageToken),
      'relativePath': serializer.toJson<String?>(relativePath),
      'format': serializer.toJson<String?>(format),
      'bytes': serializer.toJson<int>(bytes),
      'sha256': serializer.toJson<String?>(sha256),
      'status': serializer.toJson<String>(status),
      'error': serializer.toJson<String?>(error),
      'verificationVersion': serializer.toJson<int>(verificationVersion),
      'verifiedModifiedMicros': serializer.toJson<int?>(verifiedModifiedMicros),
      'verifiedChangedMicros': serializer.toJson<int?>(verifiedChangedMicros),
    };
  }

  OfflinePage copyWith(
          {String? bookId,
          int? pageIndex,
          String? pageToken,
          Value<String?> relativePath = const Value.absent(),
          Value<String?> format = const Value.absent(),
          int? bytes,
          Value<String?> sha256 = const Value.absent(),
          String? status,
          Value<String?> error = const Value.absent(),
          int? verificationVersion,
          Value<int?> verifiedModifiedMicros = const Value.absent(),
          Value<int?> verifiedChangedMicros = const Value.absent()}) =>
      OfflinePage(
        bookId: bookId ?? this.bookId,
        pageIndex: pageIndex ?? this.pageIndex,
        pageToken: pageToken ?? this.pageToken,
        relativePath:
            relativePath.present ? relativePath.value : this.relativePath,
        format: format.present ? format.value : this.format,
        bytes: bytes ?? this.bytes,
        sha256: sha256.present ? sha256.value : this.sha256,
        status: status ?? this.status,
        error: error.present ? error.value : this.error,
        verificationVersion: verificationVersion ?? this.verificationVersion,
        verifiedModifiedMicros: verifiedModifiedMicros.present
            ? verifiedModifiedMicros.value
            : this.verifiedModifiedMicros,
        verifiedChangedMicros: verifiedChangedMicros.present
            ? verifiedChangedMicros.value
            : this.verifiedChangedMicros,
      );
  @override
  String toString() {
    return (StringBuffer('OfflinePage(')
          ..write('bookId: $bookId, ')
          ..write('pageIndex: $pageIndex, ')
          ..write('pageToken: $pageToken, ')
          ..write('relativePath: $relativePath, ')
          ..write('format: $format, ')
          ..write('bytes: $bytes, ')
          ..write('sha256: $sha256, ')
          ..write('status: $status, ')
          ..write('error: $error, ')
          ..write('verificationVersion: $verificationVersion, ')
          ..write('verifiedModifiedMicros: $verifiedModifiedMicros, ')
          ..write('verifiedChangedMicros: $verifiedChangedMicros')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
      bookId,
      pageIndex,
      pageToken,
      relativePath,
      format,
      bytes,
      sha256,
      status,
      error,
      verificationVersion,
      verifiedModifiedMicros,
      verifiedChangedMicros);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is OfflinePage &&
          other.bookId == this.bookId &&
          other.pageIndex == this.pageIndex &&
          other.pageToken == this.pageToken &&
          other.relativePath == this.relativePath &&
          other.format == this.format &&
          other.bytes == this.bytes &&
          other.sha256 == this.sha256 &&
          other.status == this.status &&
          other.error == this.error &&
          other.verificationVersion == this.verificationVersion &&
          other.verifiedModifiedMicros == this.verifiedModifiedMicros &&
          other.verifiedChangedMicros == this.verifiedChangedMicros);
}

class OfflinePagesCompanion extends UpdateCompanion<OfflinePage> {
  final Value<String> bookId;
  final Value<int> pageIndex;
  final Value<String> pageToken;
  final Value<String?> relativePath;
  final Value<String?> format;
  final Value<int> bytes;
  final Value<String?> sha256;
  final Value<String> status;
  final Value<String?> error;
  final Value<int> verificationVersion;
  final Value<int?> verifiedModifiedMicros;
  final Value<int?> verifiedChangedMicros;
  final Value<int> rowid;
  const OfflinePagesCompanion({
    this.bookId = const Value.absent(),
    this.pageIndex = const Value.absent(),
    this.pageToken = const Value.absent(),
    this.relativePath = const Value.absent(),
    this.format = const Value.absent(),
    this.bytes = const Value.absent(),
    this.sha256 = const Value.absent(),
    this.status = const Value.absent(),
    this.error = const Value.absent(),
    this.verificationVersion = const Value.absent(),
    this.verifiedModifiedMicros = const Value.absent(),
    this.verifiedChangedMicros = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  OfflinePagesCompanion.insert({
    required String bookId,
    required int pageIndex,
    required String pageToken,
    this.relativePath = const Value.absent(),
    this.format = const Value.absent(),
    this.bytes = const Value.absent(),
    this.sha256 = const Value.absent(),
    this.status = const Value.absent(),
    this.error = const Value.absent(),
    this.verificationVersion = const Value.absent(),
    this.verifiedModifiedMicros = const Value.absent(),
    this.verifiedChangedMicros = const Value.absent(),
    this.rowid = const Value.absent(),
  })  : bookId = Value(bookId),
        pageIndex = Value(pageIndex),
        pageToken = Value(pageToken);
  static Insertable<OfflinePage> custom({
    Expression<String>? bookId,
    Expression<int>? pageIndex,
    Expression<String>? pageToken,
    Expression<String>? relativePath,
    Expression<String>? format,
    Expression<int>? bytes,
    Expression<String>? sha256,
    Expression<String>? status,
    Expression<String>? error,
    Expression<int>? verificationVersion,
    Expression<int>? verifiedModifiedMicros,
    Expression<int>? verifiedChangedMicros,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (bookId != null) 'book_id': bookId,
      if (pageIndex != null) 'page_index': pageIndex,
      if (pageToken != null) 'page_token': pageToken,
      if (relativePath != null) 'relative_path': relativePath,
      if (format != null) 'format': format,
      if (bytes != null) 'bytes': bytes,
      if (sha256 != null) 'sha256': sha256,
      if (status != null) 'status': status,
      if (error != null) 'error': error,
      if (verificationVersion != null)
        'verification_version': verificationVersion,
      if (verifiedModifiedMicros != null)
        'verified_modified_micros': verifiedModifiedMicros,
      if (verifiedChangedMicros != null)
        'verified_changed_micros': verifiedChangedMicros,
      if (rowid != null) 'rowid': rowid,
    });
  }

  OfflinePagesCompanion copyWith(
      {Value<String>? bookId,
      Value<int>? pageIndex,
      Value<String>? pageToken,
      Value<String?>? relativePath,
      Value<String?>? format,
      Value<int>? bytes,
      Value<String?>? sha256,
      Value<String>? status,
      Value<String?>? error,
      Value<int>? verificationVersion,
      Value<int?>? verifiedModifiedMicros,
      Value<int?>? verifiedChangedMicros,
      Value<int>? rowid}) {
    return OfflinePagesCompanion(
      bookId: bookId ?? this.bookId,
      pageIndex: pageIndex ?? this.pageIndex,
      pageToken: pageToken ?? this.pageToken,
      relativePath: relativePath ?? this.relativePath,
      format: format ?? this.format,
      bytes: bytes ?? this.bytes,
      sha256: sha256 ?? this.sha256,
      status: status ?? this.status,
      error: error ?? this.error,
      verificationVersion: verificationVersion ?? this.verificationVersion,
      verifiedModifiedMicros:
          verifiedModifiedMicros ?? this.verifiedModifiedMicros,
      verifiedChangedMicros:
          verifiedChangedMicros ?? this.verifiedChangedMicros,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (bookId.present) {
      map['book_id'] = Variable<String>(bookId.value);
    }
    if (pageIndex.present) {
      map['page_index'] = Variable<int>(pageIndex.value);
    }
    if (pageToken.present) {
      map['page_token'] = Variable<String>(pageToken.value);
    }
    if (relativePath.present) {
      map['relative_path'] = Variable<String>(relativePath.value);
    }
    if (format.present) {
      map['format'] = Variable<String>(format.value);
    }
    if (bytes.present) {
      map['bytes'] = Variable<int>(bytes.value);
    }
    if (sha256.present) {
      map['sha256'] = Variable<String>(sha256.value);
    }
    if (status.present) {
      map['status'] = Variable<String>(status.value);
    }
    if (error.present) {
      map['error'] = Variable<String>(error.value);
    }
    if (verificationVersion.present) {
      map['verification_version'] = Variable<int>(verificationVersion.value);
    }
    if (verifiedModifiedMicros.present) {
      map['verified_modified_micros'] =
          Variable<int>(verifiedModifiedMicros.value);
    }
    if (verifiedChangedMicros.present) {
      map['verified_changed_micros'] =
          Variable<int>(verifiedChangedMicros.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('OfflinePagesCompanion(')
          ..write('bookId: $bookId, ')
          ..write('pageIndex: $pageIndex, ')
          ..write('pageToken: $pageToken, ')
          ..write('relativePath: $relativePath, ')
          ..write('format: $format, ')
          ..write('bytes: $bytes, ')
          ..write('sha256: $sha256, ')
          ..write('status: $status, ')
          ..write('error: $error, ')
          ..write('verificationVersion: $verificationVersion, ')
          ..write('verifiedModifiedMicros: $verifiedModifiedMicros, ')
          ..write('verifiedChangedMicros: $verifiedChangedMicros, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$AppDatabase extends GeneratedDatabase {
  _$AppDatabase(QueryExecutor e) : super(e);
  late final $HistoryEntriesTable historyEntries = $HistoryEntriesTable(this);
  late final $LocalFavoritesTable localFavorites = $LocalFavoritesTable(this);
  late final $DownloadTasksTable downloadTasks = $DownloadTasksTable(this);
  late final $GalleryWarningAcceptancesTable galleryWarningAcceptances =
      $GalleryWarningAcceptancesTable(this);
  late final $OfflineGalleriesTable offlineGalleries =
      $OfflineGalleriesTable(this);
  late final $OfflinePagesTable offlinePages = $OfflinePagesTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
        historyEntries,
        localFavorites,
        downloadTasks,
        galleryWarningAcceptances,
        offlineGalleries,
        offlinePages
      ];
}
