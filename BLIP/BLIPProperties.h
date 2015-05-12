//
//  BLIPProperties.h
//  BLIP
//
//  Created by Jens Alfke on 5/13/08.
//  Copyright 2008-2013 Jens Alfke.
//  Copyright (c) 2013-2015 Couchbase, Inc. All rights reserved.

#import <Foundation/Foundation.h>
#import "MYData.h"
@class MYBuffer;


NSDictionary* BLIPParseProperties(MYSlice *data, BOOL *complete);
NSDictionary* BLIPReadPropertiesFromBuffer(MYBuffer*, BOOL *complete);
NSData* BLIPEncodeProperties(NSDictionary* properties);
