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

// Maska magnetyczna trzyma punkty w pikselach kadru liczonych od środka, oś y w górę
// (klik Mike'a w lewym dolnym rogu 2160×3840 = (-551,54; -999,08)). Na zewnątrz mostu
// podajemy ułamki kadru od lewego górnego rogu, jak na zrzucie: (0,245; 0,76).
typedef struct { double x, y, width, height; } MKG_Rect;

static CGSize MKG_frameSize(id item) {
    SEL propsSel = NSSelectorFromString(@"videoProps");
    SEL boundsSel = NSSelectorFromString(@"pixelSpaceFrameBounds");
    id props = [item respondsToSelector:propsSel] ? ((id (*)(id, SEL))objc_msgSend)(item, propsSel) : nil;
    if (![props respondsToSelector:boundsSel]) return CGSizeZero;
    MKG_Rect r = ((MKG_Rect (*)(id, SEL))objc_msgSend)(props, boundsSel);
    return CGSizeMake(r.width, r.height);
}

static CGPoint MKG_fractionToMaskPoint(double fx, double fy, CGSize size) {
    return CGPointMake((fx - 0.5) * size.width, (0.5 - fy) * size.height);
}

static NSDictionary *MKG_describePoint(id p, CGSize size) {
    double px = [[p valueForKey:@"x"] doubleValue], py = [[p valueForKey:@"y"] doubleValue];
    NSMutableDictionary *d = [@{@"pixelX": @(px), @"pixelY": @(py),
                                @"include": [p valueForKey:@"influence"]} mutableCopy];
    if (size.width > 0 && size.height > 0) {
        d[@"x"] = @(px / size.width + 0.5);
        d[@"y"] = @(0.5 - py / size.height);
    }
    return d;
}

static double MKG_seconds(MKG_CMTime t) {
    return t.timescale > 0 ? (double)t.value / t.timescale : 0;
}

// Zaznaczony klip z maską magnetyczną: klip, stos efektów, obiekt maski. Błąd → nil + *error.
// effectName = nil → samodzielny efekt Magnetic Mask; inaczej maska magnetyczna podpięta pod
// efekt o tej nazwie (np. „Color Adjustments”, patrz mask.attach).
// „Color Adjustments#2” = drugi efekt o tej nazwie (licząc od góry stosu w inspektorze).
static id MKG_effectNamed(id stack, NSString *name) {
    NSInteger wanted = 1;
    NSRange hash = [name rangeOfString:@"#" options:NSBackwardsSearch];
    if (hash.location != NSNotFound && [[name substringFromIndex:hash.location + 1] integerValue] > 0) {
        wanted = [[name substringFromIndex:hash.location + 1] integerValue];
        name = [name substringToIndex:hash.location];
    }
    NSInteger seen = 0;
    for (id e in (NSArray *)[stack valueForKey:@"effects"]) {
        id dn = [e respondsToSelector:@selector(displayName)] ? [e valueForKey:@"displayName"] : nil;
        if ([dn isKindOfClass:[NSString class]] && [(NSString *)dn caseInsensitiveCompare:name] == NSOrderedSame && ++seen == wanted) return e;
    }
    return nil;
}

static NSArray *MKG_effectNames(id stack) {
    NSMutableArray *out = [NSMutableArray array];
    for (id e in (NSArray *)[stack valueForKey:@"effects"]) {
        id dn = [e respondsToSelector:@selector(displayName)] ? [e valueForKey:@"displayName"] : nil;
        [out addObject:[dn isKindOfClass:[NSString class]] ? dn : NSStringFromClass([e class])];
    }
    return out;
}

static id MKG_selectedMaskIn(NSString *effectName, id *outItem, id *outStack, NSString **error) {
    id timeline = SpliceKit_getActiveTimelineModule();
    id item = timeline ? MKG_selectedTimelineItem(timeline) : nil;
    if (!item) { *error = @"No clip selected"; return nil; }
    id stack = [item respondsToSelector:NSSelectorFromString(@"videoEffects")]
        ? ((id (*)(id, SEL))objc_msgSend)(item, NSSelectorFromString(@"videoEffects")) : nil;
    id effect = nil;
    if (effectName.length) {
        effect = MKG_effectNamed(stack, effectName);
        if (!effect) { *error = [NSString stringWithFormat:@"No effect '%@' on the clip. Effects: %@", effectName, [MKG_effectNames(stack) componentsJoinedByString:@", "]]; return nil; }
    } else {
        for (id e in (NSArray *)[stack valueForKey:@"effects"])
            if ([e isKindOfClass:NSClassFromString(@"FFSegmentationMaskEffect")]) effect = e;
        if (!effect) { *error = @"Selected clip has no Magnetic Mask effect (for a mask inside an effect pass effect=\"<name>\")"; return nil; }
    }
    id mask = nil;
    Class segClass = NSClassFromString(@"FFSegmentationMask");
    id masks = [effect respondsToSelector:NSSelectorFromString(@"masks")] ? [effect valueForKey:@"masks"] : nil;
    for (id m in ([masks isKindOfClass:[NSArray class]] ? masks : @[])) if ([m isKindOfClass:segClass]) mask = m;
    if (!mask) { *error = effectName.length ? [NSString stringWithFormat:@"Effect '%@' has no Magnetic Mask — mask.attach first", effectName] : @"Magnetic Mask has no mask object"; return nil; }
    if (outItem) *outItem = item;
    if (outStack) *outStack = stack;
    return mask;
}

static NSString *MKG_effectParam(NSDictionary *params) {
    return [params[@"effect"] isKindOfClass:[NSString class]] && [params[@"effect"] length] ? params[@"effect"] : nil;
}

static MKG_CMTimeRange MKG_recordRange(id record) {
    MKG_CMTimeRange r = {{0, 600, 0, 0}, {0, 600, 0, 0}};
    SEL s = NSSelectorFromString(@"timeRange");
    if ([record respondsToSelector:s]) r = ((MKG_CMTimeRange (*)(id, SEL))objc_msgSend)(record, s);
    return r;
}

static BOOL MKG_isControlRecord(id record) {
    SEL s = NSSelectorFromString(@"isControlPointsRecord");
    return [record respondsToSelector:s] && ((BOOL (*)(id, SEL))objc_msgSend)(record, s);
}

// mask.listControlPoints — rekordy z punktami na zaznaczonym klipie (tylko odczyt).
NSDictionary *SpliceKit_handleMaskListControlPoints(NSDictionary *params) {
    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            id item = nil; NSString *err = nil;
            id mask = MKG_selectedMaskIn(MKG_effectParam(params), &item, NULL, &err);
            if (!mask) { result = @{@"error": err}; return; }
            CGSize size = MKG_frameSize(item);
            double clipStart = MKG_seconds(MKG_clippedRange(item).start);
            NSMutableArray *records = [NSMutableArray array];
            NSUInteger analysisRecords = 0;
            for (id rec in (NSArray *)[mask valueForKey:@"allAnalysisRecords"]) {
                if (!MKG_isControlRecord(rec)) { analysisRecords++; continue; }
                NSMutableArray *pts = [NSMutableArray array];
                for (id p in (NSArray *)[rec valueForKey:@"controlPoints"]) [pts addObject:MKG_describePoint(p, size)];
                [records addObject:@{@"offset": @(MKG_seconds(MKG_recordRange(rec).start) - clipStart),
                                     @"points": pts}];
            }
            result = @{@"status": @"ok", @"frame": @{@"width": @(size.width), @"height": @(size.height)},
                       @"controlRecords": records, @"propagationRecords": @(analysisRecords)};
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result ?: @{@"error": @"mask.listControlPoints failed"};
}

// mask.removeControlPoint — params: offset (s od początku klipu, jak w listControlPoints),
// index (pozycja w rekordzie). Zapis jak w -[FFSegmentationMask operationAddControlPoint:atTime:]:
// zmiana w rekordzie + dane kanału analyzedRangesChannel w beginChannelChanges/endChannelChanges
// (jeden krok cofania). Ostatniego punktu rekordu nie zdejmuje — to robi usunięcie efektu.
NSDictionary *SpliceKit_handleMaskRemoveControlPoint(NSDictionary *params) {
    if (!params[@"index"]) return @{@"error": @"index required (see mask.listControlPoints)"};
    NSInteger index = [params[@"index"] integerValue];
    double offset = params[@"offset"] ? [params[@"offset"] doubleValue] : 0;

    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            id item = nil; NSString *err = nil;
            id mask = MKG_selectedMaskIn(MKG_effectParam(params), &item, NULL, &err);
            if (!mask) { result = @{@"error": err}; return; }
            CGSize size = MKG_frameSize(item);
            double clipStart = MKG_seconds(MKG_clippedRange(item).start);

            id records = [mask valueForKey:@"allAnalysisRecords"];
            id record = nil;
            for (id rec in (NSArray *)records) {
                if (!MKG_isControlRecord(rec)) continue;
                double recOffset = MKG_seconds(MKG_recordRange(rec).start) - clipStart;
                if (fabs(recOffset - offset) < 0.5 / 60.0) record = rec;  // ostatni w historii wygrywa
            }
            if (!record) { result = @{@"error": [NSString stringWithFormat:@"No control points at offset %.3f s", offset]}; return; }
            NSMutableArray *points = [record valueForKey:@"controlPoints"];
            if (![points isKindOfClass:[NSMutableArray class]]) { result = @{@"error": @"Control points are not mutable"}; return; }
            if (index < 0 || index >= (NSInteger)points.count) {
                result = @{@"error": [NSString stringWithFormat:@"index %ld out of range (0–%lu)", (long)index, (unsigned long)points.count - 1]};
                return;
            }
            if (points.count == 1) { result = @{@"error": @"Refusing to remove the only point of the record"}; return; }

            id removed = points[index];
            NSDictionary *removedInfo = MKG_describePoint(removed, size);
            id anchored = [[[mask valueForKey:@"parentEffect"] valueForKey:@"effectStack"] valueForKey:@"anchoredObject"];
            id channel = [mask valueForKey:@"analyzedRangesChannel"];
            id ccc = [NSClassFromString(@"FFChannelChangeController") new];
            if (!anchored || !channel || !ccc) { result = @{@"error": @"Mask channel not reachable"}; return; }

            NSString *desc = @"Remove Magnetic Mask Point";
            MKG_CMTime zero = {0, 1, 1, 0};  // kCMTimeZero
            ((void (*)(id, SEL, id, id))objc_msgSend)(ccc, NSSelectorFromString(@"beginChannelChanges:forObject:"), desc, anchored);
            [points removeObjectAtIndex:index];
            ((void (*)(id, SEL, id, BOOL))objc_msgSend)(ccc, NSSelectorFromString(@"willSetChannel:flagsOnly:"), channel, NO);
            ((void (*)(id, SEL, id, MKG_CMTime))objc_msgSend)(channel, NSSelectorFromString(@"setPluginData:atTime:"), records, zero);
            ((void (*)(id, SEL, id, BOOL))objc_msgSend)(ccc, NSSelectorFromString(@"didSetChannel:flagsOnly:"), channel, NO);
            ((void (*)(id, SEL, id, id))objc_msgSend)(ccc, NSSelectorFromString(@"endChannelChanges:forObject:"), desc, anchored);

            NSMutableArray *left = [NSMutableArray array];
            for (id p in points) [left addObject:MKG_describePoint(p, size)];
            result = @{@"status": @"ok", @"removed": removedInfo, @"pointsLeft": left,
                       @"note": @"Existing analysis still reflects the old points — run mask.analyze"};
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result ?: @{@"error": @"mask.removeControlPoint failed"};
}

// Główny podgląd: moduły PEPlayerContainerModule w NSApp.delegate.upperDeckContainer, każdy ma
// playerVideoModule (widok to FFPlayerItemView, nie FFPlayerView). Bierzemy widoczny.
static NSArray *MKG_playerVideoModules(void) {
    NSMutableArray *out = [NSMutableArray array];
    id app = [NSApp delegate];
    id deck = [app respondsToSelector:NSSelectorFromString(@"upperDeckContainer")] ? [app valueForKey:@"upperDeckContainer"] : nil;
    id subs = [deck respondsToSelector:NSSelectorFromString(@"submodules")] ? [deck valueForKey:@"submodules"] : nil;
    // playerVideoModule bywa nil (zależy od układu okna) — wtedy viewerPlayerModule →
    // visiblePlayerItemModule / videoModule (2026-09-28: po restarcie tylko ta droga).
    Class pvmClass = NSClassFromString(@"FFPlayerVideoModule");
    for (id m in ([subs isKindOfClass:[NSArray class]] ? subs : @[])) {
        NSMutableArray *cands = [NSMutableArray array];
        if ([m respondsToSelector:NSSelectorFromString(@"playerVideoModule")]) {
            id pvm = [m valueForKey:@"playerVideoModule"]; if (pvm) [cands addObject:pvm];
        }
        id viewer = [m respondsToSelector:NSSelectorFromString(@"viewerPlayerModule")] ? [m valueForKey:@"viewerPlayerModule"] : nil;
        for (NSString *key in @[@"visiblePlayerItemModule", @"videoModule"]) {
            id pvm = [viewer respondsToSelector:NSSelectorFromString(key)] ? [viewer valueForKey:key] : nil;
            if (pvm) [cands addObject:pvm];
        }
        for (id pvm in cands) {
            if (![pvm isKindOfClass:pvmClass] || [out containsObject:pvm]) continue;
            [out addObject:pvm];
        }
    }
    // Analiza czyta playerVideoModule.playerModule.player — bez odtwarzacza wraca od razu bez
    // niczego (2026-09-28: widoczny podgląd bywa bez odtwarzacza). Najpierw z odtwarzaczem, potem widoczne.
    [out sortUsingComparator:^NSComparisonResult(id a, id b) {
        NSInteger (^score)(id) = ^NSInteger(id pvm) {
            id player = [[pvm valueForKey:@"playerModule"] valueForKey:@"player"];
            NSView *view = [pvm respondsToSelector:@selector(view)] ? [pvm valueForKey:@"view"] : nil;
            return (player ? 2 : 0) + ((view.window.isVisible && !view.isHiddenOrHasHiddenAncestor) ? 1 : 0);
        };
        return [@(score(b)) compare:@(score(a))];
    }];
    return out;
}

static id MKG_oscIn(id pvm, id mask) {
    Class oscClass = NSClassFromString(@"FFSegmentationMaskOSC");
    id oscs = [pvm respondsToSelector:NSSelectorFromString(@"copyOSCs")]
        ? ((id (*)(id, SEL))objc_msgSend)(pvm, NSSelectorFromString(@"copyOSCs")) : nil;
    for (id osc in ([oscs isKindOfClass:[NSArray class]] ? oscs : @[]))
        if ([osc isKindOfClass:oscClass] && [osc valueForKey:@"mask"] == mask) return osc;
    return nil;
}

// Kontrolki maski w podglądzie. FCP instaluje je dopiero, gdy maska jest wybrana w inspektorze;
// install=YES robi to samo co FCP: [mask onscreenControlsForEffectStack:] → _addOSC:playerUpdate:.
static id MKG_findMaskOSC(id mask, id stack, BOOL install) {
    NSArray *modules = MKG_playerVideoModules();
    for (id pvm in modules) { id osc = MKG_oscIn(pvm, mask); if (osc) return osc; }
    if (!install || !stack || modules.count == 0) return nil;
    id created = ((id (*)(id, SEL, id))objc_msgSend)(mask, NSSelectorFromString(@"onscreenControlsForEffectStack:"), stack);
    id osc = [created isKindOfClass:[NSArray class]] ? [(NSArray *)created firstObject] : nil;
    if (!osc) return nil;
    ((void (*)(id, SEL, id, BOOL))objc_msgSend)(modules[0], NSSelectorFromString(@"_addOSC:playerUpdate:"), osc, YES);
    return MKG_oscIn(modules[0], mask);
}

// Analiza jak przycisk Analyze: -[FFSegmentationMaskOSC analyzeAction:] czyta z nadawcy
// selectedSegment (0 / 4 = krok o klatkę, inaczej pełna analiza) i selectedTag = AnalysisDirection
// dla -[FFTrackerManager runSegmentationAnalysis:] (2 = obie strony, domyślne w FCP; 1 = wstecz, 0 = w przód). Przycisk
// z panelu kontrolek bywa nil, więc podajemy własny. Analiza trwa w oknie modalnym FCP — wywołanie
// wraca po jej końcu. Na głównym wątku.
static NSDictionary *MKG_analyze(id mask, id stack, NSString *direction) {
    // Tagi sprawdzone 2026-09-28 po rekordach (forward:0/1): 2 = obie strony, 1 = wstecz, 0 = w przód.
    NSDictionary *modes = @{@"both": @[@2, @2], @"forward": @[@3, @0], @"backward": @[@1, @1],
                            @"stepBackward": @[@0, @0], @"stepForward": @[@4, @0]};
    NSArray *mode = modes[direction ?: @"both"];
    if (!mode) return @{@"error": @"direction: both | forward | backward | stepForward | stepBackward"};
    id osc = MKG_findMaskOSC(mask, stack, YES);
    if (!osc) return @{@"error": @"Could not put the Magnetic Mask controls into the viewer"};
    if ([[osc valueForKey:@"analysisRunning"] boolValue]) return @{@"error": @"Analysis already running"};

    NSUInteger before = [(NSArray *)[mask valueForKey:@"allAnalysisRecords"] count];
    NSSegmentedControl *sender = [NSSegmentedControl new];
    sender.segmentCount = 5;
    [sender.cell setTag:[mode[1] integerValue] forSegment:[mode[0] integerValue]];
    sender.selectedSegment = [mode[0] integerValue];
    NSDate *start = [NSDate date];
    ((void (*)(id, SEL, id))objc_msgSend)(osc, NSSelectorFromString(@"analyzeAction:"), sender);
    NSUInteger after = [(NSArray *)[mask valueForKey:@"allAnalysisRecords"] count];
    return @{@"status": after > before ? @"ok" : @"no new analysis",
             @"direction": direction ?: @"both",
             @"newRecords": @((NSInteger)after - (NSInteger)before),
             @"seconds": @(round(-[start timeIntervalSinceNow] * 10) / 10)};
}

// mask.analyze — params: direction (both | forward | backward | stepForward | stepBackward).
// Analiza biegnie w tle; postęp: mask.status.
NSDictionary *SpliceKit_handleMaskAnalyze(NSDictionary *params) {
    NSString *direction = [params[@"direction"] isKindOfClass:[NSString class]] ? params[@"direction"] : @"both";
    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            NSString *err = nil; id stack = nil;
            id mask = MKG_selectedMaskIn(MKG_effectParam(params), NULL, &stack, &err);
            result = mask ? MKG_analyze(mask, stack, direction) : @{@"error": err};
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result ?: @{@"error": @"mask.analyze failed"};
}

// mask.status — czy analiza biegnie, ile rekordów i jaki zakres klipu pokrywają.
NSDictionary *SpliceKit_handleMaskStatus(NSDictionary *params) {
    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            id item = nil; NSString *err = nil;
            id mask = MKG_selectedMaskIn(MKG_effectParam(params), &item, NULL, &err);
            if (!mask) { result = @{@"error": err}; return; }
            double clipStart = MKG_seconds(MKG_clippedRange(item).start);
            NSMutableArray *ranges = [NSMutableArray array];
            for (id rec in (NSArray *)[mask valueForKey:@"allAnalysisRecords"]) {
                if (MKG_isControlRecord(rec)) continue;
                MKG_CMTimeRange r = MKG_recordRange(rec);
                [ranges addObject:@{@"start": @(MKG_seconds(r.start) - clipStart), @"duration": @(MKG_seconds(r.duration))}];
            }
            id osc = MKG_findMaskOSC(mask, nil, NO);
            result = @{@"status": @"ok",
                       @"controlsInViewer": @(osc != nil),
                       @"analysisRunning": osc ? [osc valueForKey:@"analysisRunning"] : @NO,
                       @"analyzedRanges": ranges};
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result ?: @{@"error": @"mask.status failed"};
}

// mask.addControlPoint — params: x, y (ułamek kadru 0–1 od lewego górnego rogu; pixels=true →
// surowe piksele maski od środka, oś y w górę), offset (s od początku klipu, domyślnie 0),
// include (YES = dołącz, NO = wyklucz; domyślnie YES), analyze (domyślnie NO).
// Działa na zaznaczonym klipie z efektem Magnetic Mask (FFSegmentationMaskEffect).
NSDictionary *SpliceKit_handleMaskAddControlPoint(NSDictionary *params) {
    if (!params[@"x"] || !params[@"y"]) return @{@"error": @"x and y required"};
    double x = [params[@"x"] doubleValue], y = [params[@"y"] doubleValue];
    BOOL pixels = [params[@"pixels"] boolValue];
    if (!pixels && (x < 0 || x > 1 || y < 0 || y > 1))
        return @{@"error": @"x and y are fractions of the frame (0–1 from the top-left corner); pass pixels=true for raw mask pixels"};
    double offset = params[@"offset"] ? [params[@"offset"] doubleValue] : 0;
    BOOL include = params[@"include"] ? [params[@"include"] boolValue] : YES;
    BOOL analyze = [params[@"analyze"] boolValue];

    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            id item = nil, stack = nil; NSString *err = nil;
            id mask = MKG_selectedMaskIn(MKG_effectParam(params), &item, &stack, &err);
            if (!mask) { result = @{@"error": err}; return; }
            CGSize size = MKG_frameSize(item);
            if (!pixels && (size.width <= 0 || size.height <= 0)) { result = @{@"error": @"Frame size of the clip unknown — pass pixels=true"}; return; }
            CGPoint maskPoint = pixels ? CGPointMake(x, y) : MKG_fractionToMaskPoint(x, y, size);

            MKG_CMTimeRange range = MKG_clippedRange(item);
            int32_t ts = range.start.timescale > 0 ? range.start.timescale : 600;
            MKG_CMTime t = range.start;
            t.value += (int64_t)llround(offset * ts);

            id cp = ((id (*)(id, SEL, CGPoint, BOOL))objc_msgSend)(
                [NSClassFromString(@"FFSegmentationControlPoint") alloc],
                NSSelectorFromString(@"initWithPoint:influence:"), maskPoint, include);

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
                [readBack addObject:MKG_describePoint(p, size)];

            NSMutableDictionary *r = [@{@"status": @"ok",
                                        @"maskPoint": @{@"pixelX": @(maskPoint.x), @"pixelY": @(maskPoint.y)},
                                        @"offset": @(offset),
                                        @"pointsAtTime": readBack,
                                        @"frameState": @(frameState)} mutableCopy];
            if (analyze) r[@"analyze"] = MKG_analyze(mask, stack, @"both");
            result = r;
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result ?: @{@"error": @"mask.addControlPoint failed"};
}

// mask.attach — params: effect (nazwa efektu na zaznaczonym klipie, np. „Color Adjustments”).
// Jak przycisk maski w nagłówku efektu koloru (-[FFInspectorModuleColorHeaderController
// _addSegmentationMaskWithHandler:]): FFProjectDocument actionAddMaskOfClass:FFSegmentationMask
// toEffect:… — efekt działa potem tylko w obrębie osoby. Nowa maska jest pusta: punkty
// (mask.addControlPoint z effect=…) i analiza (mask.analyze z effect=…).
NSDictionary *SpliceKit_handleMaskAttach(NSDictionary *params) {
    NSString *effectName = MKG_effectParam(params);
    if (!effectName) return @{@"error": @"effect (name of an effect on the selected clip) required"};
    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            id timeline = SpliceKit_getActiveTimelineModule();
            id item = timeline ? MKG_selectedTimelineItem(timeline) : nil;
            if (!item) { result = @{@"error": @"No clip selected"}; return; }
            id stack = [item valueForKey:@"videoEffects"];
            id effect = MKG_effectNamed(stack, effectName);
            if (!effect) { result = @{@"error": [NSString stringWithFormat:@"No effect '%@' on the clip. Effects: %@", effectName, [MKG_effectNames(stack) componentsJoinedByString:@", "]]}; return; }
            Class segClass = NSClassFromString(@"FFSegmentationMask");
            NSUInteger before = 0;
            for (id m in (NSArray *)[effect valueForKey:@"masks"]) if ([m isKindOfClass:segClass]) before++;
            if (before) { result = @{@"error": [NSString stringWithFormat:@"'%@' already has a Magnetic Mask", effectName]}; return; }

            id effectStack = [effect valueForKey:@"effectStack"];
            id project = [effectStack valueForKey:@"project"];
            id doc = ((id (*)(id, SEL, id))objc_msgSend)((id)NSClassFromString(@"FFProjectDocument"),
                                                        NSSelectorFromString(@"documentForProject:"), project);
            SEL addSel = NSSelectorFromString(@"actionAddMaskOfClass:toEffect:actionName:deselectActiveMasks:maskHandler:error:");
            if (![doc respondsToSelector:addSel]) { result = @{@"error": @"Project document not reachable"}; return; }
            void (^handler)(id, id) = ^(id owner, id newMask) {};
            NSError *error = nil;
            BOOL ok = ((BOOL (*)(id, SEL, Class, id, id, BOOL, id, NSError **))objc_msgSend)(
                doc, addSel, segClass, effect, @"Add Magnetic Mask", YES, handler, &error);
            NSUInteger after = 0;
            for (id m in (NSArray *)[effect valueForKey:@"masks"]) if ([m isKindOfClass:segClass]) after++;
            result = (ok && after == before + 1)
                ? @{@"status": @"ok", @"effect": effectName, @"note": @"Mask is empty — add points with effect=, then mask.analyze with effect="}
                : @{@"error": error.localizedDescription ?: @"Mask was not added", @"masksBefore": @(before), @"masksAfter": @(after)};
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result ?: @{@"error": @"mask.attach failed"};
}

#pragma mark - Przeglądarka: zaznaczanie po nazwie

// Zaznaczenie w przeglądarce to tablica FigTimeRangeAndObject (zakres + obiekt z ownedClips
// wydarzenia: FFAnchoredSequence projektu albo klipu). Bez tego nie działają polecenia menu,
// które biorą zaznaczenie przeglądarki (moveToTrash:, mergeEvents:, transcodeMedia:, oceny…).
static NSString *MKG_name(id obj) {
    id n = [obj respondsToSelector:@selector(displayName)] ? [obj valueForKey:@"displayName"] : nil;
    return [n isKindOfClass:[NSString class]] ? n : nil;
}

static BOOL MKG_inTrash(id obj) {
    SEL s = NSSelectorFromString(@"isInTrash");
    return [obj respondsToSelector:s] && ((BOOL (*)(id, SEL))objc_msgSend)(obj, s);
}

static NSArray *MKG_allEvents(void) {
    NSMutableArray *out = [NSMutableArray array];
    id libs = ((id (*)(id, SEL))objc_msgSend)((id)NSClassFromString(@"FFLibraryDocument"),
                                              NSSelectorFromString(@"copyActiveLibraries"));
    for (id library in ([libs isKindOfClass:[NSArray class]] ? libs : @[])) {
        if (![library respondsToSelector:NSSelectorFromString(@"events")]) continue;
        for (id ev in (id<NSFastEnumeration>)[library valueForKey:@"events"]) [out addObject:ev];
    }
    return out;
}

// Jak browser.listClips: displayOwnedClips (to, co widać w przeglądarce), inaczej ownedClips.
static NSArray *MKG_eventClips(id event) {
    for (NSString *key in @[@"displayOwnedClips", @"ownedClips"]) {
        if (![event respondsToSelector:NSSelectorFromString(key)]) continue;
        id clips = [event valueForKey:key];
        if ([clips isKindOfClass:[NSArray class]]) return clips;
        if ([clips respondsToSelector:@selector(allObjects)]) return [clips allObjects];
    }
    return @[];
}

static id MKG_rangeAndObject(id obj) {
    MKG_CMTimeRange range = {{0, 600, 1, 0}, {0, 600, 1, 0}};
    if ([obj respondsToSelector:NSSelectorFromString(@"clippedRange")]) {
        range = MKG_clippedRange(obj);
    } else if ([obj respondsToSelector:NSSelectorFromString(@"duration")]) {
        range.duration = ((MKG_CMTime (*)(id, SEL))objc_msgSend)(obj, NSSelectorFromString(@"duration"));
        range.start.timescale = range.duration.timescale;
    }
    return ((id (*)(id, SEL, MKG_CMTimeRange, id))objc_msgSend)(
        (id)NSClassFromString(@"FigTimeRangeAndObject"),
        NSSelectorFromString(@"rangeAndObjectWithRange:andObject:"), range, obj);
}

static NSArray *MKG_selectionNames(id organizer) {
    NSMutableArray *names = [NSMutableArray array];
    for (id item in (NSArray *)[organizer valueForKey:@"selectedItems"]) {
        id obj = [item respondsToSelector:NSSelectorFromString(@"object")] ? [item valueForKey:@"object"] : item;
        [names addObject:MKG_name(obj) ?: NSStringFromClass([obj class])];
    }
    return names;
}

// browser.select — params: names (tablica nazw klipów/projektów) albo name, event (nazwa
// wydarzenia; domyślnie wydarzenie wybrane w pasku bocznym). names = [] czyści zaznaczenie.
NSDictionary *SpliceKit_handleBrowserSelect(NSDictionary *params) {
    NSArray *names = [params[@"names"] isKindOfClass:[NSArray class]] ? params[@"names"]
        : ([params[@"name"] isKindOfClass:[NSString class]] ? @[params[@"name"]] : nil);
    if (!names) return @{@"error": @"names (array) or name required"};
    NSString *eventName = [params[@"event"] isKindOfClass:[NSString class]] ? params[@"event"] : nil;

    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            id delegate = [NSApp delegate];
            id container = [delegate respondsToSelector:NSSelectorFromString(@"mediaEventOrganizerContainer")]
                ? [delegate valueForKey:@"mediaEventOrganizerContainer"] : nil;
            id organizer = [container valueForKey:@"activeOrganizerModule"];
            id sidebar = [container valueForKey:@"mediaSidebarModule"];
            if (!organizer || !sidebar) { result = @{@"error": @"Browser not available (is the library sidebar hidden?)"}; return; }

            NSArray *events = nil;
            if (eventName) {
                NSMutableArray *matches = [NSMutableArray array];
                for (id ev in MKG_allEvents())
                    if ([MKG_name(ev) isEqualToString:eventName] && !MKG_inTrash(ev)) [matches addObject:ev];
                if (matches.count == 0) { result = @{@"error": [NSString stringWithFormat:@"Event '%@' not found", eventName]}; return; }
                if (matches.count > 1) { result = @{@"error": [NSString stringWithFormat:@"Event name '%@' is ambiguous (%lu libraries)", eventName, (unsigned long)matches.count]}; return; }
                // Pasek boczny pokazuje FFMediaEventProject (project rekordu wydarzenia); przełącza go
                // selectDataItem:extendSelection: — setSelectedItems: z rekordem czyści pasek (2026-09-28).
                id sidebarItem = [matches[0] respondsToSelector:NSSelectorFromString(@"project")] ? [matches[0] valueForKey:@"project"] : matches[0];
                NSArray *current = [organizer valueForKey:@"sidebarSelectedItems"];
                if (!([current count] == 1 && [current firstObject] == sidebarItem)) {
                    ((void (*)(id, SEL, id, BOOL))objc_msgSend)(sidebar, NSSelectorFromString(@"selectDataItem:extendSelection:"), sidebarItem, NO);
                    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.3]];
                    NSArray *now = [organizer valueForKey:@"sidebarSelectedItems"];
                    if (!([now count] == 1 && [now firstObject] == sidebarItem)) {
                        result = @{@"error": [NSString stringWithFormat:@"Could not show event '%@' in the sidebar", eventName]};
                        return;
                    }
                }
                events = matches;
            } else {
                events = [organizer valueForKey:@"sidebarSelectedItems"];
            }

            NSMutableArray *items = [NSMutableArray array];
            NSMutableArray *missing = [NSMutableArray array];
            NSMutableArray *ambiguous = [NSMutableArray array];
            for (NSString *wanted in names) {
                NSMutableArray *hits = [NSMutableArray array];
                for (id ev in events)
                    for (id obj in MKG_eventClips(ev))
                        if ([MKG_name(obj) isEqualToString:wanted] && !MKG_inTrash(obj)) [hits addObject:obj];
                if (hits.count == 0) [missing addObject:wanted];
                else if (hits.count > 1) [ambiguous addObject:wanted];
                else { id ro = MKG_rangeAndObject(hits[0]); if (ro) [items addObject:ro]; }
            }
            if (missing.count || ambiguous.count) {
                NSMutableString *msg = [NSMutableString stringWithString:@"Nothing selected."];
                if (missing.count) [msg appendFormat:@" Not found: %@.", [missing componentsJoinedByString:@", "]];
                if (ambiguous.count) [msg appendFormat:@" Ambiguous: %@.", [ambiguous componentsJoinedByString:@", "]];
                NSMutableArray *evNames = [NSMutableArray array];
                for (id ev in events) [evNames addObject:MKG_name(ev) ?: @"?"];
                [msg appendFormat:@" Searched events: %@", [evNames componentsJoinedByString:@", "]];
                result = @{@"error": msg};
                return;
            }

            // Zaznaczenie przeglądarki trzyma moduł filmstripu (FFOrganizerFilmstripModule);
            // setSelectedItems: na FFEventLibraryModule niczego nie zmienia (2026-09-28).
            id filmstrip = [[organizer valueForKey:@"mediaDetailContainerModule"] valueForKey:@"filmstripModule"];
            if (!filmstrip) { result = @{@"error": @"Browser filmstrip not available"}; return; }
            if (items.count == 0) {
                ((void (*)(id, SEL, id))objc_msgSend)(filmstrip, NSSelectorFromString(@"deselectAll:"), nil);
            } else {
                SEL rangesSel = NSSelectorFromString(@"_selectMediaRanges:");
                SEL setSel = NSSelectorFromString(@"setSelectedItems:");
                ((void (*)(id, SEL, id))objc_msgSend)(filmstrip, [filmstrip respondsToSelector:rangesSel] ? rangesSel : setSel, items);
            }
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.15]];
            NSArray *now = MKG_selectionNames(filmstrip);
            BOOL ok = [[NSSet setWithArray:now] isEqualToSet:[NSSet setWithArray:names]];
            result = ok ? @{@"status": @"ok", @"selected": now}
                        : @{@"error": [NSString stringWithFormat:@"Browser selection did not take — requested %@, selected %@",
                                       [names componentsJoinedByString:@", "], [now componentsJoinedByString:@", "]]};
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result ?: @{@"error": @"browser.select failed"};
}

// browser.getSelection — co jest zaznaczone w przeglądarce i w pasku bocznym (tylko odczyt).
NSDictionary *SpliceKit_handleBrowserGetSelection(NSDictionary *params) {
    __block NSDictionary *result = nil;
    SpliceKit_executeOnMainThread(^{
        @try {
            id container = [(id)[NSApp delegate] valueForKey:@"mediaEventOrganizerContainer"];
            id organizer = [container valueForKey:@"activeOrganizerModule"];
            if (!organizer) { result = @{@"error": @"Browser not available"}; return; }
            NSMutableArray *events = [NSMutableArray array];
            for (id ev in (NSArray *)[organizer valueForKey:@"sidebarSelectedItems"])
                [events addObject:MKG_name(ev) ?: NSStringFromClass([ev class])];
            result = @{@"status": @"ok", @"selected": MKG_selectionNames(organizer), @"events": events};
        } @catch (NSException *e) {
            result = @{@"error": [NSString stringWithFormat:@"Exception: %@", e.reason]};
        }
    });
    return result ?: @{@"error": @"browser.getSelection failed"};
}
