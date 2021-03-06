//
//  RMTileImage.m
//
// Copyright (c) 2008-2009, Route-Me Contributors
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

#import <QuartzCore/QuartzCore.h>

#import "RMGlobalConstants.h"
#import "RMTileImage.h"
#import "RMTileLoader.h"
#import "RMTileCache.h"
#import "RMPixel.h"

static BOOL _didLoadErrorTile = NO;
static BOOL _didLoadMissingTile = NO;
static UIImage *_errorTile = nil;
static UIImage *_missingTile = nil;

@implementation RMTileImage

@synthesize screenLocation, tile, layer, loadingCancelled;

#pragma mark -

+ (UIImage *)errorTile
{
    if (_errorTile)
        return _errorTile;

    if (_didLoadErrorTile)
        return nil;

    _errorTile = [[UIImage imageNamed:@"error.png"] retain];
    _didLoadErrorTile = YES;

    return _errorTile;
}

+ (UIImage *)missingTile
{
    if (_missingTile)
        return _missingTile;

    if (_didLoadMissingTile)
        return nil;

    _missingTile = [[UIImage imageNamed:@"missing.png"] retain];
    _didLoadMissingTile = YES;

    return _missingTile;
}

#pragma mark -

+ (RMTileImage *)tileImageWithTile:(RMTile)tile
{
    return [[[RMTileImage alloc] initWithTile:tile] autorelease];
}

- (id)initWithTile:(RMTile)_tile
{
    if (!(self = [super init]))
        return nil;

    tile = _tile;
    layer = nil;
    screenLocation = CGRectZero;
    loadingCancelled = NO;

    [self makeLayer];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(tileRemovedFromScreen:)
                                                 name:RMMapImageRemovedFromScreenNotification
                                               object:self];

    return self;
}

- (id)init
{
    [NSException raise:@"Invalid initialiser" format:@"Use the designated initialiser for TileImage"];
    [self release];
    return nil;
}

- (void)tileRemovedFromScreen:(NSNotification *)notification
{
    [self cancelLoading];
}

- (void)dealloc
{
    //	RMLog(@"Removing tile image %d %d %d", tile.x, tile.y, tile.zoom);

    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [layer release]; layer = nil;

    [super dealloc];
}

#pragma mark -

- (void)cancelLoading
{
    loadingCancelled = YES;
    [[NSNotificationCenter defaultCenter] postNotificationName:RMMapImageLoadingCancelledNotification object:self];
}

- (void)updateWithImage:(UIImage *)image andNotifyListeners:(BOOL)notifyListeners
{
    dispatch_async(dispatch_get_main_queue(), ^{
        layer.contents = (id)[image CGImage];

        if (notifyListeners) {
            [[NSNotificationCenter defaultCenter] postNotificationName:RMMapImageLoadedNotification object:self userInfo:nil];
        }
    });
}

- (BOOL)isLoaded
{
    return (layer != nil && layer.contents != NULL);
}

- (NSUInteger)hash
{
    return (NSUInteger)RMTileHash(tile);
}

- (BOOL)isEqual:(id)anObject
{
    if (![anObject isKindOfClass:[RMTileImage class]])
        return NO;

    return RMTilesEqual(tile, [(RMTileImage *)anObject tile]);
}

- (void)makeLayer
{
    if (layer == nil)
    {
        layer = [[CALayer alloc] init];
        layer.contents = nil;
        layer.anchorPoint = CGPointZero;
        layer.bounds = CGRectMake(0, 0, screenLocation.size.width, screenLocation.size.height);
        layer.position = screenLocation.origin;
        layer.edgeAntialiasingMask = 0;

        NSMutableDictionary *customActions = [NSMutableDictionary dictionaryWithDictionary:[layer actions]];
        [customActions setObject:[NSNull null] forKey:@"position"];
        [customActions setObject:[NSNull null] forKey:@"bounds"];
        [customActions setObject:[NSNull null] forKey:kCAOnOrderOut];
        [customActions setObject:[NSNull null] forKey:kCAOnOrderIn];

        CATransition *reveal = [[CATransition alloc] init];
        reveal.duration = 0.2;
        reveal.type = kCATransitionFade;
        [customActions setObject:reveal forKey:@"contents"];
        [reveal release];

        layer.actions = customActions;
    }
}

- (void)moveBy:(CGSize)delta
{
    self.screenLocation = RMTranslateCGRectBy(screenLocation, delta);
}

- (void)zoomByFactor:(float)zoomFactor near:(CGPoint)center
{
    self.screenLocation = RMScaleCGRectAboutPoint(screenLocation, zoomFactor, center);
}

- (CGRect)screenLocation
{
    return screenLocation;
}

- (void)setScreenLocation:(CGRect)newScreenLocation
{
    //	RMLog(@"location moving from %f %f to %f %f", screenLocation.origin.x, screenLocation.origin.y, newScreenLocation.origin.x, newScreenLocation.origin.y);
    screenLocation = newScreenLocation;

    if (layer != nil)
    {
        // layer.frame = screenLocation;
        layer.position = screenLocation.origin;
        layer.bounds = CGRectMake(0, 0, screenLocation.size.width, screenLocation.size.height);
    }
}

@end
