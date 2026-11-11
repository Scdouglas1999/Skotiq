/// One HTTP route of the remote API, declared once for the host and its
/// clients.
///
/// The host binds a handler to each [ApiEndpoint] and reads everything else
/// (who may call it, how often, how large a body, how long it may run) from
/// the [ApiRoute]. Clients use the same value for the method and the path.
library;

/// The verb of a route. [ws] is a WebSocket upgrade, which arrives as a GET.
enum ApiMethod {
  get('GET'),
  post('POST'),
  put('PUT'),
  delete('DELETE'),
  patch('PATCH'),
  ws('WS');

  const ApiMethod(this.wireName);

  /// The name used in the advertised endpoint list (`GET /api/info`).
  final String wireName;

  /// The HTTP verb a request for this route carries.
  String get httpVerb => this == ws ? 'GET' : wireName;

  bool get mayCarryBody => this == post || this == put || this == patch;
}

/// What a credential must hold to call a route.
enum ApiScope { public, view, control, admin }

/// The device or feature a fine-grained token is granted access to.
enum ApiResource {
  camera('camera'),
  mount('mount'),
  focuser('focuser'),
  filterWheel('filter-wheel'),
  rotator('rotator'),
  dome('dome'),
  cover('cover'),
  guiding('guiding'),
  safety('safety'),
  switchGear('switch'),
  sequencer('sequencer'),
  framing('framing'),
  calibration('calibration'),
  catalog('catalog'),
  filesystem('filesystem'),
  backup('backup'),
  settings('settings'),
  plugins('plugins'),

  /// Connect and disconnect. The device kind is in the request body, so a
  /// fine-grained token needs this resource to power gear on or off.
  devices('devices'),
  mosaic('mosaic'),
  coimaging('coimaging'),
  constellation('constellation'),
  darkroom('darkroom'),
  system('system'),
  info('info');

  const ApiResource(this.wireName);

  /// The name used in token grant specs and in 403 bodies.
  final String wireName;
}

/// Per-client request ceiling for one route.
enum ApiRateTier {
  none(null),
  control(60),
  highRisk(12);

  const ApiRateTier(this.maxRequestsPerMinute);

  final int? maxRequestsPerMinute;
}

/// How long the host lets a handler run before it answers 503.
enum ApiTimeout {
  /// A read that answers from state the host already holds.
  read,

  /// A read that builds a file (export, backup, PDF, bundle).
  slowRead,

  /// A command, which may wait for hardware.
  command,

  /// A stream that stays open by design (WebSocket, server-sent events).
  openEnded,
}

/// The per-token bucket a request draws from.
enum ApiBucket {
  read('read'),
  write('write'),
  liveView('live-view'),
  imageDownload('image-download');

  const ApiBucket(this.wireName);

  /// The name used in 429 bodies.
  final String wireName;
}

const int _oneMiB = 1024 * 1024;

/// Request body ceilings for the routes that take more than the default.
abstract final class ApiBodyLimit {
  /// Raw image data posted for stats, stretch, debayer or saving.
  static const int image = 64 * _oneMiB;

  /// A backup, dark library or plugin archive.
  static const int archive = 256 * _oneMiB;

  /// A star catalog.
  static const int catalog = 1024 * _oneMiB;
}

class ApiRoute {
  const ApiRoute(
    this.method,
    this.path, {
    required this.resource,
    required this.scope,
    required this.timeout,
    required this.bucket,
    this.rate = ApiRateTier.none,
    this.audit,
    this.maxBodyBytes = defaultMaxBodyBytes,
    this.sessionOwner = false,
    this.queryToken = false,
  });

  const ApiRoute.get(
    String path, {
    required ApiResource resource,
    ApiScope scope = ApiScope.view,
    ApiRateTier rate = ApiRateTier.none,
    String? audit,
    ApiTimeout timeout = ApiTimeout.read,
    ApiBucket bucket = ApiBucket.read,
    bool queryToken = false,
  }) : this(
         ApiMethod.get,
         path,
         resource: resource,
         scope: scope,
         rate: rate,
         audit: audit,
         timeout: timeout,
         bucket: bucket,
         queryToken: queryToken,
       );

  const ApiRoute.post(
    String path, {
    required ApiResource resource,
    ApiScope scope = ApiScope.control,
    ApiRateTier rate = ApiRateTier.none,
    String? audit,
    int maxBodyBytes = defaultMaxBodyBytes,
    ApiTimeout timeout = ApiTimeout.command,
    ApiBucket bucket = ApiBucket.write,
    bool sessionOwner = false,
  }) : this(
         ApiMethod.post,
         path,
         resource: resource,
         scope: scope,
         rate: rate,
         audit: audit,
         maxBodyBytes: maxBodyBytes,
         timeout: timeout,
         bucket: bucket,
         sessionOwner: sessionOwner,
       );

  const ApiRoute.put(
    String path, {
    required ApiResource resource,
    ApiScope scope = ApiScope.control,
    ApiRateTier rate = ApiRateTier.none,
    String? audit,
    int maxBodyBytes = defaultMaxBodyBytes,
    ApiTimeout timeout = ApiTimeout.command,
    ApiBucket bucket = ApiBucket.write,
  }) : this(
         ApiMethod.put,
         path,
         resource: resource,
         scope: scope,
         rate: rate,
         audit: audit,
         maxBodyBytes: maxBodyBytes,
         timeout: timeout,
         bucket: bucket,
       );

  const ApiRoute.delete(
    String path, {
    required ApiResource resource,
    ApiScope scope = ApiScope.control,
    ApiRateTier rate = ApiRateTier.none,
    String? audit,
    ApiTimeout timeout = ApiTimeout.command,
    ApiBucket bucket = ApiBucket.write,
  }) : this(
         ApiMethod.delete,
         path,
         resource: resource,
         scope: scope,
         rate: rate,
         audit: audit,
         timeout: timeout,
         bucket: bucket,
       );

  const ApiRoute.ws(String path, {required ApiResource resource})
    : this(
        ApiMethod.ws,
        path,
        resource: resource,
        scope: ApiScope.view,
        timeout: ApiTimeout.openEnded,
        bucket: ApiBucket.read,
      );

  static const int defaultMaxBodyBytes = _oneMiB;

  final ApiMethod method;

  /// Path template. Parameters use `<name>` or `<name|regex>`.
  final String path;

  final ApiScope scope;
  final ApiResource resource;
  final ApiRateTier rate;

  /// Name written to the audit log before and after the handler runs.
  final String? audit;

  final int maxBodyBytes;
  final ApiTimeout timeout;
  final ApiBucket bucket;

  /// While a client holds the session, only that client may call this route.
  final bool sessionOwner;

  /// The route accepts its token as `?access_token=`, for `EventSource`,
  /// which cannot set headers.
  final bool queryToken;

  /// `METHOD /path`, as listed by `GET /api/info`.
  String get signature => '${method.wireName} $path';

  /// The path with each `<name>` replaced by its value from [params],
  /// percent-encoded as one segment.
  String fill(Map<String, Object> params) {
    return path.replaceAllMapped(_parameter, (match) {
      final name = match.group(1)!;
      final value = params[name];
      if (value == null) {
        throw ArgumentError.value(params, 'params', 'no value for <$name>');
      }
      return Uri.encodeComponent(value.toString());
    });
  }

  static final RegExp _parameter = RegExp(r'<([^>|]+)(?:\|[^>]*)?>');

  @override
  String toString() => signature;
}

/// A named route. Each API area is an enum of these, so its `values` is the
/// area's route list in match order.
abstract interface class ApiEndpoint {
  ApiRoute get route;
}
