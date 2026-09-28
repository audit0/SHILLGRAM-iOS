#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// SHILLGRAM: one call into the in-process Xray core (libXray's Invoke):
/// a JSON request in, a JSON response out; nil when the core returned nothing.
/// The request may carry the VPN config: never log it.
NSString * _Nullable ShillXrayInvoke(NSString *request);

NS_ASSUME_NONNULL_END
