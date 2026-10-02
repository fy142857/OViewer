import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import '../core/theme/app_colors.dart';
import '../models/gallery_tag.dart';
import '../repositories/tag_translation_repository.dart';

class TagChip extends StatelessWidget {
  final GalleryTag tag;
  final VoidCallback? onTap;
  final bool showTranslation;

  const TagChip({
    super.key,
    required this.tag,
    this.onTap,
    this.showTranslation = true,
  });

  @override
  Widget build(BuildContext context) {
    if (showTranslation && GetIt.I.isRegistered<TagTranslationRepository>()) {
      return AnimatedBuilder(
          animation: GetIt.I<TagTranslationRepository>(),
          builder: (context, _) => _buildChip(context));
    }
    return _buildChip(context);
  }

  Widget _buildChip(BuildContext context) {
    String displayText = tag.key;

    // Try to get translation
    if (showTranslation) {
      if (tag.translation != null) {
        displayText = tag.translation!;
      } else {
        try {
          final tagRepo = GetIt.I<TagTranslationRepository>();
          final translated = tagRepo.getTranslation(tag.namespace, tag.key);
          if (translated != null) displayText = translated;
        } catch (_) {
          // TagTranslationRepository not registered yet
        }
      }
    }

    final color = _namespaceColor(tag.namespace);
    return Tooltip(
      message: '${tag.namespace}:${tag.key}',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
          decoration: BoxDecoration(
            color: color.withOpacity(0.12),
            border: Border.all(color: color.withOpacity(0.35)),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            displayText,
            style: TextStyle(
              fontSize: 12,
              color: color,
              height: 1.2,
            ),
          ),
        ),
      ),
    );
  }

  Color _namespaceColor(String namespace) {
    switch (namespace) {
      case 'female':
        return AppColors.tagFemale;
      case 'male':
        return AppColors.tagMale;
      case 'parody':
        return AppColors.tagParody;
      case 'character':
        return AppColors.tagCharacter;
      case 'group':
        return AppColors.tagGroup;
      case 'artist':
        return AppColors.tagArtist;
      case 'language':
        return AppColors.tagLanguage;
      default:
        return AppColors.tagOther;
    }
  }
}
