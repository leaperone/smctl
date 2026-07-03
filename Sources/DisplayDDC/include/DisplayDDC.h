// DDC/CI control for external displays on Apple Silicon, via the private
// IOAVService I2C interface (chip 0x37, data offset 0x51).
//
// Vendored and adapted from m1ddc (https://github.com/waydabber/m1ddc),
// Copyright (c) 2021 waydabber, MIT License. Converted from Objective-C to
// plain C / CoreFoundation so SwiftPM can build it without ARC bridging.
#ifndef DISPLAY_DDC_H
#define DISPLAY_DDC_H

#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <IOKit/IOKitLib.h>

#define DDC_MAX_DISPLAYS 8
#define DDC_BUFFER_SIZE 256

// VCP feature codes (MCCS)
#define DDC_VCP_LUMINANCE 0x10
#define DDC_VCP_POWER_MODE 0xD6  // 1 = on, 4 = soft off

// IOAVServiceRef is a private CoreDisplay class.
typedef CFTypeRef IOAVServiceRef;

typedef struct {
    CGDirectDisplayID id;
    CFStringRef ioLocation;   // retained; NULL only for skipped slots
    CFStringRef uuid;         // retained
    CFStringRef productName;  // retained, may be NULL
    UInt32 serial;
    UInt32 model;
    UInt32 vendor;
} DDCDisplayInfo;

typedef struct {
    UInt8 data[DDC_BUFFER_SIZE];
    UInt8 inputAddr;
} DDCPacket;

typedef struct {
    int curValue;
    int maxValue;
} DDCValue;

// Packet construction (pure functions, unit-testable without hardware)
DDCPacket ddcCreatePacket(UInt8 attrCode);
void ddcPrepareRead(UInt8 *data);
void ddcPrepareWrite(DDCPacket *packet, UInt16 newValue);

// Fills `infos` with online displays that expose an IORegistry location
// (i.e. physically connected panels; virtual displays are skipped).
// Returns the number of entries written. CFString fields are retained.
int ddcCopyOnlineDisplayInfos(DDCDisplayInfo *infos, int maxCount);

// Returns a retained IOAVService for the display's external DCP port,
// or NULL if the display has no DDC-capable connection.
IOAVServiceRef ddcCopyDisplayAVService(const DDCDisplayInfo *info);

// VCP feature read/write. Return kIOReturnSuccess on success.
IOReturn ddcRead(IOAVServiceRef avService, UInt8 attrCode, DDCValue *outValue);
IOReturn ddcWrite(IOAVServiceRef avService, UInt8 attrCode, UInt16 value);

// Private symbols from CoreDisplay.framework
extern IOAVServiceRef IOAVServiceCreateWithService(CFAllocatorRef allocator, io_service_t service);
extern IOReturn IOAVServiceReadI2C(IOAVServiceRef service, uint32_t chipAddress, uint32_t offset, void *outputBuffer, uint32_t outputBufferSize);
extern IOReturn IOAVServiceWriteI2C(IOAVServiceRef service, uint32_t chipAddress, uint32_t dataAddress, void *inputBuffer, uint32_t inputBufferSize);
extern CFDictionaryRef CoreDisplay_DisplayCreateInfoDictionary(CGDirectDisplayID display);

#endif
