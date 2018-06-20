/* Pipes a PS4 controller through to MIDI
 *
 * Jeff Kaufman, June 2018
 *
 * Referenced LibSDL v2 source code in writing this, so I'm releasing this
 * under the same license (zlib) to make things easier:
 * https://www.libsdl.org/license.php
 *
 * Minimal proof of concept, but it does work.
 *
 * TODO: map controller buttons to MIDI as well.
 * TODO: allow remapping so people can choose what CC values to send.
 * TODO: allow users to choose whether joysticks send different CC values for
 *       their two directions or not.
 *
 * See README for usage.
 */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/types.h>
#include <sys/uio.h>
#include <unistd.h>

#include <CoreFoundation/CoreFoundation.h>
#include <CoreMIDI/MIDIServices.h>
#include <CoreAudio/HostTime.h>
#include <IOKit/hid/IOHIDDevice.h>
#include <IOKit/hid/IOHIDManager.h>
#import <Foundation/Foundation.h>

#define MAX_AXES 256

IOHIDManagerRef hidman = NULL;
int hid_page = kHIDPage_GenericDesktop;
int hid_usage = kHIDUsage_GD_GamePad;
MIDIClientRef midiclient;
MIDIEndpointRef midiendpoint;

struct Element {
  IOHIDElementRef handle;
  int last_value;
};

struct Device {
  IOHIDDeviceRef handle;
  int n_axes;
  struct Element axes[MAX_AXES];
};

struct Device device;

void die(char *errmsg) {
  printf("%s\n",errmsg);
  exit(-1);
}

void attempt(OSStatus result, char* errmsg) {
  if (result != noErr) die(errmsg);
}

void add_hid_element(const void* v_element, void* ignored) {
  IOHIDElementRef element_handle = (IOHIDElementRef)v_element;
  if (!element_handle) die("invalid element");
  if (IOHIDElementGetUsagePage(element_handle) != kHIDPage_GenericDesktop) return;

  IOHIDElementType element_type = IOHIDElementGetType(element_handle);
  if (element_type == kIOHIDElementTypeInput_Misc ||
      element_type == kIOHIDElementTypeInput_Button ||
      element_type == kIOHIDElementTypeInput_Axis) {
    struct Element* element;
    switch (IOHIDElementGetUsage(element_handle)) {
    case kHIDUsage_GD_X:
    case kHIDUsage_GD_Y:
    case kHIDUsage_GD_Z:
    case kHIDUsage_GD_Rx:
    case kHIDUsage_GD_Ry:
    case kHIDUsage_GD_Rz:
    case kHIDUsage_GD_Slider:
    case kHIDUsage_GD_Dial:
    case kHIDUsage_GD_Wheel:
      if (device.n_axes >= MAX_AXES - 1) die("too many axes");

      element = &device.axes[device.n_axes++];
      element->handle = element_handle;
      element->last_value = 0;
    }
  } else if (element_type == kIOHIDElementTypeCollection) {
    CFArrayRef elements = IOHIDElementGetChildren(element_handle);
    if (!elements) die("get elements in collection");

    CFArrayApplyFunction(
      elements,
      (CFRange) { 0, CFArrayGetCount(elements) },
      add_hid_element, NULL);
  }
}

void gc_added_callback(void *ctx,
                       IOReturn res,
                       void *sender,
                       IOHIDDeviceRef device_handle) {
  if (device.handle) {
    printf("ignoring duplicate added call\n");
    return;
  }
  device.handle = device_handle;

  CFArrayRef elements = IOHIDDeviceCopyMatchingElements(device.handle, NULL, kIOHIDOptionsTypeNone);
  if (!elements) die("get elements");

  CFArrayApplyFunction(
    elements,
    (CFRange) { 0, CFArrayGetCount(elements) },
    add_hid_element, NULL);
}

void setup_gc() {
  device.handle = NULL;
  device.n_axes = 0;

  hidman = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
  attempt(IOHIDManagerOpen(hidman, kIOHIDOptionsTypeNone),
          "opening iohidmanager");
  if (!hidman) die("couldn't allocate hidmanager");

  const void *k[2] = {
    (void*) CFSTR(kIOHIDDeviceUsagePageKey),
    (void*) CFSTR(kIOHIDDeviceUsageKey)
  };
  const void *v[2] = {
    (void*)CFNumberCreate(kCFAllocatorDefault,
                          kCFNumberIntType,
                          &hid_page),
    (void*)CFNumberCreate(kCFAllocatorDefault,
                          kCFNumberIntType,
                          &hid_usage)
  };
  if (!v[0] || !v[1]) die("allocating numbers for usage pages");

  CFDictionaryRef deviceMatcher = CFDictionaryCreate(
      kCFAllocatorDefault, k, v, 2,
      &kCFTypeDictionaryKeyCallBacks,
      &kCFTypeDictionaryValueCallBacks);
  if (!deviceMatcher) die("create dictionary");

  IOHIDManagerSetDeviceMatching(hidman, deviceMatcher);
  IOHIDManagerRegisterDeviceMatchingCallback(hidman, gc_added_callback, NULL);
  IOHIDManagerScheduleWithRunLoop(hidman, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);

  while (CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0, TRUE) ==
         kCFRunLoopRunHandledSource) {
    // callbacks for existing devices;
  }
}


#define PACKET_BUF_SIZE (3+64) /* 3 for message, 32 for structure vars */
void send_midi(int cc, int v) {
  printf("Sending CC-%d: %d\n", cc, v);

  Byte buffer[PACKET_BUF_SIZE];
  Byte msg[3];
  msg[0] = 0xb0;  // control change
  msg[1] = cc;
  msg[2] = v;

  MIDIPacketList *packetList = (MIDIPacketList*) buffer;
  MIDIPacket *curPacket = MIDIPacketListInit(packetList);

  curPacket = MIDIPacketListAdd(packetList,
				PACKET_BUF_SIZE,
				curPacket,
				AudioGetCurrentHostTime(),
				3,
				msg);
  if (!curPacket) die("packet list allocation failed");

  attempt(MIDIReceived(midiendpoint, packetList), "error sending midi");
}

void send_cc_midi(int device_num, int device_val) {
  if (device_num > 5) {
    return; // duplicates
  }
  if (device_val < 0) {
    printf("shouldn't be negative: %d is %d", device_num, device_val);
    die("out of range");
  } else if (device_val > 255) {
    printf("shouldn't be so large: %d is %d", device_num, device_val);
    die("out of range");
  }

  if (device_num == 4 || device_num == 5) {
    // single axis, 0-255, left and right linear buttons
    // send on 20 and 21
    send_midi(20 + (device_num - 4), device_val / 2);
  } else {
    // Two joysticks (0/1 and 2/3), each with two axes.
    // These send 128 when centered, and can do 0-255.
    // Split them into two separate axes:
    //   left side:
    //     left:    22
    //     right:   23
    //     up:      24
    //     down:    25
    //   right side:
    //     left:    26
    //     right:   27
    //     up:      28
    //     down:    29

    if (device_val <= 128) {
      send_midi(22 + (device_num*2), 128-device_val);
      send_midi(22 + (device_num*2) + 1, 0);
    } else {
      send_midi(22 + (device_num*2), 0);
      send_midi(22 + (device_num*2) + 1, device_val-128);
    }
  }
}

void poll_gc() {
  int v;
  IOHIDValueRef value;
  struct Element* element;

  for (int i = 0; i < device.n_axes; i++) {
    element = &device.axes[i];
    if (IOHIDDeviceGetValue(device.handle, element->handle, &value) == kIOReturnSuccess) {
      v = (int)IOHIDValueGetIntegerValue(value);
      if (v != element->last_value) {
        printf("%d: %d\n", i, v);
        element->last_value = v;
        send_cc_midi(i, v);
      }
    }
  }
}

void setup_midi() {
  attempt(
    MIDIClientCreate(
     CFSTR("game controller"),
     NULL, NULL, &midiclient),
    "creating OS-X MIDI client object." );
  attempt(
    MIDISourceCreate(
      midiclient,
      CFSTR("game controller"),
      &midiendpoint),
   "creating OS-X virtual MIDI source." );
}

void setup() {
  setup_midi();
  setup_gc();
}

int main(int argc, char** argv) {
  setup();
  while (true) {
    poll_gc();
    usleep(10);
  }
  return 0;
}
