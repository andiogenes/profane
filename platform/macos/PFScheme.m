#import "PFScheme.h"

#import <AppKit/AppKit.h>

#import "ProfaneView.h"

#include "pf_scheme.h"

void pf_app_quit(void) {
    /* Never terminate from inside Scheme: deinit would run under the active Scheme frame. */
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSApp terminate:nil];
    });
}

void pf_app_beep(void) {
    NSBeep();
}

/* Runs the next time slice of a command that outlived its first (see (profane command-loop)). It
 * is a main-queue block, so the event loop runs between slices and C-g can reach Scheme. The
 * view is redrawn from time to time, so a long command shows its progress. */
void pf_app_schedule_resume(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        pf_scheme_call("pf-resume", NULL, 0, NULL);
        static CFAbsoluteTime last;
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (now - last > 0.05) {
            last = now;
            for (NSWindow *w in NSApp.windows) {
                if ([w.contentView isKindOfClass:ProfaneView.class]) {
                    [(ProfaneView *)w.contentView redisplay];
                }
            }
        }
    });
}

int PFSchemeBoot(void) {
    NSString *resources = NSBundle.mainBundle.resourcePath;
    NSString *bootDir = [resources stringByAppendingPathComponent:@"boot"];
    NSString *schemeDir = [resources stringByAppendingPathComponent:@"scheme"];
    static const pf_scheme_symbol symbols[] = {
        {"pf_app_quit", (void *)pf_app_quit},
        {"pf_app_beep", (void *)pf_app_beep},
        {"pf_app_schedule_resume", (void *)pf_app_schedule_resume},
        {"pf_app_latency_report", (void *)pf_app_latency_report},
        {"pf_app_latency_reset", (void *)pf_app_latency_reset},
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
