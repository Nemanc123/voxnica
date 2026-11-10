package com.voxnica.voxnica

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Показ экрана требует foreground service с типом mediaProjection.
        // Flutter-клиент включает и выключает его вокруг setScreenShareEnabled.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SCREEN_SHARE_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        ScreenShareService.start(this)
                        result.success(null)
                    }
                    "stop" -> {
                        ScreenShareService.stop(this)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    companion object {
        private const val SCREEN_SHARE_CHANNEL = "voxnica/screen_share"
    }
}
