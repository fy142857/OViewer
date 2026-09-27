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
        lastReadAt
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
      required this.lastReadAt});
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
          DateTime? lastReadAt}) =>
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
          ..write('lastReadAt: $lastReadAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(gid, token, title, thumbUrl, category, rating,
      fileCount, lastReadPage, totalPages, lastReadAt);
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
          other.lastReadAt == this.lastReadAt);
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
      Value<DateTime>? lastReadAt}) {
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
          ..write('lastReadAt: $lastReadAt')
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

abstract class _$AppDatabase extends GeneratedDatabase {
  _$AppDatabase(QueryExecutor e) : super(e);
  late final $HistoryEntriesTable historyEntries = $HistoryEntriesTable(this);
  late final $LocalFavoritesTable localFavorites = $LocalFavoritesTable(this);
  late final $DownloadTasksTable downloadTasks = $DownloadTasksTable(this);
  late final $GalleryWarningAcceptancesTable galleryWarningAcceptances =
      $GalleryWarningAcceptancesTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
        historyEntries,
        localFavorites,
        downloadTasks,
        galleryWarningAcceptances
      ];
}
