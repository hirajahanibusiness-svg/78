import 'dart:math' as m;

enum Pose { qiyam, ruku, sujud, julus, unknown }

const _poses = [Pose.qiyam, Pose.ruku, Pose.sujud, Pose.julus];

double _med(List<double> a) => (List.of(a)..sort())[a.length ~/ 2];

/// میانگین y چند نقطه‌ی قابل‌اعتماد؛ اگر هیچ‌کدام دیده نشد null.
double? _y(List<List<double>> l, List<int> ids) {
  final v = ids.where((i) => l[i][2] > 0.3).map((i) => l[i][1]).toList();
  return v.isEmpty ? null : v.reduce((a, b) => a + b) / v.length;
}

/// راهنمای چیدمان؛ null یعنی کادر مناسب است.
String? framingHint(List<List<double>> l, {bool standing = false}) {
  bool ok(int i) => l[i][2] > 0.5;
  if (!ok(0)) return 'سر شما دیده نمی‌شود';
  if (!(ok(27) || ok(28))) return 'کمی عقب‌تر بروید تا کل بدن دیده شود';
  final ys = l.map((p) => p[1]);
  if (ys.reduce(m.min) < 0.02 || ys.reduce(m.max) > 0.98) return 'کمی عقب‌تر بروید';
  if (standing) {
    final h = (l[27][1] - l[0][1]).abs();
    if (h > 0 && (l[11][0] - l[12][0]).abs() / h > 0.3) return 'کمی بچرخید تا از پهلو دیده شوید';
  }
  return null;
}

/// ویژگی‌های یک فریم (همه نسبت به قد ایستادهٔ همان فرد). ترکیبی از شکل کلی بدن
/// (مقاوم در برابر چادر) و چند نقطهٔ کلیدی: سر نسبت به لگن، زانو و مچ نسبت به زمین.
class Frame {
  Frame(this.h, this.w, this.head, this.trunk, this.vis, this.nh, this.kn, this.wr);
  final double h, w, head, trunk, vis, nh, kn, wr;

  static Frame? from(List<List<double>> l) {
    final p = l.where((e) => e[2] > 0.3).toList();
    if (p.length < 8) return null;
    final xs = p.map((e) => e[0]), ys = p.map((e) => e[1]);
    final minY = ys.reduce(m.min), maxY = ys.reduce(m.max);
    final w = xs.reduce(m.max) - xs.reduce(m.min);
    double mid(int a, int b, int k) => (l[a][k] + l[b][k]) / 2;
    final dx = (mid(11, 12, 0) - mid(23, 24, 0)).abs();
    final dy = (mid(11, 12, 1) - mid(23, 24, 1)).abs();
    final trunk = m.atan2(dx, dy) / (m.pi / 2); // 0 عمودی، 1 افقی
    final vis = [0, 11, 12, 23, 24].map((i) => l[i][2]).reduce((a, b) => a + b) / 5;
    final shY = mid(11, 12, 1);
    final hipY = _y(l, [23, 24]) ?? shY;
    final nh = hipY - l[0][1]; // مثبت: سر بالاتر از لگن (قیام)، منفی: سجده
    final kn = maxY - (_y(l, [25, 26]) ?? hipY); // ارتفاع زانو از پایین‌ترین نقطه
    final wr = maxY - (_y(l, [15, 16]) ?? shY); // ارتفاع مچ از پایین‌ترین نقطه
    return Frame(maxY - minY, w, maxY - l[0][1], trunk, vis, nh, kn, wr);
  }

  List<double> vec(double hs) => [h / hs, w / hs, head / hs, trunk, nh / hs, kn / hs, wr / hs];
}

const _wt = [1.0, 1.0, 1.5, 0.7, 1.2, 0.8, 0.5];
double _dist(List<double> a, List<double> b) {
  var s = 0.0;
  for (var i = 0; i < a.length; i++) {
    final d = (a[i] - b[i]) * _wt[i];
    s += d * d;
  }
  return m.sqrt(s);
}

/// کالیبراسیون شخصی + kNN نرم + میانگین متحرک نمایی (EMA) روی احتمال هر حالت.
/// حالت‌های گذار (که به هیچ نمونه‌ای شبیه نیستند) unknown می‌شوند و شمارش را خراب نمی‌کنند.
class Calibration {
  final _raw = <Pose, List<Frame>>{};
  final _s = <(Pose, List<double>)>[];
  final _ema = <Pose, double>{};
  double hs = 1;
  bool ready = false;

  void reset() { _raw.clear(); _s.clear(); _ema.clear(); ready = false; }
  void add(Pose p, Frame f) => (_raw[p] ??= []).add(f);

  // آستانه‌ها از داده‌ی کالیبراسیونِ همان فرد محاسبه می‌شوند، نه عدد ثابت.
  double sigma = 0.2, farTh = 0.7;
  String? problem; // دلیل ناموفق‌بودن کالیبراسیون (برای نمایش به کاربر)

  static const _fa = {Pose.qiyam: 'قیام', Pose.ruku: 'رکوع', Pose.sujud: 'سجده', Pose.julus: 'جلسه'};

  bool finish() {
    problem = null;
    final q = _raw[Pose.qiyam];
    if (q == null || q.length < 8) {
      problem = 'قیام به‌اندازهٔ کافی ثبت نشد؛ کامل در کادر بایستید.';
      return false;
    }
    hs = _med(q.map((f) => f.h).toList());
    _s.clear();
    _ema.clear();
    final cent = <Pose, List<double>>{};
    final nn = <double>[];
    for (final p in _poses) {
      final fs = _raw[p] ?? [];
      if (fs.length < 8) {
        problem = '«${_fa[p]}» به‌اندازهٔ کافی ثبت نشد؛ بدن‌تان در این حالت باید کامل دیده شود.';
        return false;
      }
      var vs = [for (final f in fs) f.vec(hs)];
      // حذف فریم‌های پرت (مثلاً لحظه‌ای که فرد هنوز در راه رسیدن به حالت بوده)
      final mv = [for (var i = 0; i < vs.first.length; i++) _med(vs.map((v) => v[i]).toList())];
      final ds = vs.map((v) => _dist(v, mv)).toList();
      final lim = m.max(3 * _med(ds), 0.12);
      vs = [for (var i = 0; i < vs.length; i++) if (ds[i] <= lim) vs[i]];
      if (vs.length < 8) {
        problem = '«${_fa[p]}» پایدار نبود؛ در همان حالت بدون حرکت بمانید.';
        return false;
      }
      for (final v in vs) { _s.add((p, v)); }
      cent[p] = [for (var i = 0; i < vs.first.length; i++) vs.map((v) => v[i]).reduce((a, b) => a + b) / vs.length];
      for (var i = 0; i < vs.length; i++) {
        var best = double.infinity;
        for (var j = 0; j < vs.length; j++) {
          if ((i - j).abs() < 3) continue; // فریم‌های مجاور تقریباً یکسانند
          best = m.min(best, _dist(vs[i], vs[j]));
        }
        if (best.isFinite) nn.add(best);
      }
    }
    nn.sort();
    final p90 = nn[(nn.length * 0.9).floor().clamp(0, nn.length - 1).toInt()];
    sigma = (p90 * 1.2).clamp(0.08, 0.3).toDouble();
    farTh = (p90 * 4).clamp(0.4, 1.0).toDouble();
    // آیا حالت‌ها از هم قابل‌تفکیک‌اند؟
    for (var i = 0; i < _poses.length; i++) {
      for (var j = i + 1; j < _poses.length; j++) {
        if (_dist(cent[_poses[i]]!, cent[_poses[j]]!) < 1.5 * sigma) {
          problem = '«${_fa[_poses[i]]}» و «${_fa[_poses[j]]}» برای دوربین شبیه‌اند. گوشی را دقیقاً از پهلو و کمی دورتر بگذارید و حالت‌ها را کامل‌تر بگیرید.';
          return false;
        }
      }
    }
    return ready = true;
  }

  /// (حالت، اطمینان بین ۰ تا ۱)
  (Pose, double) classify(Frame f) {
    final v = f.vec(hs);
    final d = _s.map((s) => (s.$1, _dist(v, s.$2))).toList()..sort((a, b) => a.$2.compareTo(b.$2));
    if (d.first.$2 > farTh || f.vis < 0.4) return (Pose.unknown, 0.0); // گذار یا دید ضعیف
    final sc = {for (final p in _poses) p: 0.0};
    var tot = 0.0;
    for (final e in d.take(9)) {
      final w = m.exp(-e.$2 * e.$2 / (2 * sigma * sigma));
      sc[e.$1] = sc[e.$1]! + w;
      tot += w;
    }
    if (tot < 1e-9) return (Pose.unknown, 0.0);
    const a = 0.4;
    for (final p in _poses) {
      _ema[p] = a * sc[p]! / tot + (1 - a) * (_ema[p] ?? sc[p]! / tot);
    }
    final best = _poses.reduce((x, y) => _ema[x]! >= _ema[y]! ? x : y);
    final conf = _ema[best]!;
    return conf < 0.55 ? (Pose.unknown, conf) : (best, conf);
  }
}

/// ماشین حالت مبتنی بر «دستور زبان نماز» و زمان واقعی (نه تعداد فریم).
/// رکعت با دیدن «قیام بعد از حداقل یک سجده» شمرده می‌شود، نه با شمردن دقیق ۲ سجده؛
/// پس از دست‌رفتن یک فریم یا یک حالت، شمارش از مسیر خارج نمی‌شود.
class RakatCounter {
  RakatCounter(this.total);
  final int total;
  int rakat = 1, sujud = 0;
  bool done = false;
  Pose stable = Pose.unknown, _cand = Pose.unknown;
  int _since = 0, _stableAt = 0;
  bool _sat = false; // بین دو سجده نشسته؟ (جلوی دوبار شمردن یک سجده را می‌گیرد)
  static const dwellMs = 450, finalSitMs = 4500;
  void Function(String event)? onEvent;

  void update(Pose p, {int? nowMs}) {
    final t = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    if (done) return;
    // پشت‌سرهم نشستن در آخرین رکعت (تشهد) یعنی نماز تمام شده، حتی اگر یک سجده گم شده باشد
    if (stable == Pose.julus && rakat >= total && sujud >= 1 && t - _stableAt >= finalSitMs) {
      return _finish();
    }
    if (p == Pose.unknown) return;
    if (p != _cand) { _cand = p; _since = t; return; }
    if (p == stable || t - _since < dwellMs) return;
    final from = stable;
    stable = p;
    _stableAt = t;
    _go(from, p);
  }

  void _finish() { done = true; onEvent?.call('finished'); }

  void _go(Pose from, Pose to) {
    switch (to) {
      case Pose.ruku:
        if (from == Pose.qiyam) onEvent?.call('takbir'); // گذار سجده→قیام از حالت شبیه رکوع نمی‌شمارد
      case Pose.sujud:
        if (sujud == 0 || _sat) {
          sujud++;
          _sat = false;
          onEvent?.call('takbir');
        }
      case Pose.julus:
        if (from == Pose.sujud && sujud >= 1) {
          _sat = true;
          onEvent?.call('takbir');
          if (sujud >= 2 && rakat >= total) _finish();
        }
      case Pose.qiyam:
        if (sujud >= 1) {
          sujud = 0;
          _sat = false;
          if (rakat < total) {
            rakat++;
            onEvent?.call('takbir');
            onEvent?.call('rakat_$rakat');
          }
        }
      case Pose.unknown:
        break;
    }
  }
}
