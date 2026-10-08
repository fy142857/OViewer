/// Uploader names are literal account names, not tags or bilingual aliases.
/// The site has no documented escaping for quotes inside this qualifier.
String? uploaderSearchQuery(String uploader, {bool allowUnknown = false}) {
  final name = uploader.trim();
  if (name.isEmpty ||
      !allowUnknown && name == 'Unknown' ||
      name.contains('"') ||
      RegExp(r'[\r\n\x00]').hasMatch(name)) return null;
  return 'uploader:"$name"';
}

/// Plain search input also looks up an account, while explicit search syntax
/// keeps its existing meaning. A quoted phrase is a literal account name.
String? plainUploaderSearchQuery(String keyword) {
  var name = keyword.trim();
  if (name.length >= 2 && name.startsWith('"') && name.endsWith('"')) {
    name = name.substring(1, name.length - 1);
  } else if (RegExp(r'(^|\s)[-~]|[\w]+:|[*%$]|\b(?:OR|AND|NOT)\b')
      .hasMatch(name)) {
    return null;
  }
  return uploaderSearchQuery(name, allowUnknown: true);
}
