import 'package:flutter/widgets.dart';
import 'package:lucide_icons/lucide_icons.dart';

/// The icons a profile can be marked with, by the word stored in its
/// `profileIcon`, in the order the editor offers them.
const Map<String, ProfileGlyph> profileGlyphs = {
  'orbit': ProfileGlyph(LucideIcons.orbit, 'Planet'),
  'moon': ProfileGlyph(LucideIcons.moon, 'Moon'),
  'star': ProfileGlyph(LucideIcons.star, 'Star'),
  'sparkles': ProfileGlyph(LucideIcons.sparkles, 'Deep sky'),
  'sun': ProfileGlyph(LucideIcons.sun, 'Sun'),
  'camera': ProfileGlyph(LucideIcons.camera, 'Camera'),
  'mountain': ProfileGlyph(LucideIcons.mountain, 'Dark site'),
  'home': ProfileGlyph(LucideIcons.home, 'Backyard'),
};

/// One icon a profile can carry and the name it is offered under.
class ProfileGlyph {
  const ProfileGlyph(this.icon, this.name);

  final IconData icon;
  final String name;
}

/// The icon a profile shows when it has none of its own.
const IconData defaultProfileIcon = LucideIcons.aperture;

/// The icon for a stored `profileIcon` word: its glyph, or [defaultProfileIcon]
/// for none or a word this build does not offer.
IconData profileIconFor(String? word) =>
    profileGlyphs[word]?.icon ?? defaultProfileIcon;
