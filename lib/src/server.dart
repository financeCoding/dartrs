part of dartrs;

/**
 * Restful Server implementation
 */
class RestfulServer {

  static final NOT_FOUND = new Endpoint("NOT_FOUND", "", (HttpRequest request, params) {
    request.response.statusCode = HttpStatus.NOT_FOUND;
    request.response.write("No handler for requested resource found");
  });

  /**
   * Static method to create new restful servers
   * This is more consistent stylistically with the sdk
   */
  static Future<RestfulServer> bind({String host:"127.0.0.1", int port:8080, Object init, int concurrency:1}) {
    var server = _newServer(init, concurrency);
    return server._listen(host: host, port: port);
  }

  /**
   * Static method to create new tls restful servers
   * This is more consistent stylistically with the sdk
   */
  static Future<RestfulServer> bindSecure({String host:"127.0.0.1", int port:8443, Object init, int concurrency:1, String certificateName}) {
    var server = _newServer(init, concurrency);
    return server._listenSecure(host: host, port: port, certificateName: certificateName);
  }

  static _newServer(init, concurrencyLevel) {
    var server = new RestfulServer();
    server._concurrency = concurrencyLevel;
    server._isolateInit = init;
    
    return server;
  }

  int _concurrency;
  Function _isolateInit;

  List<Endpoint> _endpoints = [];
  HttpServer _server;
  List<SendPort> _workers = [];
  math.Random random = new math.Random();
  _WsHandler _wsHandler = new _WsHandler();

/**
   * The global pre-processor.
   *
   * This method may return a Future.
   */
  Function preProcessor = (request) => request.response.headers.add(HttpHeaders.CACHE_CONTROL, "no-cache, no-store, must-revalidate");

  /**
   * The global post-processor. Note that you should not try to modify
   * immutable headers here, which is the case if any output has already
   * been written to the response.
   *
   * This method may return a Future.
   */
  Function postProcessor = (request) {};

  /**
   * The global error handler.
   */
  Function onError = (e, request) {
    try {
      request.response.statusCode = HttpStatus.INTERNAL_SERVER_ERROR;
    } on StateError catch (e) {
      _log.warn("Could not update status code: ${e.toString()}");
    }
    request.response.writeln(e.toString());
  };

  /**
   * Creates a new [RestfulServer] and registers the default OPTIONS endpoint.
   */
  RestfulServer() {
    var endpoint = new Endpoint.root("OPTIONS", (request, params) {
      _endpoints.forEach((Endpoint e) {
        request.response.writeln("$e");
      });
    });

    _endpoints.add(endpoint);
  }

  /**
   * Starts this server on the given host and port.
   */
  Future<RestfulServer> _listen({String host:"127.0.0.1", int port:8080}) {
    return HttpServer.bind(host, port).then((server) {
      _log.info("Server listening on $host:$port...");
      _logic(server);
      return this;
    });
  }

  /**
   * Starts this server on the given host and port (in secure mode).
   */
  Future<RestfulServer> _listenSecure({String host:"127.0.0.1", int port:8443, String certificateName}) {
    return HttpServer.bindSecure(host, port, certificateName: certificateName).then((server) {
      _log.info("Server listening on $host:$port (secured)...");
      _logic(server);
      return this;
    });
  }

  /**
   * Performs a context scan and creates endpoints from annotated methods found
   */
  void contextScan() {
    var mirrors = currentMirrorSystem();
    mirrors.libraries.forEach((_, LibraryMirror lib) {
      lib.functions.values.forEach((MethodMirror method) {

        var verb = null;
        var path = null;
        method.metadata.forEach((InstanceMirror im) {

          if(im.reflectee is _HttpMethod) {
            verb = im.reflectee.name;
          }

          if(im.reflectee is Path) {
            path = im.reflectee.path;
          }
        });

        if(verb != null && path !=null) {
          if(method.parameters.length == 2) {
            _endpoints.add(new Endpoint(verb, path, (request, uriParams)=>lib.invoke(method.simpleName, [request, uriParams])));
            _log.info("Added endpoint $verb:$path");
          } else if(method.parameters.length == 3) {
            _endpoints.add(new Endpoint(verb, path, (request, uriParams, body)=>lib.invoke(method.simpleName, [request, uriParams, body])));
            _log.info("Added endpoint $verb:$path");
          } else {
            _log.error("Not adding annotated method ${method.simpleName} as it has wrong number of arguments (Must be 2 or 3)");
          }
        }
      });
    });
  }

  void _logic(HttpServer server) {
    _server = server;

    server.listen((HttpRequest request) {
      if(WebSocketTransformer.isUpgradeRequest(request)) {
        _isolateInit(this);
        _wsHandler.handle(request, _isolateInit);
      }
      else if(this._isolateInit == null) {
        _handle(request);
      } else {
        _dispatch(request);
      }
    });
  }

  /**
  * Initializes isolates
  */
  Future _initIsolates() {
    Completer comp = new Completer();
    for (var i = _concurrency;i > 0 ;i--) {
      var initPort = new ReceivePort();
      Isolate.spawn(_isolateLogic, {
          "init" : _isolateInit, "initPort":initPort.sendPort
      }).then((Isolate iss) {
        initPort.first.then((commandPort) {
          _workers.add(commandPort);
          if(!comp.isCompleted) {
            comp.complete(commandPort);
          }
        });
      });
    }

    return comp.future;
  }

  /**
  * Dispatches requests to worker isolates
  */
  void _dispatch(request) {
    Future workerProvider;
    if(_workers.isEmpty) {
      workerProvider = _initIsolates();
    } else {
      workerProvider = new Future.sync(() {
        var index = random.nextInt(_workers.length-1);
        _log.debug("Using worker # ${index}");
        return _workers[index];
      });
    }

    workerProvider.then((commandPort) {
      var reply = new ReceivePort();
      var outBodyPort = new ReceivePort();

      var isolateRequest = new IsolateRequest.fromHttpRequest(request);
      isolateRequest.response = new IsolateResponse.fromHttpResponse(request.response, outBodyPort.sendPort);

      commandPort.send({"reply" : reply.sendPort, "request" : isolateRequest});

      reply.listen((response) {
        if(response is SendPort) {
          request.listen((incoming) {
            response.send(incoming);
          }).onDone(() {
            response.send(new _DoneEvent());
          });
        } else if(response is IsolateResponse) {
          response.headers.forEach((key, value) => request.response.headers.add(key, value));
          request.response.statusCode = response.statusCode;
          request.response.headers.contentType = response.headers.contentType;

          outBodyPort.takeWhile(_untilDone).pipe(request.response);
          reply.close();
        }
      });
    });
  }

  /**
   *
  */
  Future _handle(HttpRequest request) {
    Stopwatch sw = new Stopwatch()..start();

      /*
       * Since we're allowing sync and async processors, we have to wrap them into
       * a Future.sync() to be able to chain them and properly handle exceptions.
       *
       * Chain:
       * Pre-process -> Service -> Post-Process
       */
    // 1. Pre-process
    var future = new Future.sync(() => preProcessor(request))
    // 2. Then service
    .then((_) {
      Endpoint endpoint = _endpoints.firstWhere((Endpoint e) => e.canService(request), orElse:() => NOT_FOUND);
      _log.debug("Match: ${request.method}:${request.uri} to ${endpoint}");
      return endpoint.service(request);
    });
    future
    // 3. Then post-process
    .then((_) => postProcessor(request))
    // If an error occurred in the chain, handle it.
    .catchError((e, stack) {
      _log.warn("Server error: $e");
      _log.debug(stack.toString());
      onError(e, request);
    })
    // At the end, always close the request's response and log the request time.
    .whenComplete(() {
      request.response.close().then((resp) => _log.info("Closed request to ${request.uri.path} with status ${resp.statusCode}.."));
      sw.stop();
      _log.info("Call to ${request.method} ${request.uri} ended in ${sw.elapsedMilliseconds} ms");
    });

    return future;
  }

  _wsHandlerFor(path) {
    return _wsHandler.findHandler(path);
  }

  /**
   * Shuts down this server.
   */
  Future close() {
    return _server.close().then((server) => _log.info("Server is now stopped"));
  }

  /**
   * Services GET calls
   * [handler] should take (HttpRequest, Map)
   */
  void onGet(String uri, handler(HttpRequest req, Map uriParams)) {
    _endpoints.add(new Endpoint("GET", uri, handler));

    _log.info("Added endpoint GET:$uri");
  }

  /**
   * Services POST calls
   * [handler] can take be either (HttpRequest, Map)
   * or (HttpRequest, Map, body).  In latter case,
   * request body will be parsed and passed in
   */
  void onPost(String uri, handler) {
    _endpoints.add(new Endpoint("POST", uri, handler));

    _log.info("Added endpoint POST:$uri");
  }

  /**
   * Services PUT calls
   * [handler] can take be either (HttpRequest, Map)
   * or (HttpRequest, Map, body).  In latter case,
   * request body will be parsed and passed in
   */
  void onPut(String uri, handler) {
    _endpoints.add(new Endpoint("PUT", uri, handler));

    _log.info("Added endpoint PUT:$uri");
  }

  /**
   * Services PATCH calls
   * [handler] can take be either (HttpRequest, Map)
   * or (HttpRequest, Map, body).  In latter case,
   * request body will be parsed and passed in
   */
  void onPatch(String uri, handler) {
    _endpoints.add(new Endpoint("PATCH", uri, handler));

    _log.info("Added endpoint Patch:$uri");
  }

  void onDelete(String uri, handler(HttpRequest req, Map uriParams)) {
    _endpoints.add(new Endpoint("DELETE", uri, handler));

    _log.info("Added endpoint DELETE:$uri");
  }

  void onHead(String uri, handler(HttpRequest req, Map uriParams)) {
    _endpoints.add(new Endpoint("HEAD", uri, handler));

    _log.info("Added endpoint HEAD:$uri");
  }

  void onOptions(String uri, handler(HttpRequest req, Map uriParams)) {
    _endpoints.add(new Endpoint("OPTIONS", uri, handler));

    _log.info("Added endpoint OPTIONS:$uri");
  }

  void onWs(String path, handler(data)) {
    _wsHandler.addHandler(path, handler);

    _log.info("Added endpoint WS:$path");
  }
}

class _WsHandler {

  var _wsHandlers = {};

  void handle(HttpRequest request, init) {

    if(!_wsHandlers.containsKey(request.uri.path)) {
      _log.error("No WS handler configured for path ${request.uri.path}");
      request.response.statusCode = HttpStatus.NOT_FOUND;
      request.response.write("No handler for path ${request.uri.path}");
      request.response.close();
    } else {
      WebSocketTransformer.upgrade(request).then((WebSocket sws) {
        SendPort inPort;
        ReceivePort out = new ReceivePort();
        Isolate.spawn(_wsLogic, {"path" : request.uri.path, "init" : init, "outPort": out.sendPort}).then((iss) {
          out.listen((data) {
            if(data is SendPort) {
              inPort = data;
              sws.listen((data) {
                inPort.send(data);
              }).onDone(() {
                inPort.send(new _DoneEvent());
              });
            } else {
              sws.add(data);
            }
          });
        });
      });
    }
  }

  addHandler(String path,  handler) {
    _wsHandlers[path] = handler;
  }

  findHandler(String path) {
    return _wsHandlers[path];
  }
}

/**
 * Holds information about a restful endpoint
 */
class Endpoint {

  static final _log = LoggerFactory.getLoggerFor(Endpoint);

  static final URI_PARAM = new RegExp(r"{(\w+?)}");

  final String _method, _path;

  Function _handler;

  RegExp _uriMatch;
  List _uriParamNames = [];

  bool _parseBody;

  /**
   * Creates a new endpoint.
   *
   * The handler may return a Future.
   */
  Endpoint(String method, this._path, this._handler): this._method = method.toUpperCase() {
    _uriParamNames = [];

    String regexp = _path.replaceAllMapped(URI_PARAM, (Match m) {
      _uriParamNames.add(m.group(1));
      return r"(\w+)";
    });

    _uriMatch = new RegExp(regexp);
    _parseBody = _hasMoreThan2Parameters(_handler);
  }

  /**
   * Creates an endpoint for the root path.
   * Matches one `/` or an empty path.
   */
  Endpoint.root(String method, this._handler):
    this._method = method.toUpperCase(),
    this._path = "/",
    this._uriMatch = new RegExp(r'(^$|^(/)$)') {
    this._parseBody = _hasMoreThan2Parameters(_handler);
  }

  bool _hasMoreThan2Parameters(handler) {
    return (reflect(handler) as ClosureMirror).function.parameters.length>2;
  }

  /**
   *  Replies if this endpoint can service incoming request
   */
  bool canService(req) {
    return _method == req.method.toUpperCase() && _uriMatch.hasMatch(req.uri.path);
  }

  /**
   * Services the given [HttpRequest].
   * Always returns a Future.
   */
  Future service(req) {
    // Wrap in Future.sync() to avoid mixing of sync and async errors.
    return new Future.sync(() {
      // Extract URI params
      var uriParams = {};
      if (_uriParamNames.isNotEmpty) {
        var match = _uriMatch.firstMatch(req.uri.path);
        for(var i = 0; i < match.groupCount; i++) {
          String group = match.group(i+1);
          uriParams[_uriParamNames[i]] = group;
        }
      }

      _log.debug("Got params: $uriParams");

      // Handle request
      if (!_parseBody) return _handler(req, uriParams);
      return req.transform(new Utf8Decoder()).join().then((body) {
        return _handler(req, uriParams, body); // Could throw (sync or async)
      });
    });
  }

  String toString() => '$_method $_path';
}
