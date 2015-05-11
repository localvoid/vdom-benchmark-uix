import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'package:uix/uix.dart';

abstract class BenchmarkImpl {
  void setUp();
  void tearDown();
  void render();
  void update();
}

class Node {
  final Object key;
  final int flags;
  final List<Node> children;

  Node(this.key, this.flags, this.children);

  factory Node.fromMap(Map data) {
    return new Node(
        data['key'],
        data['flags'],
        data['children'] == null ? null : data['children'].map((i) => new Node.fromMap(i)).toList());
  }
}

class Test {
  final String name;
  final List<Node> a;
  final List<Node> b;

  Test(this.name, this.a, this.b);

  factory Test.fromMap(Map data) {
    var d = data['data'];

    var a = d['a'].map((i) => new Node.fromMap(i)).toList();
    var b = d['b'].map((i) => new Node.fromMap(i)).toList();

    return new Test(data['name'], a, b);
  }
}

class Executor {
  Function _impl;
  html.Element _container;
  List<Test> _tests;
  int _iterations;
  Function _cb;
  Function _iterCb;

  int _currentTest = 0;
  int _currentIter = 0;
  List<double> _renderSamples = [];
  List<double> _updateSamples = [];
  List<Map> _result = [];

  int _tasksCount = 0;

  Executor(this._impl, this._container, List<Test> tests, int iterations, this._cb, [this._iterCb])
    : _tests = tests,
      _iterations = iterations,
      _tasksCount = tests.length * iterations;

  void start() {
    _iter();
  }

  void finished() {
    _cb(_result);
  }

  _iter() {
    if (_iterCb != null) {
      _iterCb();
    }

    if (_currentTest < _tests.length) {
      final test = _tests[_currentTest];

      if (_currentIter < _iterations) {
        BenchmarkImpl impl = _impl(_container, test.a, test.b);
        impl.setUp();

        var t = html.window.performance.now();
        impl.render();
        var renderTime = html.window.performance.now() - t;

        t = html.window.performance.now();
        impl.update();
        var updateTime = html.window.performance.now() - t;

        impl.tearDown();

        _renderSamples.add(renderTime);
        _updateSamples.add(updateTime);

        _currentIter++;
      } else {
        _result.add({
          'name': '${test.name} render()',
          'data': new List.from(_renderSamples)
        });
        _result.add({
          'name': '${test.name} update()',
          'data': new List.from(_updateSamples)
        });

        _currentTest++;
        _currentIter = 0;
        _renderSamples = [];
        _updateSamples = [];
      }

      new Future.delayed(const Duration(milliseconds: 0), _iter);
    } else {
      finished();
    }
  }
}

class Benchmark {
  static Benchmark instance;

  bool running = false;
  List<Test> tests;

  Function impl;
  Function reportCb;

  html.DivElement _container = new html.DivElement();
  html.ButtonElement _runButton;
  html.InputElement _iterationsElement;
  html.PreElement _reportElement = new html.PreElement();

  bool _ready = false;
  bool get ready => _ready;
  set ready(bool v) {
    _runButton.disabled = !v;
    _ready = v;
  }

  Benchmark(this.impl) {
    _runButton = html.querySelector('#RunButton');
    _iterationsElement = html.querySelector('#Iterations');

    html.document.body.append(_container);
    html.document.body.append(_reportElement);

    _runButton.onClick.listen((e) {
      e.preventDefault();

      if (!running) {
        int iterations = int.parse(_iterationsElement.value);
        if (iterations <= 0) {
          iterations = 10;
        }

        run(iterations);
      }
    });
  }

  void run(int iterations) {
    running = true;
    ready = false;

    new Executor(impl, _container, tests, 1, (_) { // warmup
      new Executor(impl, _container, tests, iterations, (samples) {
        _reportElement.text = JSON.encode(samples);
        running = false;
        ready = true;

        if (reportCb != null) {
          reportCb(samples);
        }
      }).start();
    }).start();
  }

  static initFromParentWindow(parent, String name, String version, String id) {
    html.window.onMessage.listen((e) {
      Map data = e.data;
      String type = data['type'];
      List<Test> tests;

      if (type == 'tests') {
        instance.tests = data['data'].map((i) => new Test.fromMap(i)).toList();
        instance.reportCb = (samples) {
          parent.postMessage({
            'type': 'report',
            'data': {
              'name': name,
              'version': version,
              'samples': samples
            },
            'id': id
          }, '*');
        };

        instance.ready = true;

        parent.postMessage({
          'type': 'ready',
          'data': null,
          'id': id
        }, '*');
      } else if (type == 'run') {
        instance.run(data['data']['iterations']);
      }
    });

    parent.postMessage({
      'type': 'init',
      'data': null,
      'id': id
    }, '*');
  }

  static void init(String name, String version, Function impl) {
    instance = new Benchmark(impl);

    final uri = Uri.parse(html.window.location.toString());

    if (uri.queryParameters.containsKey('name')) {
      name = uri.queryParameters['name'];
    }

    if (uri.queryParameters.containsKey('version')) {
      version = uri.queryParameters['version'];
    }

    String id = uri.queryParameters['id'];
    String type  = uri.queryParameters['type'];

    if (type == 'iframe') {
      initFromParentWindow(html.window.parent, name, version, id);
    } else if (type == 'window') {
      if (html.window.opener != null) {
        initFromParentWindow(html.window.opener, name, version, id);
      } else {
        html.window.console.log('Failed to initialize: opener window is NULL');
      }
    }
  }
}

const name = 'uix';
const version = '0.7.0';

List<VNode> renderTree(List<Node> nodes) {
  List<VNode> children = [];

  for (var i = 0; i < nodes.length; i++) {
    final n = nodes[i];
    if (n.children != null) {
      children.add(vElement('div', key: n.key, children: renderTree(n.children)));
    } else {
      children.add(vElement('span', key: n.key, children: [vText(n.key.toString())]));
    }
  }

  return children;
}

void injectVNodeSync(VNode node, html.Node container) {
  node.create(const VContext(false));
  container.append(node.ref);
  node.attached();
  node.render(const VContext(true));
}

class VDomBenchmark implements BenchmarkImpl {
  html.Element container;
  List<Node> a;
  List<Node> b;
  VNode _vRoot;

  VDomBenchmark(this.container, this.a, this.b);

  void setUp() {}

  void tearDown() {
    _vRoot.ref.remove();
  }

  void render() {
    _vRoot = vElement('div', key: 0, children: renderTree(a));
    injectVNodeSync(_vRoot, container);
  }

  void update() {
    final newRoot = vElement('div', key: 0, children: renderTree(b));
    _vRoot.update(newRoot, const VContext(true));
    _vRoot = newRoot;
  }
}

void main() {
  Benchmark.init(name, version, (container, a, b) => new VDomBenchmark(container, a, b));
}
