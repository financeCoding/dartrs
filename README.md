Dart Restful Webserver
======================

[![Build Status](https://drone.io/github.com/dkornishev/dartrs/status.png)](https://drone.io/github.com/dkornishev/dartrs/latest)

A server to make development of ReSTful webservices easy and fun

Getting Started
---------------

```dart
RestfulServer.bind().then((server) {
  server
    ..onGet("/echo", (request, params) => request.response.write("ECHO"))
    ..onPut("/put", (request, uriParams, body) => request.response.statusCode = HttpStatus.NO_CONTENT);
});
```

POST/PUT/PATCH will handle parsing the body if provided callback has three parameters
```dart
..onPost("/post", (request, uriParams, body) => request.response.statusCode = HttpStatus.CREATED)
```
Pre processing handler can be registed which will be invoked on every request
```dart
var old = server.preProcessor;

server.preProcessor = (request) {
    request.response.headers.contentType = ContentTypes.APPLICATION_JSON;
    old(request);
  };
```

Uri Parameters
--------------
Uri parameters, denoted by {} are automagically parsed and provided as second argument to the callback
```dart
..onGet("/api/{version}/{user}", (request, params) {
    request.response.write("Version ${params['version']} with user ${params['user']}"
  }));
```

HTTPS (SSL/TLS)
---------------
The good folks at google decided to go with NSS see (https://developer.mozilla.org/en-US/docs/NSS/Tools)
and documentation on SecureSocket.initialize(..)
Luckily, default tests have a functioning key pair, which have been appropriated for testing needs (test/pkcert)
```dart
SecureSocket.initialize(database: "pkcert", password: 'dartdart', useBuiltinRoots: false);
RestfulServer.bindSecure(port: 8443, certificateName: "localhost_cert").then((server) {
  server
    ..onGet("/secure", (request, params) => request.response.write("SECURE"));
});
```

Annotations and Context Scan
-------------------
Jaxrs-style annotations and bootstrap via a library scanner:
```dart
@Path("/hello")
@GET
void echo(request, params) {
  request.response.write("hi");
}

RestfulServer.bind(host: "127.0.0.1", port: 8080).then((server) {
  server
    ..onGet("/mixed", (request, params) => request.response.write("I am all mixed up"))
    ..contextScan();
  });
```

Isolates
--------
There are currently some limitations on what can be sent across isolates
Request and Response are proxies with limited functionality.

To init a multi-isolate server, a "functor" (a class with 'call' method) needs to be defined and passed in.

Keep in mind that since streams cannot be passed between isolates, some of the io
happens on the main isolate, though in practice, that doesn't seem to effect things

Isolates are NOT threads.  It is perfectly fine to have hundreds of isolates if logic
of your application warrants it.

If no init object is provided, all requests will handled on main isolate.

```dart
void main() {
  RestfulServer.bind(init:new MyInit(), concurrency: 8).then((server) {
  });
}

class MyInit {
  call(RestfulServer server) {
    print("initializing server");
    server
    ..onPost("/api/isolate", (request, params, body) {
      request.response.statusCode = "777";
      request.response.headers.add("X-TEST", "WORKS");
      request.response.headers.contentType = ContentTypes.TEXT_PLAIN;
      request.response.writeln("$body ${new DateTime.now()}");
      request.response.writeln("����������������! | ������ | pr��ce");
    })
    ..onGet("/api/get", (request, params) {
      request.response.writeln("GOT");
    });
  }
}
```

Web Sockets
-----------
```dart
server
  ..onWs("/ws/echo", (data) {
    print(data);
    return "ACK $data";
  });
```

Websockets only work if server was initialized with init object (concurrency-ready)
Each websocket will get its own isolate.

Default Endpoints
-----------------
By default, the server will list all registered endpoints if you issue:
```
OPTIONS /
```


Logging
-------
log4dart is used for logging on the server.

See https://github.com/ltackmann/log4dart/blob/master/doc/Config.md for ways to configure
