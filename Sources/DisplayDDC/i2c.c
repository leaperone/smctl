// Vendored and adapted from m1ddc sources/i2c.m
// (https://github.com/waydabber/m1ddc), Copyright (c) 2021 waydabber, MIT.
#include "DisplayDDC.h"

#include <string.h>
#include <unistd.h>

#define DDC_DEFAULT_INPUT_ADDRESS 0x51
#define DDC_ALTERNATE_INPUT_ADDRESS 0x50
#define DDC_VCP_INPUT_ALT 0xF4
#define DDC_WAIT 10000  // usec; some displays need up to 50000
#define DDC_ITERATIONS 2

static int getBytesUsed(const UInt8 *data) {
    int bytes = 0;
    for (int i = 0; i < DDC_BUFFER_SIZE; ++i) {
        if (data[i] != 0) {
            bytes = i + 1;
        }
    }
    return bytes;
}

DDCPacket ddcCreatePacket(UInt8 attrCode) {
    DDCPacket packet = {};
    packet.data[2] = attrCode;
    packet.inputAddr = attrCode == DDC_VCP_INPUT_ALT ? DDC_ALTERNATE_INPUT_ADDRESS : DDC_DEFAULT_INPUT_ADDRESS;
    return packet;
}

void ddcPrepareRead(UInt8 *data) {
    data[0] = 0x82;
    data[1] = 0x01;
    data[3] = 0x6e ^ data[0] ^ data[1] ^ data[2] ^ data[3];
}

void ddcPrepareWrite(DDCPacket *packet, UInt16 newValue) {
    UInt8 *data = packet->data;
    data[0] = 0x84;
    data[1] = 0x03;
    data[3] = newValue >> 8;
    data[4] = newValue & 255;
    data[5] = 0x6E ^ packet->inputAddr ^ data[0] ^ data[1] ^ data[2] ^ data[3] ^ data[4];
}

static IOReturn performDDCWrite(IOAVServiceRef avService, DDCPacket *packet) {
    IOReturn ret = kIOReturnSuccess;
    for (int i = 0; i < DDC_ITERATIONS; ++i) {
        usleep(DDC_WAIT);
        if ((ret = IOAVServiceWriteI2C(avService, 0x37, packet->inputAddr, packet->data, getBytesUsed(packet->data)))) {
            return ret;
        }
    }
    return ret;
}

IOReturn ddcRead(IOAVServiceRef avService, UInt8 attrCode, DDCValue *outValue) {
    DDCPacket packet = ddcCreatePacket(attrCode);
    ddcPrepareRead(packet.data);

    IOReturn err = performDDCWrite(avService, &packet);
    if (err) {
        return err;
    }

    UInt8 reply[DDC_BUFFER_SIZE] = {0};
    usleep(DDC_WAIT);
    err = IOAVServiceReadI2C(avService, 0x37, packet.inputAddr, reply, 12);
    if (err) {
        return err;
    }

    // DDC/CI "Get VCP Feature Reply": max in bytes [6..7], current in [8..9], big-endian.
    outValue->maxValue = (reply[6] << 8) | reply[7];
    outValue->curValue = (reply[8] << 8) | reply[9];
    return kIOReturnSuccess;
}

IOReturn ddcWrite(IOAVServiceRef avService, UInt8 attrCode, UInt16 value) {
    DDCPacket packet = ddcCreatePacket(attrCode);
    ddcPrepareWrite(&packet, value);
    return performDDCWrite(avService, &packet);
}
