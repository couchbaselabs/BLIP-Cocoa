//
//  BLIPProperties.m
//  BLIP
//
//  Created by Jens Alfke on 5/13/08.
//  Copyright 2008-2013 Jens Alfke.
//  Copyright (c) 2013-2015 Couchbase, Inc. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file
//  except in compliance with the License. You may obtain a copy of the License at
//    http://www.apache.org/licenses/LICENSE-2.0
//  Unless required by applicable law or agreed to in writing, software distributed under the
//  License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
//  either express or implied. See the License for the specific language governing permissions
//  and limitations under the License.

#import "BLIPProperties.h"
#import "MYBuffer.h"
#import "MYData.h"
#import "MYLogging.h"
#import "Test.h"
#import "MYData.h"


/** Common strings are abbreviated as single-byte strings in the packed form.
    The ascii value of the single character minus one is the index into this table. */
static const char* kAbbreviations[] = {
    "Profile",
    "Error-Code",
    "Error-Domain",

    "Content-Type",
    "application/json",
    "application/octet-stream",
    "text/plain; charset=UTF-8",
    "text/xml",

    "Accept",
    "Cache-Control",
    "must-revalidate",
    "If-Match",
    "If-None-Match",
    "Location",
};
#define kNAbbreviations ((sizeof(kAbbreviations)/sizeof(const char*)))  // cannot exceed 31!



static NSString* readCString(MYSlice* slice) {
    const char* key = slice->bytes;
    size_t len = strlen(key);
    MYSliceMoveStart(slice, len+1);
    if (len == 0)
        return @"";
    uint8_t first = (uint8_t)key[0];
    if (first < ' ' && key[1]=='\0') {
        // Single-control-character property string is an abbreviation:
        if (first > kNAbbreviations)
            return nil;
        static NSMutableArray* kAbbrevNSStrings;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            kAbbrevNSStrings = [[NSMutableArray alloc] initWithCapacity: kNAbbreviations];
            for (int i=0; i<kNAbbreviations; i++)
                [kAbbrevNSStrings addObject: [NSString stringWithUTF8String: kAbbreviations[i]]];
        });
        return kAbbrevNSStrings[first-1];
    }
    return [NSString stringWithUTF8String: key];
}


NSDictionary* BLIPParseProperties(MYSlice *data, BOOL* complete) {
    MYSlice slice = *data;
    uint64_t length;
    if (!MYSliceReadVarUInt(&slice, &length) || slice.length < length) {
        *complete = NO;
        return nil;
    }
    *complete = YES;
    if (length == 0) {
        MYSliceMoveStart(data, 1);
        return @{};
    }
    MYSlice buf = MYMakeSlice(slice.bytes, (size_t)length);
    if (((const char*)slice.bytes)[buf.length - 1] != '\0')
        return nil;     // checking for nul at end makes it safe to use strlen in readCString
    NSMutableDictionary* result = [NSMutableDictionary new];
    while (buf.length > 0) {
        NSString* key = readCString(&buf);
        if (!key)
            return nil;
        NSString* value = readCString(&buf);
        if (!value)
            return nil;
        result[key] = value;
    }
    MYSliceMoveStartTo(data, buf.bytes);
    return result;
}


NSDictionary* BLIPReadPropertiesFromBuffer(MYBuffer* buffer, BOOL *complete) {
    MYSlice slice = buffer.flattened.my_asSlice;
    MYSlice readSlice = slice;
    NSDictionary* props = BLIPParseProperties(&readSlice, complete);
    if (props)
        [buffer readSliceOfMaxLength: slice.length - readSlice.length];
    return props;
}


static void appendStr( NSMutableData *data, NSString *str ) {
    const char *utf8 = [str UTF8String];
    for (uint8_t i=0; i<kNAbbreviations; i++)
        if (strcmp(utf8,kAbbreviations[i])==0) {
            const UInt8 abbrev[2] = {i+1,0};
            [data appendBytes: &abbrev length: 2];
            return;
        }
    [data appendBytes: utf8 length: strlen(utf8)+1];
}

NSData* BLIPEncodeProperties(NSDictionary* properties) {
    static const int kPlaceholderLength = 1; // space to reserve for varint length
    NSMutableData *data = [NSMutableData dataWithCapacity: 16*properties.count];
    [data setLength: kPlaceholderLength];
    for (NSString *name in properties) {
        appendStr(data,name);
        appendStr(data,properties[name]);
    }
    NSUInteger length = data.length - kPlaceholderLength;
    UInt8 buf[10];
    UInt8* end = MYEncodeVarUInt(buf, length);
    [data replaceBytesInRange: NSMakeRange(0, kPlaceholderLength)
                    withBytes: buf
                       length: end-buf];
    return data;
}
