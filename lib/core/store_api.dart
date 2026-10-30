/// 两个库（明文 / 加密）共用的接口。
///
/// 界面只认这个抽象，不关心背后是 `.md` 文件还是 AES 密文。
library;

import 'models.dart';

abstract class NotesStore {
  String get notesDir;
  String get trashDir;
  Map<String, Note> get notes;

  void load();
  void saveIndex();

  Note create({String title, String content});
  Note save(Note note);
  bool delete(String noteId);
  Note? get(String noteId);

  List<TrashEntry> listTrash();
  Note? restoreTrash(TrashEntry entry);

  List<Note> allNotes();
  List<Note> filter({String query, String? tag});
  Map<String, int> allTags();
}
