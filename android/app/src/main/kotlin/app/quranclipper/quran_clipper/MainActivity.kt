package app.quranclipper.quran_clipper

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "quran_clipper/keep_alive")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        KeepAliveService.start(applicationContext, call.argument<String>("text") ?: "Working…")
                        result.success(null)
                    }
                    "stop" -> {
                        KeepAliveService.stop(applicationContext)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
