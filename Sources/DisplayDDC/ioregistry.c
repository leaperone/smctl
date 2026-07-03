// Vendored and adapted from m1ddc sources/ioregistry.m
// (https://github.com/waydabber/m1ddc), Copyright (c) 2021 waydabber, MIT.
#include "DisplayDDC.h"

#include <string.h>

static CFTypeRef copySearchedProperty(io_service_t service, CFStringRef key) {
    return IORegistryEntrySearchCFProperty(service, kIOServicePlane, key, kCFAllocatorDefault, kIORegistryIterateRecursively);
}

int ddcCopyOnlineDisplayInfos(DDCDisplayInfo *infos, int maxCount) {
    CGDisplayCount screenCount = 0;
    CGDirectDisplayID screenList[DDC_MAX_DISPLAYS];
    CGGetOnlineDisplayList(DDC_MAX_DISPLAYS, screenList, &screenCount);

    int valid = 0;
    for (int i = 0; i < (int)screenCount && valid < maxCount; i++) {
        DDCDisplayInfo *display = &infos[valid];
        memset(display, 0, sizeof(*display));
        display->id = screenList[i];

        // Private API shortcut to the system UUID and IORegistry location.
        CFDictionaryRef infoDict = CoreDisplay_DisplayCreateInfoDictionary(display->id);
        if (infoDict == NULL) {
            continue;
        }

        CFStringRef uuid = CFDictionaryGetValue(infoDict, CFSTR("kCGDisplayUUID"));
        CFStringRef ioLocation = CFDictionaryGetValue(infoDict, CFSTR("IODisplayLocation"));
        // Virtual displays (Sidecar/AirPlay) lack these properties.
        if (uuid == NULL || ioLocation == NULL) {
            CFRelease(infoDict);
            continue;
        }

        display->serial = CGDisplaySerialNumber(display->id);
        display->model = CGDisplayModelNumber(display->id);
        display->vendor = CGDisplayVendorNumber(display->id);
        display->uuid = CFRetain(uuid);
        display->ioLocation = CFRetain(ioLocation);

        io_registry_entry_t adapter = IORegistryEntryCopyFromPath(kIOMainPortDefault, ioLocation);
        if (adapter != MACH_PORT_NULL) {
            CFTypeRef attrs = copySearchedProperty(adapter, CFSTR("DisplayAttributes"));
            if (attrs != NULL && CFGetTypeID(attrs) == CFDictionaryGetTypeID()) {
                CFTypeRef product = CFDictionaryGetValue((CFDictionaryRef)attrs, CFSTR("ProductAttributes"));
                if (product != NULL && CFGetTypeID(product) == CFDictionaryGetTypeID()) {
                    CFTypeRef name = CFDictionaryGetValue((CFDictionaryRef)product, CFSTR("ProductName"));
                    if (name != NULL && CFGetTypeID(name) == CFStringGetTypeID()) {
                        display->productName = CFRetain(name);
                    }
                }
            }
            if (attrs != NULL) {
                CFRelease(attrs);
            }
            IOObjectRelease(adapter);
        }

        CFRelease(infoDict);
        valid++;
    }
    return valid;
}

IOAVServiceRef ddcCopyDisplayAVService(const DDCDisplayInfo *info) {
    if (info->ioLocation == NULL) {
        return NULL;
    }

    char targetPath[1024];
    if (!CFStringGetCString(info->ioLocation, targetPath, sizeof(targetPath), kCFStringEncodingASCII)) {
        return NULL;
    }

    io_registry_entry_t root = IORegistryGetRootEntry(kIOMainPortDefault);
    io_iterator_t iter;
    if (IORegistryEntryCreateIterator(root, kIOServicePlane, kIORegistryIterateRecursively, &iter) != KERN_SUCCESS) {
        return NULL;
    }

    IOAVServiceRef avService = NULL;
    io_service_t service;
    // Find the display's adapter entry, then the first *external* DCPAVServiceProxy below it.
    while (avService == NULL && (service = IOIteratorNext(iter)) != MACH_PORT_NULL) {
        io_string_t servicePath;
        IORegistryEntryGetPath(service, kIOServicePlane, servicePath);
        if (strcmp(servicePath, targetPath) != 0) {
            IOObjectRelease(service);
            continue;
        }
        IOObjectRelease(service);

        while ((service = IOIteratorNext(iter)) != MACH_PORT_NULL) {
            io_name_t name;
            IORegistryEntryGetName(service, name);
            if (strcmp(name, "DCPAVServiceProxy") == 0) {
                IOAVServiceRef candidate = IOAVServiceCreateWithService(kCFAllocatorDefault, service);
                CFTypeRef location = copySearchedProperty(service, CFSTR("Location"));
                bool external = location != NULL
                    && CFGetTypeID(location) == CFStringGetTypeID()
                    && CFStringCompare((CFStringRef)location, CFSTR("External"), 0) == kCFCompareEqualTo;
                if (location != NULL) {
                    CFRelease(location);
                }
                if (candidate != NULL && external) {
                    avService = candidate;
                    IOObjectRelease(service);
                    break;
                }
                if (candidate != NULL) {
                    CFRelease(candidate);
                }
            }
            IOObjectRelease(service);
        }
        break;
    }
    IOObjectRelease(iter);
    return avService;
}
