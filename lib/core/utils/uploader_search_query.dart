/// Uploader names are literal account names, not tags or bilingual aliases.
/// The site has no documented escaping for quotes inside this qualifier.
String? uploaderSearchQuery(String uploader) {
  final name = uploader.trim();
  if (name.isEmpty ||
      name == 'Unknown' ||
      name.contains('"') ||
      RegExp(r'[\r\n\x00]').hasMatch(name)) return null;
  return 'uploader:"$name"';
}
