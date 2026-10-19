import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:ui_web' as ui_web;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:web/web.dart' as web;
import 'core.dart';

@JS('PoseBridge')
external _Bridge get _bridge;

extension type _Bridge._(JSObject _) implements JSObject {
  external JSPromise<JSAny?> start(JSFunction cb, int fps);
  external void stop();
  external void beep(int freq, int ms);
  external bool say(String text, String lang, bool cut);
  external web.HTMLVideoElement get video;
}

void main() {
  ui_web.platformViewRegistry.registerViewFactory('cam', (int _) => _bridge.video);
  runApp(const App());
}

class App extends StatelessWidget {
  const App({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'رکعت‌شمار هوشمند',
        theme: ThemeData(useMaterial3: true, fontFamily: 'Vazirmatn', colorSchemeSeed: const Color(0xFF1F5F54)),
        builder: (c, w) => Directionality(textDirection: TextDirection.rtl, child: w!),
        home: const Home(),
      );
}

enum Stage { intro, setup, calib, run }

const order = [Pose.qiyam, Pose.ruku, Pose.sujud, Pose.julus];
const faName = {Pose.qiyam: 'قیام', Pose.ruku: 'رکوع', Pose.sujud: 'سجده', Pose.julus: 'جلسه', Pose.unknown: '…'};
const faHow = {
  Pose.qiyam: 'صاف بایستید',
  Pose.ruku: 'به رکوع بروید',
  Pose.sujud: 'به سجده بروید',
  Pose.julus: 'بنشینید (جلسه)',
};

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  Stage stage = Stage.intro;
  List<dynamic> prayers = [];
  Map<String, dynamic>? prayer;
  bool hide = false, capturing = false;
  String? hint = 'در حال آماده‌سازی…', error;
  String cmsg = '';
  int ci = 0;
  Pose pose = Pose.unknown;
  double conf = 0;
  final cal = Calibration();
  RakatCounter? counter;
  int okFrames = 0, frames = 0;
  DateTime lastSay = DateTime(2000);
  String? lastHint;
  Timer? timer;

  @override
  void initState() {
    super.initState();
    rootBundle.loadString('assets/prayers.json').then((s) => setState(() {
          prayers = jsonDecode(s);
          prayer = prayers.first;
        }));
  }

  @override
  void dispose() {
    timer?.cancel();
    _bridge.stop();
    super.dispose();
  }

  static const _nth = {'2': 'دوم', '3': 'سوم', '4': 'چهارم'};

  /// اگر دستگاه صدای فارسی/عربی نداشته باشد، به‌جای سکوت با بوق خبر می‌دهد.
  void _beeps(int n) {
    for (var i = 0; i < n; i++) {
      Future.delayed(Duration(milliseconds: i * 350), () => _bridge.beep(900, 150));
    }
  }

  void _sfx(String e) {
    if (e == 'takbir') {
      if (!_bridge.say('الله أکبر', 'ar-SA', false)) _beeps(1);
    } else if (e.startsWith('rakat_')) {
      final n = int.tryParse(e.substring(6)) ?? 1;
      final nth = _nth['$n'] ?? '$n';
      if (!_bridge.say('رکعت $nth', 'fa-IR', false)) Future.delayed(const Duration(milliseconds: 500), () => _beeps(n));
    } else if (e == 'finished') {
      _bridge.beep(1000, 400);
      _bridge.say('نماز تمام شد', 'fa-IR', false);
    }
  }

  /// راهنمای صوتی و شروع خودکار: بدون لمس صفحه.
  void _guide() {
    if (hint == null) {
      lastHint = null;
      if (++okFrames >= 36) {
        okFrames = 0;
        Future.microtask(_beginCalib);
      }
    } else {
      okFrames = 0;
      final now = DateTime.now();
      if (hint != lastHint && now.difference(lastSay).inSeconds >= 3) {
        lastHint = hint;
        lastSay = now;
        _bridge.say(hint!, 'fa-IR', true);
      }
    }
  }

  Future<void> _start() async {
    setState(() => error = null);
    try {
      await _bridge.start(((JSString s) => _onPose(s.toDart)).toJS, 12).toDart;
      setState(() => stage = Stage.setup);
    } catch (_) {
      setState(() => error = 'دسترسی به دوربین یا بارگذاری مدل ممکن نشد. اجازهٔ دوربین را بررسی کنید.');
    }
  }

  void _onPose(String s) {
    List<List<double>>? l;
    if (s.isNotEmpty) {
      l = [for (final e in jsonDecode(s) as List) [for (final n in e as List) (n as num).toDouble()]];
    }
    final f = l == null ? null : Frame.from(l);
    setState(() {
      frames++;
      hint = l == null ? 'شما در کادر دیده نمی‌شوید' : framingHint(l, standing: stage == Stage.setup);
      if (stage == Stage.setup) _guide();
      if (f == null) { pose = Pose.unknown; return; }
      if (stage == Stage.calib && capturing) cal.add(order[ci], f);
      if (stage == Stage.run && cal.ready) {
        final r = cal.classify(f);
        pose = r.$1;
        conf = r.$2;
        counter!.update(pose);
      }
    });
  }

  void _beginCalib() {
    if (stage != Stage.setup) return;
    cal.reset();
    ci = 0;
    setState(() { stage = Stage.calib; error = null; });
    _nextCalib();
  }

  void _nextCalib() {
    if (ci >= order.length) {
      if (cal.finish()) {
        counter = RakatCounter(prayer!['rakats'] as int)..onEvent = _sfx;
        _bridge.beep(1000, 300);
        _bridge.say('آماده‌ام. نماز را شروع کنید', 'fa-IR', true);
        setState(() => stage = Stage.run);
      } else {
        setState(() { stage = Stage.setup; error = cal.problem ?? 'کالیبراسیون کامل نشد. کادر را بررسی و دوباره تلاش کنید.'; });
      }
      return;
    }
    var t = ci == 0 ? 4 : 7;
    _bridge.say(faHow[order[ci]]!, 'fa-IR', true);
    setState(() { cmsg = '$t'; capturing = false; });
    timer = Timer.periodic(const Duration(seconds: 1), (x) {
      t--;
      if (t >= 1) {
        setState(() => cmsg = '$t');
      } else if (t == 0) {
        _bridge.beep(1200, 150);
        setState(() { capturing = true; cmsg = 'ثبت…'; });
      } else if (t == -3) {
        x.cancel();
        setState(() => capturing = false);
        ci++;
        _nextCalib();
      }
    });
  }

  void _stop() {
    timer?.cancel();
    _bridge.stop();
    setState(() { stage = Stage.intro; pose = Pose.unknown; capturing = false; okFrames = 0; frames = 0; counter = null; });
  }

  Widget _preview([double h = 280]) => SizedBox(
        height: h,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: hide
              ? const ColoredBox(color: Color(0x14000000), child: Center(child: Icon(Icons.person_outline, size: 96)))
              : const HtmlElementView(viewType: 'cam'),
        ),
      );

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(20),
            // پیش‌نمایش دوربین بین مرحله‌ها ثابت می‌ماند تا ویدیو قطع و وصل نشود
            child: Column(children: [
              if (stage != Stage.intro)
                _preview(stage == Stage.setup ? 320 : stage == Stage.calib ? 260 : (hide ? 0 : 140)),
              if (stage != Stage.intro) Text('فریم‌های دریافتی: $frames', style: Theme.of(context).textTheme.bodySmall),
              Expanded(
                child: switch (stage) {
                  Stage.intro => _intro(),
                  Stage.setup => _setup(),
                  Stage.calib => _calib(),
                  Stage.run => _run(),
                },
              ),
            ]),
          ),
        ),
      );

  Widget _intro() => ListView(children: [
        Text('رکعت‌شمار هوشمند', style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        const Text('تصویر شما فقط روی همین دستگاه پردازش می‌شود. هیچ تصویری ذخیره یا ارسال نمی‌شود و برنامه بدون اینترنت کار می‌کند.'),
        const SizedBox(height: 24),
        const Text('نماز'),
        const SizedBox(height: 8),
        Wrap(spacing: 8, children: [
          for (final p in prayers)
            ChoiceChip(
              label: Text('${p['name']} (${p['rakats']} رکعت)'),
              selected: prayer == p,
              onSelected: (_) => setState(() => prayer = p),
            ),
        ]),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('پنهان‌کردن پیش‌نمایش دوربین'),
          subtitle: const Text('دوربین کار می‌کند ولی تصویر شما روی صفحه دیده نمی‌شود'),
          value: hide,
          onChanged: (v) => setState(() => hide = v),
        ),
        if (error != null) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
        FilledButton(onPressed: prayer == null ? null : _start, child: const Text('روشن‌کردن دوربین')),
      ]);

  Widget _setup() => ListView(children: [
        const SizedBox(height: 16),
        Text(hint ?? 'چیدمان مناسب است', style: Theme.of(context).textTheme.headlineSmall?.copyWith(color: hint == null ? Colors.green.shade800 : null)),
        const SizedBox(height: 8),
        const Text('گوشی را از پهلو، حدود ۲ تا ۳ متر دورتر، هم‌سطح کمر یا کمی بالاتر روی جای ثابتی بگذارید. کل بدن از سر تا پا باید دیده شود.'),
        if (error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
        const SizedBox(height: 16),
        Text(hint == null ? 'ثابت بمانید؛ تا چند ثانیه دیگر خودکار شروع می‌شود…' : 'بعد از قرارگرفتن در کادر، همه‌چیز خودکار شروع می‌شود و لازم نیست صفحه را لمس کنید.'),
        TextButton(onPressed: hint == null ? _beginCalib : null, child: const Text('شروع فوری')),
        TextButton(onPressed: _stop, child: const Text('بازگشت')),
      ]);

  Widget _calib() => Column(children: [
        const Spacer(),
        Text('${ci + 1} از ${order.length}'),
        Text(faHow[order[ci.clamp(0, 3)]]!, style: Theme.of(context).textTheme.headlineSmall),
        Text(cmsg, style: Theme.of(context).textTheme.displayMedium),
        const Text('تا شمارش تمام نشده در همان حالت بمانید'),
        const Spacer(),
      ]);

  Widget _run() {
    final c = counter!;
    final cs = Theme.of(context).colorScheme;
    return Column(children: [
      const Spacer(),
      Text(c.done ? 'نماز تمام شد' : 'رکعت', style: Theme.of(context).textTheme.titleLarge),
      Text('${c.rakat}', style: TextStyle(fontSize: 150, fontWeight: FontWeight.bold, height: 1, color: cs.primary)),
      Text('از ${c.total}'),
      const SizedBox(height: 16),
      Chip(label: Text(faName[pose]!)),
      const SizedBox(height: 8),
      SizedBox(width: 200, child: LinearProgressIndicator(value: conf)),
      Text(pose == Pose.unknown ? 'نامطمئن؛ شمارش متوقف است' : 'اطمینان تشخیص', style: Theme.of(context).textTheme.bodySmall),
      const Spacer(),
      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        IconButton.outlined(onPressed: c.rakat > 1 ? () => setState(() { c.rakat--; c.sujud = 0; }) : null, icon: const Icon(Icons.remove)),
        const Padding(padding: EdgeInsets.symmetric(horizontal: 12), child: Text('تصحیح دستی')),
        IconButton.outlined(onPressed: c.rakat < c.total ? () => setState(() { c.rakat++; c.sujud = 0; }) : null, icon: const Icon(Icons.add)),
      ]),
      TextButton(onPressed: _stop, child: const Text('پایان')),
    ]);
  }
}
