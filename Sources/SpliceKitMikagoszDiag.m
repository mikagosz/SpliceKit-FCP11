//
//  SpliceKitMikagoszDiag.m
//  mikagosz: diagnostyka mostu pod Final Cut Pro 11.2.
//
//  diag.selectorImplementors — dla podanych selektorów zwraca klasy, które je
//  implementują (metody instancji i klasy), razem z obrazem (binarką), z którego
//  klasa pochodzi. Służy do wyłapania martwych poleceń mostu: nazwa funkcji
//  istnieje w FCP, ale nie ma jej żaden obiekt, do którego most ją wysyła.
//

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <objc/runtime.h>

NSDictionary *SpliceKit_handleDiagSelectorImplementors(NSDictionary *params) {
    NSArray *requested = params[@"selectors"];
    if (![requested isKindOfClass:[NSArray class]] || requested.count == 0)
        return @{@"error": @"selectors (array of selector names) required"};
    NSInteger limit = [params[@"limit"] respondsToSelector:@selector(integerValue)]
        ? [params[@"limit"] integerValue] : 12;

    NSMutableDictionary<NSString *, NSMutableArray *> *found = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSNumber *> *totals = [NSMutableDictionary dictionary];
    NSMutableSet<NSString *> *wanted = [NSMutableSet set];
    for (id s in requested) if ([s isKindOfClass:[NSString class]]) [wanted addObject:s];

    unsigned int classCount = 0;
    Class *classes = objc_copyClassList(&classCount);
    for (unsigned int i = 0; i < classCount; i++) {
        Class cls = classes[i];
        const char *image = class_getImageName(cls);
        NSString *imageName = image ? [[NSString stringWithUTF8String:image] lastPathComponent] : @"?";
        for (int meta = 0; meta < 2; meta++) {
            Class target = meta ? object_getClass((id)cls) : cls;
            if (!target) continue;
            unsigned int methodCount = 0;
            Method *methods = class_copyMethodList(target, &methodCount);
            for (unsigned int m = 0; m < methodCount; m++) {
                NSString *name = NSStringFromSelector(method_getName(methods[m]));
                if (![wanted containsObject:name]) continue;
                totals[name] = @(totals[name].integerValue + 1);
                NSMutableArray *list = found[name] ?: (found[name] = [NSMutableArray array]);
                if ((NSInteger)list.count < limit) {
                    [list addObject:@{@"class": NSStringFromClass(cls),
                                      @"image": imageName,
                                      @"kind": meta ? @"class" : @"instance"}];
                }
            }
            free(methods);
        }
    }
    free(classes);

    NSMutableArray *missing = [NSMutableArray array];
    for (NSString *s in wanted) if (!found[s]) [missing addObject:s];
    [missing sortUsingSelector:@selector(compare:)];

    return @{@"classesScanned": @(classCount),
             @"requested": @(wanted.count),
             @"missing": missing,
             @"implementors": found,
             @"totals": totals};
}

// diag.menuActions — całe główne menu FCP: ścieżka pozycji, akcja (selektor), skrót.
// Źródło prawdziwych nazw akcji w danej wersji FCP — pozycja menu wie, co wywołuje.
static void SpliceKit_mikagoszCollectMenu(NSMenu *menu, NSString *path, NSMutableArray *out, int depth) {
    if (!menu || depth > 8) return;
    for (NSMenuItem *item in menu.itemArray) {
        if (item.isSeparatorItem) continue;
        NSString *title = item.title.length ? item.title : @"(bez tytułu)";
        NSString *itemPath = path.length ? [NSString stringWithFormat:@"%@ > %@", path, title] : title;
        if (item.action) {
            NSMutableDictionary *entry = [@{@"path": itemPath,
                                            @"action": NSStringFromSelector(item.action)} mutableCopy];
            if (item.keyEquivalent.length) {
                NSMutableString *key = [NSMutableString string];
                NSEventModifierFlags m = item.keyEquivalentModifierMask;
                if (m & NSEventModifierFlagControl) [key appendString:@"⌃"];
                if (m & NSEventModifierFlagOption) [key appendString:@"⌥"];
                if (m & NSEventModifierFlagShift) [key appendString:@"⇧"];
                if (m & NSEventModifierFlagCommand) [key appendString:@"⌘"];
                [key appendString:item.keyEquivalent];
                entry[@"key"] = key;
            }
            if (item.target) entry[@"target"] = NSStringFromClass([item.target class]);
            [out addObject:entry];
        }
        if (item.hasSubmenu) SpliceKit_mikagoszCollectMenu(item.submenu, itemPath, out, depth + 1);
    }
}

NSDictionary *SpliceKit_handleDiagMenuActions(NSDictionary *params) {
    __block NSMutableArray *items = [NSMutableArray array];
    void (^collect)(void) = ^{
        NSMenu *main = [NSApplication sharedApplication].mainMenu;
        SpliceKit_mikagoszCollectMenu(main, @"", items, 0);
    };
    if ([NSThread isMainThread]) collect(); else dispatch_sync(dispatch_get_main_queue(), collect);
    return @{@"count": @(items.count), @"items": items};
}

#pragma mark - Maska magnetyczna: punkt na osobie bez klikania

#import <objc/message.h>

typedef struct { int64_t value; int32_t timescale; uint32_t flags; int64_t epoch; } MKG_CMTime;
typedef struct { MKG_CMTime start; MKG_CMTime duration; } MKG_CMTimeRange;

extern id SpliceKit_getActiveTimelineModule(void);
extern void SpliceKit_executeOnMainThread(dispatch_block_t block);

static id MKG_selectedTimelineItem(id timeline) {
    SEL selSel = NSSelectorFromString(@"selectedItems:includeItemBeforePlayheadIfLast:");
    id r = nil;
    if ([timeline respondsToSelector:selSel])
        r = ((id (*)(id, SEL, BOOL, BOOL))objc_msgSend)(timeline, selSel, NO, YES);
    if ((![r isKindOfClass:[NSArray class]] || [(NSArray *)r count] == 0) &&
        [timeline respondsToSelector:@selector(selectedItems)])
        r = ((id (*)(id, SEL))objc_msgSend)(timeline, @selector(selectedItems));
    return ([r isKindOfClass:[NSArray class]] && [(NSArray *)r count]) ? [(NSArray *)r firstObject] : nil;
}

static MKG_CMTimeRange MKG_clippedRange(id obj) {
    MKG_CMTimeRange r = {{0, 600, 1, 0}, {0, 600, 1, 0}};
    SEL s = NSSelectorFromString(@"clippedRange");
    if (![obj respondsToSelector:s]) return r;
#if defined(__x86_64__)
    ((void (*)(MKG_CMTimeRange *, id, SEL))objc_msgSend_stret)(&r, obj, s);
#else
    r = ((MKG_CMTimeRange (*)(id, SEL))objc_msgSend)(obj, s);
#endif
    return r;
}

// mask.addControlPoint — params: x, y (punkt w kadrze), offset (s od początku klipu, domyślnie 0),
// include (YES = dołącz, NO = wyklucz; domyślnie YES), analyze (domyślnie NO).
// Działa na zaznaczonym klipie z efektem Magnetic Mask (FFSegmentationMaskEffect).
NSDictionary *SpliceKit_handleMaskAddControlPoint(NSDictionary *params) {
    if (!params[@"x"] || !params[@"y"]) return @{@"error": @"x and y required"};
    double x = [params[@"x"] doubleValue], y = [params[@"y"] doubleValue];
    double offset = params[@"offset"] ? [params[@"offset"] doubleValue] : 0;
    BOOL include = params[@"include"] ? [params[@"include"] boolValue] : YES;
    BOOL analyze = [params[@"analyze"] boolValue];

    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            id timeline = SpliceKit_getActiveTimelineModule();
            id item = timeline ? MKG_selectedTimelineItem(timeline) : nil;
            if (!item) { result = @{@"error": @"No clip selected"}; return; }
            id stack = [item respondsToSelector:NSSelectorFromString(@"videoEffects")]
                ? ((id (*)(id, SEL))objc_msgSend)(item, NSSelectorFromString(@"videoEffects")) : nil;
            id maskEffect = nil;
            for (id e in (NSArray *)[stack valueForKey:@"effects"])
                if ([e isKindOfClass:NSClassFromString(@"FFSegmentationMaskEffect")]) maskEffect = e;
            if (!maskEffect) { result = @{@"error": @"Selected clip has no Magnetic Mask"}; return; }
            id mask = [(NSArray *)[maskEffect valueForKey:@"masks"] firstObject];
            if (!mask) { result = @{@"error": @"Magnetic Mask has no mask object"}; return; }

            MKG_CMTimeRange range = MKG_clippedRange(item);
            int32_t ts = range.start.timescale > 0 ? range.start.timescale : 600;
            MKG_CMTime t = range.start;
            t.value += (int64_t)llround(offset * ts);

            id cp = ((id (*)(id, SEL, CGPoint, BOOL))objc_msgSend)(
                [NSClassFromString(@"FFSegmentationControlPoint") alloc],
                NSSelectorFromString(@"initWithPoint:influence:"), CGPointMake(x, y), include);

            NSString *desc = @"Add Magnetic Mask Point";
            SEL beginSel = NSSelectorFromString(@"actionBegin:animationHint:deferUpdates:");
            SEL endSel = NSSelectorFromString(@"actionEnd:save:error:");
            if ([stack respondsToSelector:beginSel])
                ((void (*)(id, SEL, id, id, BOOL))objc_msgSend)(stack, beginSel, desc, nil, YES);
            ((void (*)(id, SEL, id, MKG_CMTime))objc_msgSend)(
                mask, NSSelectorFromString(@"operationAddControlPoint:atTime:"), cp, t);
            if ([stack respondsToSelector:endSel])
                ((void (*)(id, SEL, id, BOOL, id))objc_msgSend)(stack, endSel, desc, YES, nil);

            int64_t frameState = 0;
            id points = ((id (*)(id, SEL, MKG_CMTime, int64_t *))objc_msgSend)(
                mask, NSSelectorFromString(@"controlPointsAtTime:frameState:"), t, &frameState);
            NSMutableArray *readBack = [NSMutableArray array];
            for (id p in ([points isKindOfClass:[NSArray class]] ? points : @[]))
                [readBack addObject:@{@"x": [p valueForKey:@"x"], @"y": [p valueForKey:@"y"],
                                      @"include": [p valueForKey:@"influence"]}];

            NSMutableDictionary *r = [@{@"status": @"ok",
                                        @"localTime": @{@"value": @(t.value), @"timescale": @(t.timescale)},
                                        @"clipStart": @{@"value": @(range.start.value), @"timescale": @(range.start.timescale)},
                                        @"pointsAtTime": readBack,
                                        @"frameState": @(frameState)} mutableCopy];
            if (analyze) {
                BOOL sent = [[NSApplication sharedApplication] sendAction:NSSelectorFromString(@"analyzeAction:") to:nil from:nil];
                r[@"analyzeSent"] = @(sent);
            }
            result = r;
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result ?: @{@"error": @"mask.addControlPoint failed"};
}
