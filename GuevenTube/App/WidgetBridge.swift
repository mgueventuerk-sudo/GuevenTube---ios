import WidgetKit
import GuevenCore

/// Schreibt die „Weiterschauen“-Liste in den App-Group-Speicher und stößt das Widget an. Apple-only, ungetestet.
enum WidgetBridge {
    static func refresh() async {
        let items = await AppEnvironment.shared.library.continueWatching(limit: WidgetSnapshot.maxEntries)
        guard let defaults = UserDefaults(suiteName: WidgetSnapshot.appGroup) else { return }
        defaults.set(WidgetSnapshot(continueWatching: items).encoded(), forKey: WidgetSnapshot.defaultsKey)
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetSnapshot.widgetKind)
    }
}
