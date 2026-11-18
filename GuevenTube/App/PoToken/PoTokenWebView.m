#import "PoTokenWebView.h"
#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>

@interface PoTokenWebView () <WKNavigationDelegate>
@property (nonatomic, strong) WKWebView *webView;
@property (nonatomic, copy, nullable) void (^loadCompletion)(NSString *_Nullable);
@property (nonatomic, readwrite) BOOL terminated;
@end

@implementation PoTokenWebView

- (instancetype)initWithUserAgent:(NSString *)userAgent {
    if ((self = [super init])) {
        WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
        config.websiteDataStore = [WKWebsiteDataStore nonPersistentDataStore];
        _webView = [[WKWebView alloc] initWithFrame:CGRectMake(0, 0, 1, 1) configuration:config];
        _webView.customUserAgent = userAgent;
        _webView.navigationDelegate = self;
        _webView.userInteractionEnabled = NO;
        _webView.alpha = 0.01;
    }
    return self;
}

- (void)attachToWindow {
    if (self.webView.superview != nil) { return; }
    // Zeitgeber laufen in WebViews ohne Fenster nur gedrosselt: unsichtbar ins Fenster hängen (sobald eines existiert).
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]]) {
            UIWindow *window = ((UIWindowScene *)scene).windows.firstObject;
            if (window != nil) { [window addSubview:self.webView]; return; }
        }
    }
}

- (void)loadHTML:(NSString *)html baseURL:(NSString *)baseURL completion:(void (^)(NSString *_Nullable))completion {
    self.loadCompletion = completion;
    [self.webView loadHTMLString:html baseURL:[NSURL URLWithString:baseURL]];
}

- (void)callAsync:(NSString *)body arguments:(NSDictionary<NSString *, id> *)arguments
       completion:(void (^)(id _Nullable, NSString *_Nullable))completion {
    if (self.terminated) { completion(nil, @"WebView beendet"); return; }
    [self.webView callAsyncJavaScript:body arguments:arguments inFrame:nil inContentWorld:WKContentWorld.pageWorld
                    completionHandler:^(id _Nullable result, NSError *_Nullable error) {
        if (error != nil) {
            NSString *detail = error.userInfo[@"WKJavaScriptExceptionMessage"] ?: error.localizedDescription;
            completion(nil, detail ?: @"JavaScript-Fehler");
        } else {
            completion(result, nil);
        }
    }];
}

- (void)close {
    if (self.terminated) { return; }
    self.terminated = YES;
    [self finishLoad:@"Generator freigegeben"];
    [self.webView stopLoading];
    [self.webView removeFromSuperview];
}

- (void)finishLoad:(NSString *_Nullable)error {
    void (^completion)(NSString *_Nullable) = self.loadCompletion;
    self.loadCompletion = nil;
    if (completion != nil) { completion(error); }
}

#pragma mark WKNavigationDelegate

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation { [self finishLoad:nil]; }

- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    [self finishLoad:error.localizedDescription];
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    [self finishLoad:error.localizedDescription];
}

- (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView { [self close]; }

// Nichts nachladen: Nur die eigene Seite, alles andere (Weiterleitungen, Verweise) wird verworfen.
- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction
                                                     decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    decisionHandler(navigationAction.navigationType == WKNavigationTypeOther ? WKNavigationActionPolicyAllow : WKNavigationActionPolicyCancel);
}

@end
