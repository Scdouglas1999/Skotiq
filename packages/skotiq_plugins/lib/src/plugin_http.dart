/// How long a bundled plugin waits for one HTTP request and its reply.
///
/// Far below the node executor's limit, so a server that stops answering
/// fails the plugin's node in seconds instead of holding the sequence step.
const Duration pluginHttpTimeout = Duration(seconds: 30);
