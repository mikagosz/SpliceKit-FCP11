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
