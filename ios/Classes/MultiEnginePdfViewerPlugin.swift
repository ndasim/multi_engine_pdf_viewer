import Flutter
import UIKit

public final class MultiEnginePdfViewerPlugin: NSObject, FlutterPlugin {
    public static func register(with registrar: FlutterPluginRegistrar) {
        registrar.register(
            PdfKitViewFactory(messenger: registrar.messenger()),
            withId: PdfKitViewFactory.viewType
        )
    }
}
