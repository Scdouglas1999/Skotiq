/// The one-time move of saved sequences from quality stops to notices.
///
/// Owner decision 2026-10-06: only a risk to the hardware pauses or ends a run
/// by itself. A trigger that judges the frames (HFR, focus drift, guiding RMS,
/// drift, transparency) used to pause or end the run in every sequence that
/// had one, and new triggers now notify. Sequences saved before that change
/// keep the old stop unless they are moved, so the database migration to
/// schema 61 and the sequence-file importer both pass every node through
/// [notifyInsteadOfQualityStops].
///
/// Safety triggers (weather, dawn, dome, altitude, tracking lost, humidity,
/// clouds, a lost guide star) are never touched, nor is an action that does
/// not stop the run (autofocus, next target, switch target or filter).
///
/// Works on the stored maps rather than the models so the database migration
/// does not depend on the current model classes.
library;

/// Recovery-node trigger types that judge image quality, by their stored name.
const Set<String> kQualityTriggerTypeNames = {
  'hfrdegraded',
  'focusdrift',
  'guidingfailed',
  'driftlimit',
  'transparencydropped',
};

/// Recovery actions that pause or end the run, by their stored name. `retry`
/// is here because on a trigger it means pause the run after that many
/// firings.
const Set<String> _stoppingRecoveryActions = {
  'pause',
  'retry',
  'parkandabort',
  'pauseandwaitforclear',
};

/// Exposure-trigger actions that pause or end the run. Every exposure trigger
/// condition (HFR, guiding RMS, drift) judges quality.
const Set<String> _stoppingExposureTriggerActions = {
  'pauseandrecalibrate',
  'abort',
};

/// The stored name of the Notify recovery action, the same in the database
/// and in sequence files.
const String kNotifyRecoveryActionWire = 'notify';

/// The Notify exposure-trigger action as the native sequencer reads it.
const String kNotifyExposureTriggerActionWire = 'Notify';

/// Move a stored node's quality stops to notices, in place.
///
/// [nodeType] is the node's stored type ('Recovery', 'TakeExposure', or their
/// older lower-case spellings) and [properties] its stored fields: the
/// database's `properties` column, or the node object of a sequence file.
/// Returns whether anything changed. Running it again changes nothing.
bool notifyInsteadOfQualityStops(
  String nodeType,
  Map<String, dynamic> properties,
) {
  switch (nodeType.toLowerCase()) {
    case 'recovery':
      final trigger = properties['triggerType'];
      final action = properties['recoveryAction'];
      if (trigger is String &&
          kQualityTriggerTypeNames.contains(trigger.toLowerCase()) &&
          action is String &&
          _stoppingRecoveryActions.contains(action.toLowerCase())) {
        properties['recoveryAction'] = kNotifyRecoveryActionWire;
        return true;
      }
      return false;
    case 'takeexposure':
    case 'exposure':
      final triggers = properties['triggers'];
      if (triggers is! List) return false;
      var changed = false;
      for (final trigger in triggers) {
        if (trigger is! Map) continue;
        final action = trigger['action'];
        if (action is String &&
            _stoppingExposureTriggerActions.contains(action.toLowerCase())) {
          trigger['action'] = kNotifyExposureTriggerActionWire;
          changed = true;
        }
      }
      return changed;
    default:
      return false;
  }
}
