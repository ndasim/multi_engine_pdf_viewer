package com.thy.perf.pdfjs_perf_harness

import android.os.Bundle
import android.webkit.WebView
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
	override fun onCreate(savedInstanceState: Bundle?) {
		super.onCreate(savedInstanceState)
		if (BuildConfig.BUILD_TYPE != "release") {
			WebView.setWebContentsDebuggingEnabled(true)
		}
	}
}
