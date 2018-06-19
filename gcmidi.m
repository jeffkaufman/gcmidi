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

IOHIDManagerRef hidman = NULL;
int hid_page = kHIDPage_GenericDesktop;
int hid_usage = kHIDUsage_GD_GamePad;

#define MAX_AXES 256

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
  if (result != noErr) {
    die(errmsg);
  }
}

void add_hid_element(const void* v_element, void* ignored) {
  IOHIDElementRef element_handle = (IOHIDElementRef)v_element;
  if (!element_handle) {
    die("invalid element");
  }
  if (IOHIDElementGetUsagePage(element_handle) != kHIDPage_GenericDesktop) {
    return;
  }

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
      element = &device.axes[device.n_axes++];
      element->handle = element_handle;
      element->last_value = 0;
      break;
    }
  } else if (element_type == kIOHIDElementTypeCollection) {
    CFArrayRef elements = IOHIDElementGetChildren(element_handle);
    if (!elements) {
      die("get elements in collection");
    }

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
  if (!elements) {
    die("get elements");
  }

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
  if (!hidman) {
    die("couldn't allocate hidmanager");
  }
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
  if (!v[0] || !v[1]) {
    die("allocating numbers for usage pages");
  }
  CFDictionaryRef deviceMatcher = CFDictionaryCreate(
      kCFAllocatorDefault, k, v, 2,
      &kCFTypeDictionaryKeyCallBacks,
      &kCFTypeDictionaryValueCallBacks);
  if (!deviceMatcher) {
    die("create dictionary");
  }

  IOHIDManagerSetDeviceMatching(hidman, deviceMatcher);
  IOHIDManagerRegisterDeviceMatchingCallback(hidman, gc_added_callback, NULL);
  IOHIDManagerScheduleWithRunLoop(hidman, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);

  while (CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0, TRUE) ==
         kCFRunLoopRunHandledSource) {
    // callbacks for existing devices;
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
      }
    }
  }
}

void setup() {
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
