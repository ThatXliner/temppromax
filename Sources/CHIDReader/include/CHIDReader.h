#ifndef CHIDReader_h
#define CHIDReader_h

#include <Foundation/Foundation.h>
#include <IOKit/hidsystem/IOHIDEventSystemClient.h>
#include <IOKit/hidsystem/IOHIDServiceClient.h>

typedef struct __IOHIDEvent *IOHIDEventRef;
typedef double IOHIDFloat;

IOHIDEventSystemClientRef _Nullable IOHIDEventSystemClientCreate(CFAllocatorRef _Nullable allocator);
int IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef _Nonnull client, CFDictionaryRef _Nonnull match);
IOHIDEventRef _Nullable IOHIDServiceClientCopyEvent(IOHIDServiceClientRef _Nonnull service, int64_t type, int32_t options, int64_t timestamp);
IOHIDFloat IOHIDEventGetFloatValue(IOHIDEventRef _Nonnull event, int32_t field);

NS_ASSUME_NONNULL_BEGIN

NSDictionary<NSString *, NSNumber *> *readAppleSiliconTemperatures(void);

NS_ASSUME_NONNULL_END

#endif
