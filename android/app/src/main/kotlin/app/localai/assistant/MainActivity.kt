package app.localai.assistant

import android.app.ActivityManager
import android.content.Context
import android.os.StatFs
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/** Native Android integration: memory info, free storage, trim-memory events. Local only. */
class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "app.localai/native")
        channel = ch
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "memoryInfo" -> {
                    val am = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
                    val mi = ActivityManager.MemoryInfo()
                    am.getMemoryInfo(mi)
                    result.success(
                        mapOf(
                            "total" to mi.totalMem,
                            "avail" to mi.availMem,
                            "threshold" to mi.threshold,
                            "low" to mi.lowMemory
                        )
                    )
                }
                "freeStorage" -> {
                    val path = call.argument<String>("path")
                    if (path == null) {
                        result.error("ARG", "path is required", null)
                    } else {
                        try {
                            result.success(StatFs(path).availableBytes)
                        } catch (e: Exception) {
                            result.error("STAT", e.message, null)
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onTrimMemory(level: Int) {
        super.onTrimMemory(level)
        channel?.invokeMethod("trimMemory", level)
    }
}
