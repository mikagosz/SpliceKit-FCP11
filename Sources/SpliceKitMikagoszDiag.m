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
