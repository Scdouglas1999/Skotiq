import '../api_route.dart';

enum DbReadApi implements ApiEndpoint {
  listSequenceRuns(
    ApiRoute.get('/api/sequence-runs', resource: ApiResource.system),
  ),
  getSequenceRunEvents(
    ApiRoute.get(
      '/api/sequence-runs/<runId>/events',
      resource: ApiResource.system,
    ),
  ),
  getSequenceRunFrames(
    ApiRoute.get(
      '/api/sequence-runs/<runId>/frames',
      resource: ApiResource.system,
    ),
  ),
  getSequenceRunById(
    ApiRoute.get('/api/sequence-runs/<runId>', resource: ApiResource.system),
  ),
  listNotesJournal(
    ApiRoute.get('/api/notes-journal', resource: ApiResource.system),
  ),
  createObservationLog(
    ApiRoute.post('/api/notes-journal', resource: ApiResource.system),
  ),
  deleteObservationLog(
    ApiRoute.delete('/api/notes-journal/<id>', resource: ApiResource.system),
  ),
  deleteAllObservationLogs(
    ApiRoute.delete('/api/notes-journal', resource: ApiResource.system),
  ),
  listJournalNotes(ApiRoute.get('/api/db/notes', resource: ApiResource.system)),
  createJournalNote(
    ApiRoute.post('/api/db/notes', resource: ApiResource.system),
  ),
  updateJournalNote(
    ApiRoute.put('/api/db/notes/<id>', resource: ApiResource.system),
  ),
  deleteJournalNote(
    ApiRoute.delete('/api/db/notes/<id>', resource: ApiResource.system),
  ),
  listGuideRmsHistory(
    ApiRoute.get('/api/guide-rms-history', resource: ApiResource.system),
  ),
  listPolarAlignmentHistory(
    ApiRoute.get('/api/polar-alignment-history', resource: ApiResource.system),
  ),
  listDarkLibrary(
    ApiRoute.get('/api/db/dark-library', resource: ApiResource.system),
  ),
  listFlatHistory(
    ApiRoute.get('/api/db/flat-history', resource: ApiResource.system),
  );

  const DbReadApi(this.route);

  @override
  final ApiRoute route;
}
