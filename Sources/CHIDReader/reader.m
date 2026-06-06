#include "CHIDReader.h"

#include <CoreFoundation/CoreFoundation.h>
#include <math.h>

static const int64_t kBMHIDEventTypeTemperature = 15;
static const int32_t kBMHIDEventTemperatureField = (15 << 16);

NSDictionary<NSString *, NSNumber *> *readAppleSiliconTemperatures(void) {
    IOHIDEventSystemClientRef client = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    if (client == NULL) {
        return @{};
    }

    NSDictionary *matching = @{
        @"PrimaryUsagePage": @(0xFF00),
        @"PrimaryUsage": @(5),
    };

    IOHIDEventSystemClientSetMatching(client, (__bridge CFDictionaryRef)matching);

    CFArrayRef copiedServices = IOHIDEventSystemClientCopyServices(client);
    if (copiedServices == NULL) {
        CFRelease(client);
        return @{};
    }

    NSArray *services = CFBridgingRelease(copiedServices);
    NSMutableDictionary<NSString *, NSNumber *> *temperatures = [NSMutableDictionary dictionary];

    for (id serviceObject in services) {
        IOHIDServiceClientRef service = (__bridge IOHIDServiceClientRef)serviceObject;
        CFTypeRef copiedProduct = IOHIDServiceClientCopyProperty(service, CFSTR("Product"));
        if (copiedProduct == NULL) {
            continue;
        }

        NSString *product = nil;
        if (CFGetTypeID(copiedProduct) == CFStringGetTypeID()) {
            product = CFBridgingRelease(copiedProduct);
        } else {
            CFRelease(copiedProduct);
            continue;
        }

        if (![product hasPrefix:@"PMU"]) {
            continue;
        }

        IOHIDEventRef event = IOHIDServiceClientCopyEvent(service, kBMHIDEventTypeTemperature, 0, 0);
        if (event == NULL) {
            continue;
        }

        double celsius = IOHIDEventGetFloatValue(event, kBMHIDEventTemperatureField);
        CFRelease(event);

        if (isfinite(celsius)) {
            temperatures[product] = @(celsius);
        }
    }

    CFRelease(client);
    return temperatures;
}
