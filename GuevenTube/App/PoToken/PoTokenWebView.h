#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Dünne Objective-C-Hülle um WKWebView für den BotGuard-Generator. Absichtlich nicht in Swift: `import WebKit` zieht das
/// Swift-Overlay `libswiftWebKit.dylib` ein, das auf iOS-18-Laufzeiten fehlt (App stürzt beim Start ab, dyld „Library not loaded“).
/// Alle Methoden nur auf dem Haupt-Thread aufrufen; die Rückrufe kommen auf dem Haupt-Thread.
@interface PoTokenWebView : NSObject

- (instancetype)initWithUserAgent:(NSString *)userAgent;

/// Lädt [html] mit [baseURL] als Ursprung. Fehlertext oder `nil` bei Erfolg.
- (void)loadHTML:(NSString *)html baseURL:(NSString *)baseURL completion:(void (^)(NSString *_Nullable error))completion;

/// Führt [body] als asynchrone Funktion im Seitenkontext aus (Promises werden abgewartet). [arguments] sind Namen → Plist-Werte.
- (void)callAsync:(NSString *)body arguments:(NSDictionary<NSString *, id> *)arguments
       completion:(void (^)(id _Nullable result, NSString *_Nullable error))completion;

/// Hängt das (unsichtbare) WebView ins erste Fenster, falls schon eines existiert.
- (void)attachToWindow;

- (void)close;

@property (nonatomic, readonly) BOOL terminated;

@end

NS_ASSUME_NONNULL_END
