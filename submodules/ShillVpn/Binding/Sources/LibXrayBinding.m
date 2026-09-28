#import <LibXrayBinding/LibXrayBinding.h>

#include <libXray.h>

NSString * _Nullable ShillXrayInvoke(NSString *request) {
    const char *utf8 = [request UTF8String];
    if (utf8 == NULL) {
        return nil;
    }
    char *copy = strdup(utf8);
    if (copy == NULL) {
        return nil;
    }
    char *response = CGoInvoke(copy);
    free(copy);
    if (response == NULL) {
        return nil;
    }
    NSString *result = [[NSString alloc] initWithUTF8String:response];
    CGoFree(response);
    return result;
}
