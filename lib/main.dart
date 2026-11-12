// =============================================================
//  MediControl — APK Flutter (contenedor del sistema Apps Script)
//  SOLUCIONES INNOVATE · Transformando el futuro hoy
// =============================================================
//  El HTML vive DENTRO de la APK: assets/web/index.html
//  La URL de Apps Script (API) se configura en ese index.html (API_URL)
//  flutter pub get  →  flutter build apk --release
// =============================================================

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// Página principal empaquetada en la APK
const String kHtml = 'assets/web/index.html';

const Color kPri = Color(0xFF0E7C86);
const Color kPri2 = Color(0xFF0A5F67);
const Color kAcc = Color(0xFFE2680C);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    await InAppWebViewController.setWebContentsDebuggingEnabled(kDebugMode);
  }
  await Avisos.iniciar();
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: kPri2,
    statusBarIconBrightness: Brightness.light,
  ));
  runApp(const MediControlApp());
}

// =============================================================
//  NOTIFICACIONES LOCALES (suenan aunque la app esté cerrada)
// =============================================================
class Avisos {
  static final FlutterLocalNotificationsPlugin _p = FlutterLocalNotificationsPlugin();
  static const String _canal = 'medicacion';
  static String _ultimoStock = '';

  static AndroidFlutterLocalNotificationsPlugin? get _android =>
      _p.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();

  static Future<void> iniciar() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    tzdata.initializeTimeZones();
    await _p.initialize(
      const InitializationSettings(android: AndroidInitializationSettings('@mipmap/ic_launcher')),
    );
    await _android?.createNotificationChannel(const AndroidNotificationChannel(
      _canal,
      'Medicación',
      description: 'Recordatorios de tomas de medicación',
      importance: Importance.max,
      playSound: true,
      enableVibration: true,
    ));
  }

  /// Pide permiso de notificaciones (Android 13+) y de alarmas exactas.
  static Future<void> pedirPermisos() async {
    final a = _android;
    if (a == null) return;
    try {
      await a.requestNotificationsPermission();
      final exactas = await a.canScheduleExactNotifications() ?? true;
      if (!exactas) await a.requestExactAlarmsPermission();
    } catch (_) {}
  }

  static NotificationDetails _det(String cuerpo) => NotificationDetails(
        android: AndroidNotificationDetails(
          _canal,
          'Medicación',
          channelDescription: 'Recordatorios de tomas de medicación',
          importance: Importance.max,
          priority: Priority.high,
          category: AndroidNotificationCategory.reminder,
          styleInformation: BigTextStyleInformation(cuerpo),
          ticker: 'MediControl',
        ),
      );

  static Future<void> _agendar(int id, String titulo, String cuerpo, DateTime cuando, AndroidScheduleMode modo) async {
    try {
      await _p.zonedSchedule(id, titulo, cuerpo, tz.TZDateTime.from(cuando, tz.UTC), _det(cuerpo),
          androidScheduleMode: modo);
    } catch (_) {
      // si el sistema no permite alarmas exactas, cae a inexacta
      await _p.zonedSchedule(id, titulo, cuerpo, tz.TZDateTime.from(cuando, tz.UTC), _det(cuerpo),
          androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle);
    }
  }

  /// Recibe el JSON de la acción "alarmas" y reprograma todo. Devuelve cuántas quedaron.
  static Future<int> programar(String json) async {
    if (_android == null) return 0;
    final data = jsonDecode(json) as Map<String, dynamic>;
    final tomas = (data['tomas'] as List?) ?? const [];
    await _p.cancelAll();

    final exactas = await _android!.canScheduleExactNotifications() ?? false;
    final modo = exactas ? AndroidScheduleMode.exactAllowWhileIdle : AndroidScheduleMode.inexactAllowWhileIdle;
    final ahora = DateTime.now();
    var id = 100;
    var n = 0;

    for (final x in tomas) {
      if (id > 480) break; // límite de Android (~500 alarmas por app)
      final m = Map<String, dynamic>.from(x as Map);
      final cuando = DateTime.tryParse('${m['fecha']} ${m['hora']}:00');
      if (cuando == null) continue;
      final ind = '${m['indicaciones'] ?? ''}'.trim();
      final cuerpo = '${m['dosis']} · ${m['via']}\n${m['paciente']}${ind.isNotEmpty ? '\n📝 $ind' : ''}';

      if (cuando.isAfter(ahora)) {
        await _agendar(id++, '💊 ${m['hora']} · ${m['medicamento']}', cuerpo, cuando, modo);
        n++;
      }
      final tarde = cuando.add(const Duration(minutes: 30));
      if (tarde.isAfter(ahora)) {
        await _agendar(id++, '⏰ Toma atrasada · ${m['medicamento']}',
            'Programada a las ${m['hora']} y todavía no se registró.\n${m['paciente']}', tarde, modo);
        n++;
      }
    }

    // Stock bajo: aviso inmediato, una vez por día
    final stock = ((data['stockBajo'] as List?) ?? const []).map((e) => '$e').toList();
    final hoy = '${ahora.year}-${ahora.month}-${ahora.day}';
    if (stock.isNotEmpty && _ultimoStock != hoy) {
      _ultimoStock = hoy;
      await _p.show(2, '⚠ Stock bajo de medicación', stock.join('\n'), _det(stock.join('\n')));
    }
    return n;
  }

  static Future<void> cancelar() async {
    if (_android == null) return;
    await _p.cancelAll();
  }

  static Future<void> probar() async {
    await pedirPermisos();
    const cuerpo = 'Así vas a recibir los recordatorios de cada toma.';
    await _p.show(1, '💊 MediControl', cuerpo, _det(cuerpo));
  }
}

class MediControlApp extends StatelessWidget {
  const MediControlApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MediControl',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: kPri, primary: kPri),
        useMaterial3: true,
      ),
      home: const PantallaWeb(),
    );
  }
}

class PantallaWeb extends StatefulWidget {
  const PantallaWeb({super.key});

  @override
  State<PantallaWeb> createState() => _PantallaWebState();
}

class _PantallaWebState extends State<PantallaWeb> {
  InAppWebViewController? _ctl;
  double _progreso = 0;
  bool _error = false;
  bool _cargoUnaVez = false;

  /// Dominios que se abren DENTRO de la app. El resto (Drive, WhatsApp, mapas...) va al navegador/app externa.
  bool _esInterno(Uri? u) {
    if (u == null) return true;
    if (['about', 'data', 'blob', 'javascript', 'file'].contains(u.scheme)) return true;
    final h = u.host.toLowerCase();
    return h == 'script.google.com' ||
        h == 'accounts.google.com' ||
        h.endsWith('.googleusercontent.com') ||
        h.endsWith('.gstatic.com') ||
        h.endsWith('.googleapis.com');
  }

  Future<void> _abrirExterno(Uri u) async {
    try {
      await launchUrl(u, mode: LaunchMode.externalApplication);
    } catch (_) {
      _aviso('No se pudo abrir el enlace');
    }
  }

  void _aviso(String msg, {SnackBarAction? accion}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), action: accion, behavior: SnackBarBehavior.floating),
    );
  }

  /// Recibe un archivo en base64 desde la web, lo guarda y lo abre.
  Future<void> _guardarArchivo(String nombre, String mime, String b64) async {
    try {
      final bytes = base64Decode(b64);
      final dir = await getApplicationDocumentsDirectory();
      final carpeta = Directory('${dir.path}/MediControl');
      if (!await carpeta.exists()) await carpeta.create(recursive: true);
      final seguro = nombre.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
      final f = File('${carpeta.path}/$seguro');
      await f.writeAsBytes(bytes, flush: true);

      final r = await OpenFilex.open(f.path, type: mime);
      _aviso(
        r.type == ResultType.done ? 'Archivo listo: $seguro' : 'Guardado: $seguro (no hay app para abrirlo)',
        accion: SnackBarAction(
          label: 'COMPARTIR',
          textColor: kAcc,
          onPressed: () => Share.shareXFiles([XFile(f.path, mimeType: mime)], text: seguro),
        ),
      );
    } catch (e) {
      _aviso('Error al guardar el archivo: $e');
    }
  }

  Future<void> _procesarMensaje(String txt) async {
    try {
      final m = jsonDecode(txt) as Map<String, dynamic>;
      if (m['accion'] == 'guardar') {
        await _guardarArchivo('${m['nombre']}', '${m['mime']}', '${m['b64']}');
      }
    } catch (e) {
      _aviso('Mensaje inválido de la web');
    }
  }

  Future<void> _configurarPuente(InAppWebViewController c) async {
    // Puente para el iframe de Apps Script (se inyecta en TODOS los frames)
    if (defaultTargetPlatform == TargetPlatform.android &&
        await WebViewFeature.isFeatureSupported(WebViewFeature.WEB_MESSAGE_LISTENER)) {
      await c.addWebMessageListener(WebMessageListener(
        jsObjectName: 'MediBridge',
        allowedOriginRules: {'*'},
        onPostMessage: (message, sourceOrigin, isMainFrame, replyProxy) async {
          final dynamic m = message;
          final String txt = m is String ? m : (m?.data?.toString() ?? '');
          if (txt.isNotEmpty) await _procesarMensaje(txt);
        },
      ));
    }
    // Notificaciones programadas
    c.addJavaScriptHandler(
      handlerName: 'programarAlarmas',
      callback: (args) async {
        if (args.isEmpty) return 0;
        await Avisos.pedirPermisos();
        return Avisos.programar('${args[0]}');
      },
    );
    c.addJavaScriptHandler(handlerName: 'cancelarAlarmas', callback: (args) async {
      await Avisos.cancelar();
      return true;
    });
    c.addJavaScriptHandler(handlerName: 'probarNotificacion', callback: (args) async {
      await Avisos.probar();
      return true;
    });

    // Guardar/abrir archivos
    c.addJavaScriptHandler(
      handlerName: 'guardarArchivo',
      callback: (args) async {
        if (args.length >= 3) await _guardarArchivo('${args[0]}', '${args[1]}', '${args[2]}');
        return true;
      },
    );
  }

  Future<void> _cargar() async {
    setState(() => _error = false);
    await _ctl?.loadFile(assetFilePath: kHtml);
  }

  Future<bool> _confirmarSalida() async {
    final r = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Salir'),
        content: const Text('¿Cerrar MediControl?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('No')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Salir')),
        ],
      ),
    );
    return r ?? false;
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        if (_ctl != null && await _ctl!.canGoBack()) {
          await _ctl!.goBack();
          return;
        }
        if (await _confirmarSalida()) SystemNavigator.pop();
      },
      child: Scaffold(
        backgroundColor: Colors.white,
        body: SafeArea(
          child: Stack(
            children: [
              InAppWebView(
                initialSettings: InAppWebViewSettings(
                  javaScriptEnabled: true,
                  domStorageEnabled: true,
                  databaseEnabled: true,
                  cacheEnabled: true,
                  thirdPartyCookiesEnabled: true,
                  useShouldOverrideUrlLoading: true,
                  useOnDownloadStart: true,
                  supportMultipleWindows: true,
                  javaScriptCanOpenWindowsAutomatically: true,
                  mediaPlaybackRequiresUserGesture: false,
                  allowFileAccess: true,
                  allowFileAccessFromFileURLs: true,
                  allowUniversalAccessFromFileURLs: true,
                  supportZoom: false,
                  builtInZoomControls: false,
                  applicationNameForUserAgent: 'MediControlApp/1.0',
                ),
                onWebViewCreated: (c) async {
                  _ctl = c;
                  await _configurarPuente(c);
                  await _cargar();
                },
                onProgressChanged: (c, p) => setState(() => _progreso = p / 100),
                onLoadStop: (c, url) => setState(() => _cargoUnaVez = true),
                onReceivedError: (c, request, error) {
                  if (request.isForMainFrame ?? false) setState(() => _error = true);
                },
                shouldOverrideUrlLoading: (c, accion) async {
                  final u = accion.request.url;
                  if (!accion.isForMainFrame || _esInterno(u)) return NavigationActionPolicy.ALLOW;
                  await _abrirExterno(u!);
                  return NavigationActionPolicy.CANCEL;
                },
                onCreateWindow: (c, accion) async {
                  // window.open / target=_blank → navegador externo
                  final u = accion.request.url;
                  if (u != null && u.toString() != 'about:blank') await _abrirExterno(u);
                  return false;
                },
                onDownloadStartRequest: (c, req) async => _abrirExterno(req.url),
                onPermissionRequest: (c, req) async => PermissionResponse(
                  resources: req.resources,
                  action: PermissionResponseAction.GRANT,
                ),
              ),
              if (_progreso < 1)
                LinearProgressIndicator(value: _progreso, minHeight: 3, color: kAcc, backgroundColor: Colors.transparent),
              if (!_cargoUnaVez && !_error) const _Splash(),
              if (_error) _SinConexion(onReintentar: _cargar),
            ],
          ),
        ),
      ),
    );
  }
}

class _Splash extends StatelessWidget {
  const _Splash();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: kPri,
      alignment: Alignment.center,
      child: const Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.medication_rounded, size: 84, color: Colors.white),
          SizedBox(height: 12),
          Text('MediControl', style: TextStyle(color: Colors.white, fontSize: 30, fontWeight: FontWeight.w700)),
          SizedBox(height: 4),
          Text('Control de medicación y ficha médica', style: TextStyle(color: Colors.white70)),
          SizedBox(height: 28),
          SizedBox(width: 30, height: 30, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 3)),
        ],
      ),
    );
  }
}

class _SinConexion extends StatelessWidget {
  final VoidCallback onReintentar;
  const _SinConexion({required this.onReintentar});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.all(32),
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.wifi_off_rounded, size: 72, color: kPri),
          const SizedBox(height: 16),
          const Text('Sin conexión', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700, color: kPri2)),
          const SizedBox(height: 8),
          const Text('Revisá tu conexión a internet e intentá de nuevo.', textAlign: TextAlign.center),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: onReintentar,
            icon: const Icon(Icons.refresh),
            label: const Text('Reintentar'),
            style: FilledButton.styleFrom(backgroundColor: kPri),
          ),
        ],
      ),
    );
  }
}
