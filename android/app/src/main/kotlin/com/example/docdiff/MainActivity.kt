package com.example.docdiff

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.nio.charset.Charset

class MainActivity : FlutterActivity() {

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // —— 编码解码（GBK/GB2312/GB18030/Big5/Shift-JIS 走系统 ICU） ——
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "docdiff/encoding")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "decode" -> {
                        try {
                            val bytes = call.argument<ByteArray>("bytes")
                            val charsetName = call.argument<String>("charset") ?: "UTF-8"
                            if (bytes == null) {
                                result.error("ARG", "bytes is null", null)
                                return@setMethodCallHandler
                            }
                            val charset = when (charsetName) {
                                "GB2312" -> Charset.forName("GBK")   // GB2312 ⊂ GBK
                                "Shift-JIS" -> Charset.forName("Shift_JIS")
                                else -> Charset.forName(charsetName)
                            }
                            // String(bytes, Charset) 对非法字节输出 U+FFFD，不抛异常
                            result.success(String(bytes, charset))
                        } catch (e: Exception) {
                            result.error("DECODE", e.message ?: "decode failed", null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
