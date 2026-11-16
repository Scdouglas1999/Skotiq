import 'dart:io';

/// A folder of this test run's own for darkroom masters. The editor writes
/// recipe drafts beside a master, so a fixed path would leave files in a shared
/// `/tmp` (on Windows, in a `C:\tmp` it creates).
final String darkroomScratch =
    Directory.systemTemp.createTempSync('skotiq-darkroom-').path;
