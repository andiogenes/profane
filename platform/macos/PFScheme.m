#import "PFScheme.h"

#import <AppKit/AppKit.h>

#include "pf_scheme.h"

void pf_app_quit(void) {
    /* Never terminate from inside Scheme: deinit would run under the active Scheme frame. */
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSApp terminate:nil];
    });
}

int PFSchemeBoot(void) {
    NSString *resources = NSBundle.mainBundle.resourcePath;
    NSString *bootDir = [resources stringByAppendingPathComponent:@"boot"];
    NSString *schemeDir = [resources stringByAppendingPathComponent:@"scheme"];
    static const pf_scheme_symbol symbols[] = {
        {"pf_app_quit", (void *)pf_app_quit},
    };
    pf_scheme_options opts = {
        .boot_dir = bootDir.fileSystemRepresentation,
        .scheme_dir = schemeDir.fileSystemRepresentation,
        .symbols = symbols,
        .symbol_count = sizeof symbols / sizeof symbols[0],
    };
    return pf_scheme_init(&opts);
}

NSString *PFSchemeCallString(const char *proc) {
    pf_scheme_result result;
    if (pf_scheme_call(proc, NULL, 0, &result) != 0 || !result.text) {
        return nil;
    }
    NSString *s = [[NSString alloc] initWithBytes:result.text
                                           length:result.len
                                         encoding:NSUTF8StringEncoding];
    pf_scheme_result_free(&result);
    return s;
}
