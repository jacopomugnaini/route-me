//
// RMDBMapSource.m
//
// Copyright (c) 2009, Frank Schroeder, SharpMind GbR
// All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//
// * Redistributions of source code must retain the above copyright notice, this
//   list of conditions and the following disclaimer.
// * Redistributions in binary form must reproduce the above copyright notice,
//   this list of conditions and the following disclaimer in the documentation
//   and/or other materials provided with the distribution.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
// ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE
// LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
// INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
// CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
// POSSIBILITY OF SUCH DAMAGE.

// RMDBMap source is an implementation of an sqlite tile source which is 
// can be used as an offline map store. 
//
// The implementation expects two tables in the database:
//
// table "preferences" - contains the map meta data as name/value pairs
//
//    SQL: create table preferences(name text primary key, value text)
//
//    The preferences table must at least contain the following
//    values for the tile source to function properly.
//
//      * map.minZoom           - minimum supported zoom level
//      * map.maxZoom           - maximum supported zoom level
//      * map.tileSideLength    - tile size in pixels
// 
//    Optionally it can contain the following values
// 
//    Coverage area:
//      * map.coverage.topLeft.latitude
//      * map.coverage.topLeft.longitude
//      * map.coverage.bottomRight.latitude
//      * map.coverage.bottomRight.longitude
//      * map.coverage.center.latitude
//      * map.coverage.center.longitude
//
//    Attribution:
//      * map.shortName
//      * map.shortAttribution
//      * map.longDescription
//      * map.longAttribution
//
// table "tiles" - contains the tile images
//
//    SQL: create table tiles(tilekey integer primary key, image blob)
//
//    The tile images are stored in the "image" column as a blob. 
//    The primary key of the table is the "tilekey" which is computed
//    with the RMTileKey function (found in RMTile.h)
//
//    uint64_t RMTileKey(RMTile tile);
//    

#import "RMDBMapSource.h"
#import "RMTileImage.h"
#import "RMTileCache.h"
#import "RMFractalTileProjection.h"

#define kDefaultLatLonBoundingBox ((RMSphericalTrapezium){.northeast = {.latitude = 90, .longitude = 180}, .southwest = {.latitude = -90, .longitude = -180}})

#define FMDBErrorCheck(db) { if ([db hadError]) { NSLog(@"DB error %d on line %d: %@", [db lastErrorCode], __LINE__, [db lastErrorMessage]); } }

// mandatory preference keys
#define kMinZoomKey @"map.minZoom"
#define kMaxZoomKey @"map.maxZoom"
#define kTileSideLengthKey @"map.tileSideLength"

// optional preference keys for the coverage area
#define kCoverageTopLeftLatitudeKey @"map.coverage.topLeft.latitude"
#define kCoverageTopLeftLongitudeKey @"map.coverage.topLeft.longitude"
#define kCoverageBottomRightLatitudeKey @"map.coverage.bottomRight.latitude"
#define kCoverageBottomRightLongitudeKey @"map.coverage.bottomRight.longitude"
#define kCoverageCenterLatitudeKey @"map.coverage.center.latitude"
#define kCoverageCenterLongitudeKey @"map.coverage.center.longitude"

// optional preference keys for the attribution
#define kShortNameKey @"map.shortName"
#define kLongDescriptionKey @"map.longDescription"
#define kShortAttributionKey @"map.shortAttribution"
#define kLongAttributionKey @"map.longAttribution"


@interface RMDBMapSource (Preferences)

- (NSString *)getPreferenceAsString:(NSString *)name;
- (float)getPreferenceAsFloat:(NSString *)name;
- (int)getPreferenceAsInt:(NSString *)name;

@end

#pragma mark -

@implementation RMDBMapSource

@synthesize uniqueTilecacheKey;

- (id)initWithPath:(NSString *)path
{
	if (!(self = [super init]))
        return nil;

    uniqueTilecacheKey = [[[path lastPathComponent] stringByDeletingPathExtension] retain];
    
    // open the db
    db = [[FMDatabase alloc] initWithPath:path];
    if ([db openWithFlags:SQLITE_OPEN_READONLY])
    {
        RMLog(@"Opening db map source %@", path);

        // Debug mode
//        [db setTraceExecution:YES];

        // get the tile side length
        tileSideLength = [self getPreferenceAsInt:kTileSideLengthKey];

        // get the supported zoom levels
        minZoom = [self getPreferenceAsFloat:kMinZoomKey];
        maxZoom = [self getPreferenceAsFloat:kMaxZoomKey];

        // get the coverage area
        topLeft.latitude = [self getPreferenceAsFloat:kCoverageTopLeftLatitudeKey];
        topLeft.longitude = [self getPreferenceAsFloat:kCoverageTopLeftLongitudeKey];
        bottomRight.latitude = [self getPreferenceAsFloat:kCoverageBottomRightLatitudeKey];
        bottomRight.longitude = [self getPreferenceAsFloat:kCoverageBottomRightLongitudeKey];
        center.latitude = [self getPreferenceAsFloat:kCoverageCenterLatitudeKey];
        center.longitude = [self getPreferenceAsFloat:kCoverageCenterLongitudeKey];

        RMLog(@"Tile size: %d pixel", tileSideLength);
        RMLog(@"Supported zoom range: %.0f - %.0f", minZoom, maxZoom);
        RMLog(@"Coverage area: (%2.6f,%2.6f) x (%2.6f,%2.6f)", 
              topLeft.latitude, 
              topLeft.longitude,
              bottomRight.latitude, 
              bottomRight.longitude);
        RMLog(@"Center: (%2.6f,%2.6f)", 
              center.latitude, 
              center.longitude);
    } else {
        RMLog(@"Error opening db map source %@", path);
    }

    // init the tile projection
    tileProjection = [[RMFractalTileProjection alloc] initFromProjection:[self projection]
                                                          tileSideLength:tileSideLength
                                                                 maxZoom:maxZoom
                                                                 minZoom:minZoom];

	return self;
}

- (void)dealloc
{
    [uniqueTilecacheKey release]; uniqueTilecacheKey = nil;
	[db release]; db = nil;
	[tileProjection release]; tileProjection = nil;
	[super dealloc];
}

- (CLLocationCoordinate2D)topLeftOfCoverage
{
	return topLeft;
}

- (CLLocationCoordinate2D)bottomRightOfCoverage
{
	return bottomRight;
}

- (CLLocationCoordinate2D)centerOfCoverage
{
	return center;
}

#pragma mark RMTileSource methods

- (UIImage *)imageForTileImage:(RMTileImage *)tileImage addToCache:(RMTileCache *)tileCache withCacheKey:(NSString *)aCacheKey
{
    UIImage *image = nil;

	RMTile tile = [[self mercatorToTileProjection] normaliseTile:tileImage.tile];

    // get the unique key for the tile
    NSNumber *key = [NSNumber numberWithLongLong:RMTileKey(tile)];

    @synchronized(db) {
        // fetch the image from the db
        FMResultSet *result = [db executeQuery:@"SELECT image FROM tiles WHERE tilekey = ?", key];
        FMDBErrorCheck(db);

        if ([result next]) {
            image = [[[UIImage alloc] initWithData:[result dataForColumnIndex:0]] autorelease];
        } else {
            image = [RMTileImage missingTile];
        }
        [result close];
    }

    if (tileCache)
        [tileCache addImage:image forTile:tile withCacheKey:aCacheKey];

	return image;
}

- (RMSphericalTrapezium)latitudeLongitudeBoundingBox
{
    CLLocationCoordinate2D southwest, northeast;
    southwest.latitude = bottomRight.latitude;
    southwest.longitude = topLeft.longitude;
    northeast.latitude = topLeft.latitude;
    northeast.longitude = bottomRight.longitude;

    RMSphericalTrapezium bbox;
    bbox.southwest = southwest;
    bbox.northeast = northeast;

    return bbox;
}

- (NSString *)uniqueTilecacheKey
{
    return uniqueTilecacheKey;
}

- (NSString *)shortName
{
	return [self getPreferenceAsString:kShortNameKey];
}

- (NSString *)longDescription
{
	return [self getPreferenceAsString:kLongDescriptionKey];
}

- (NSString *)shortAttribution
{
	return [self getPreferenceAsString:kShortAttributionKey];
}

- (NSString *)longAttribution
{
	return [self getPreferenceAsString:kLongAttributionKey];
}

#pragma mark preference methods

- (NSString *)getPreferenceAsString:(NSString*)name
{
	NSString* value = nil;

    @synchronized(db) {
        FMResultSet *result = [db executeQuery:@"select value from preferences where name = ?", name];
        if ([result next]) {
            value = [result stringForColumn:@"value"];
        }
        [result close];
    }

	return value;
}

- (float)getPreferenceAsFloat:(NSString *)name
{
	NSString *value = [self getPreferenceAsString:name];
	return (value == nil) ? INT_MIN : [value floatValue];
}

- (int)getPreferenceAsInt:(NSString *)name
{
	NSString* value = [self getPreferenceAsString:name];
	return (value == nil) ? INT_MIN : [value intValue];
}

@end
