//
//  MediaLibraryOutlineViewController.m
//  DeaDBeeF
//
//  Created by Oleksiy Yakovenko on 7/28/20.
//  Copyright © 2020 Oleksiy Yakovenko. All rights reserved.
//

#include <deadbeef/deadbeef.h>
#import "DdbShared.h"
#import "medialib.h"
#import "artwork.h"
#import "AppDelegate.h"
#import "MediaLibraryOutlineView.h"
#import "MediaLibraryItem.h"
#import "MediaLibraryOutlineViewController.h"
#import "MedialibItemDragDropHolder.h"
#import "TrackContextMenu.h"
#import "TrackPropertiesWindowController.h"

extern DB_functions_t *deadbeef;

@interface MediaLibraryOutlineViewController() <NSOutlineViewDataSource,MediaLibraryOutlineViewDelegate,TrackContextMenuDelegate,TrackPropertiesWindowControllerDelegate> {
    ddb_mediasource_list_selector_t *_selectors;
}

@property (nonatomic) MediaLibraryItem *medialibRootItem;

@property (nullable, nonatomic) NSString *searchString;

@property (nonatomic) NSArray *topLevelItems;
@property (nonatomic) BOOL outlineViewInitialized;

@property (nonatomic) int listenerId;

@property (nonatomic) NSOutlineView *outlineView;
@property (nonatomic) NSSearchField *searchField;
@property (nonatomic) NSPopUpButton *selectorPopup;

@property (atomic) DB_mediasource_t *medialibPlugin;
@property (atomic,readonly) ddb_mediasource_source_t medialibSource;
@property (atomic) ddb_artwork_plugin_t *artworkPlugin;

@property (nonatomic) ddb_medialib_item_t *medialibItemTree;

@property (nonatomic) NSInteger lastSelectedIndex;
@property (nonatomic) NSMutableArray<MediaLibraryItem *> *selectedItems;

@property (nonatomic) TrackContextMenu *trackContextMenu;
@property (nonatomic) TrackPropertiesWindowController *trkProperties;

@property (nonatomic) NSMutableDictionary<NSString *,NSImage *> *albumArtCache;

@end

@implementation MediaLibraryOutlineViewController

- (ddb_mediasource_source_t)medialibSource {
    AppDelegate *appDelegate = NSApplication.sharedApplication.delegate;
    return appDelegate.mediaLibraryManager.source;
}

- (instancetype)init {
    return [self initWithOutlineView:[NSOutlineView new] searchField:[NSSearchField new] selectorPopup:[NSPopUpButton new]];
}

- (instancetype)initWithOutlineView:(NSOutlineView *)outlineView searchField:(NSSearchField *)searchField selectorPopup:(NSPopUpButton *)selectorPopup {
    self = [super init];
    if (!self) {
        return nil;
    }

    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(applicationWillQuit:) name:@"ApplicationWillQuit" object:nil];

    self.outlineView = outlineView;
    self.outlineView.dataSource = self;
    self.outlineView.delegate = self;
    [self.outlineView registerForDraggedTypes:@[ddbMedialibItemUTIType]];

    self.searchField = searchField;
    self.searchField.target = self;
    self.searchField.action = @selector(searchFieldAction:);

    self.selectorPopup = selectorPopup;
    self.selectorPopup.action = @selector(filterSelectorChanged:);
    self.selectorPopup.target = self;

    self.medialibPlugin = (DB_mediasource_t *)deadbeef->plug_get_for_id ("medialib");
    _selectors = self.medialibPlugin->get_selectors_list (self.medialibSource);
    self.artworkPlugin = (ddb_artwork_plugin_t *)deadbeef->plug_get_for_id ("artwork2");
    self.listenerId = self.medialibPlugin->add_listener (self.medialibSource, _medialib_listener, (__bridge void *)self);

    self.trackContextMenu = [[TrackContextMenu alloc] initWithView:self.outlineView];
    self.outlineView.menu = self.trackContextMenu;
    self.outlineView.menu.delegate = self;

    [self.selectorPopup removeAllItems];

    // populate the selector popup
    for (int i = 0; _selectors[i]; i++) {
        const char *name = self.medialibPlugin->selector_name (self.medialibSource, _selectors[i]);
        [self.selectorPopup addItemWithTitle:@(name)];
    }

    [self.selectorPopup selectItemAtIndex:self.lastSelectedIndex];

    [self initializeTreeView:0];

    [self.outlineView expandItem:self.medialibRootItem];

    [self updateMedialibStatus];

    self.outlineView.doubleAction = @selector(outlineViewDoubleAction:);
    self.outlineView.target = self;

    self.albumArtCache = [NSMutableDictionary new];

    self.selectedItems = [NSMutableArray new];

    return self;
}

- (void)applicationWillQuit:(NSNotification *)notification {
    self.medialibPlugin = NULL;
    self.artworkPlugin = NULL;
    NSLog(@"MediaLibraryOutlineViewController: received applicationWillQuit notification");
}

- (void)dealloc {
    self.medialibPlugin->remove_listener (self.medialibSource, self.listenerId);
    self.medialibPlugin->free_selectors_list (self.medialibSource, _selectors);
    _selectors = NULL;
    self.listenerId = -1;
    self.medialibPlugin = NULL;
}

static void _medialib_listener (ddb_mediasource_event_type_t event, void *user_data) {
    MediaLibraryOutlineViewController *ctl = (__bridge MediaLibraryOutlineViewController *)user_data;
    dispatch_async(dispatch_get_main_queue(), ^{
        [ctl medialibEvent:event];
    });
}

- (void)initializeTreeView:(int)index {
    NSInteger itemIndex = NSNotFound;
    if (self.outlineViewInitialized) {
        itemIndex = [self.topLevelItems indexOfObject:self.medialibRootItem];
        [self.outlineView removeItemsAtIndexes:[NSIndexSet indexSetWithIndex:itemIndex] inParent:nil withAnimation:NSTableViewAnimationEffectNone];
        self.medialibRootItem = nil;
        self.topLevelItems = nil;
    }

    if (self.medialibItemTree) {
        self.medialibPlugin->free_item_tree (self.medialibSource, self.medialibItemTree);
        self.medialibItemTree = NULL;
    }
    self.medialibItemTree = self.medialibPlugin->create_item_tree (self.medialibSource, _selectors[index], self.searchString ? self.searchString.UTF8String : NULL);
    self.medialibRootItem = [[MediaLibraryItem alloc] initWithItem:self.medialibItemTree];

    self.topLevelItems = @[
        self.medialibRootItem,
    ];

    if (self.outlineViewInitialized) {
        [self.outlineView insertItemsAtIndexes:[NSIndexSet indexSetWithIndex:itemIndex] inParent:nil withAnimation:NSTableViewAnimationEffectNone];
    }
    if (!self.outlineViewInitialized) {
        [self.outlineView reloadData];
    }

    // Restore selected/expanded state
    // Defer one frame, since the row indexes are unavailable immediately.
    dispatch_async(dispatch_get_main_queue(), ^{
        NSMutableIndexSet *selectedRowIndexes = [NSMutableIndexSet new];
        [self.outlineView beginUpdates];
        [self restoreSelectedExpandedStateForItem:self.medialibRootItem selectedRows:selectedRowIndexes];
        [self.outlineView selectRowIndexes:selectedRowIndexes byExtendingSelection:NO];
        [self.outlineView endUpdates];
    });

    self.outlineViewInitialized = YES;
}

- (void)saveSelectionStateWithItem:(MediaLibraryItem *)item {
    const ddb_medialib_item_t *medialibItem = item.medialibItem;
    if (medialibItem == NULL) {
        return;
    }

    NSInteger rowIndex = [self.outlineView rowForItem:item];
    if (rowIndex != -1) {
        BOOL selected = [self.outlineView isRowSelected:rowIndex];
        BOOL expanded = [self.outlineView isItemExpanded:item];
        self.medialibPlugin->set_tree_item_selected (self.medialibSource, medialibItem, selected ? 1 : 0);
        self.medialibPlugin->set_tree_item_expanded (self.medialibSource, medialibItem, expanded ? 1 : 0);
    }

    for (NSUInteger i = 0; i < item.numberOfChildren; i++) {
        [self saveSelectionStateWithItem:item.children[i]];
    }
}

- (void)restoreSelectedExpandedStateForItem:(MediaLibraryItem *)item selectedRows:(NSMutableIndexSet *)selectedRows {
    const ddb_medialib_item_t *medialibItem = item.medialibItem;
    if (medialibItem == NULL) {
        return;
    }

    int selected = self.medialibPlugin->is_tree_item_selected (self.medialibSource, medialibItem);
    int expanded = self.medialibPlugin->is_tree_item_expanded (self.medialibSource, medialibItem);

    if (expanded) {
        [self.outlineView expandItem:item expandChildren:NO];
    }
    else {
        [self.outlineView collapseItem:item collapseChildren:NO];
    }

    if (selected) {
        NSInteger rowIndex = [self.outlineView rowForItem:item];
        if (rowIndex != -1) {
            [selectedRows addIndex:rowIndex];
        }
    }

    for (NSUInteger i = 0; i < item.numberOfChildren; i++) {
        [self restoreSelectedExpandedStateForItem:item.children[i] selectedRows:selectedRows];
    }
}

- (void)updateMedialibStatusForView:(NSTableCellView *)view {
    ddb_mediasource_state_t state = self.medialibPlugin->scanner_state (self.medialibSource);
    int enabled = self.medialibPlugin->is_source_enabled (self.medialibSource);
    switch (state) {
    case DDB_MEDIASOURCE_STATE_IDLE:
        view.textField.stringValue = enabled ? @"All Music" : @"Media library is disabled";
        break;
    case DDB_MEDIASOURCE_STATE_LOADING:
        view.textField.stringValue = @"Loading...";
        break;
    case DDB_MEDIASOURCE_STATE_SCANNING:
        view.textField.stringValue = @"Scanning...";
        break;
    case DDB_MEDIASOURCE_STATE_INDEXING:
        view.textField.stringValue = @"Indexing...";
        break;
    case DDB_MEDIASOURCE_STATE_SAVING:
        view.textField.stringValue = @"Saving...";
        break;
   }
}

- (void)updateMedialibStatus {
    NSInteger row = [self.outlineView rowForItem:self.medialibRootItem];
    if (row < 0) {
        return;
    }
    NSTableCellView *view = [[self.outlineView rowViewAtRow:row makeIfNecessary:NO]  viewAtColumn:0];


    [self updateMedialibStatusForView:view];
}

- (void)medialibEvent:(ddb_mediasource_event_type_t)event {
    if (self.medialibPlugin == NULL) {
        return;
    }
    switch (event) {
    case DDB_MEDIASOURCE_EVENT_CONTENT_DID_CHANGE:
        [self filterChanged];
        break;
    case DDB_MEDIASOURCE_EVENT_STATE_DID_CHANGE:
    case DDB_MEDIASOURCE_EVENT_ENABLED_DID_CHANGE:
        [self updateMedialibStatus];
        break;
    case DDB_MEDIASOURCE_EVENT_SELECTORS_DID_CHANGE:
        break;
    case DDB_MEDIASOURCE_EVENT_OUT_OF_SYNC:
        self.medialibPlugin->refresh(self.medialibSource);
        break;
    }
}

- (ddb_playlist_t *)getDestPlaylist {
    ddb_playlist_t *curr_plt = NULL;
    if (deadbeef->conf_get_int ("cli_add_to_specific_playlist", 1)) {
        char str[200];
        deadbeef->conf_get_str ("cli_add_playlist_name", "Default", str, sizeof (str));
        curr_plt = deadbeef->plt_find_by_name (str);
        if (!curr_plt) {
            curr_plt = deadbeef->plt_append (str);
        }
    }
    return curr_plt;
}

- (int)addSelectionToPlaylist:(ddb_playlist_t *)curr_plt {
    MediaLibraryItem *item = [self selectedItem];
    NSMutableArray<MediaLibraryItem *> *items = [NSMutableArray new];
    [self arrayOfPlayableItemsForItem:item outputArray:items];

    int count = 0;

    ddb_playItem_t *prev = deadbeef->plt_get_last(curr_plt, PL_MAIN);
    for (item in items) {
        ddb_playItem_t *playItem = item.playItem;
        if (playItem == NULL) {
            continue;
        }
        ddb_playItem_t *it = deadbeef->pl_item_alloc();
        deadbeef->pl_item_copy (it, playItem);
        deadbeef->plt_insert_item (curr_plt, prev, it);
        if (prev != NULL) {
            deadbeef->pl_item_unref (prev);
        }
        prev = it;
        count += 1;
    }
    if (prev != NULL) {
        deadbeef->pl_item_unref (prev);
    }
    prev = NULL;

    deadbeef->pl_save_all();

    return count;
}

- (void)outlineViewDoubleAction:(NSOutlineView *)sender {
    NSInteger row = self.outlineView.selectedRow;
    if (row == -1) {
        return;
    }

    ddb_playlist_t * curr_plt = [self getDestPlaylist];
    if (!curr_plt) {
        return;
    }

    deadbeef->plt_set_curr (curr_plt);
    deadbeef->plt_clear(curr_plt);

    int count = [self addSelectionToPlaylist:curr_plt];

    deadbeef->plt_unref (curr_plt);

    if (count > 0) {
        deadbeef->sendmessage(DB_EV_PLAY_NUM, 0, 0, 0);
    }
    deadbeef->sendmessage (DB_EV_PLAYLISTCHANGED, DDB_PLAYLIST_CHANGE_CONTENT, 0, 0);
}

- (void)filterChanged {
    [self initializeTreeView:(int)self.lastSelectedIndex];
    [self.outlineView expandItem:self.medialibRootItem expandChildren:self.searchString!=nil];
}

- (void)arrayOfPlayableItemsForItem:(MediaLibraryItem *)item outputArray:(out NSMutableArray<MediaLibraryItem *> *)items {
    if (item.playItem != NULL) {
        [items addObject:item];
    }

    for (MediaLibraryItem *child in item.children) {
        [self arrayOfPlayableItemsForItem:child outputArray:items];
    }
}

- (int)widgetMessage:(int)_id ctx:(uint64_t)ctx p1:(uint32_t)p1 p2:(uint32_t)p2 {
    return 0;
}

#pragma mark - NSOutlineViewDataSource

- (NSInteger)outlineView:(NSOutlineView *)outlineView numberOfChildrenOfItem:(id)item {
    if (item == nil) {
        return self.topLevelItems.count;
    }
    else if ([item isKindOfClass:MediaLibraryItem.class]) {
        MediaLibraryItem *mlItem = item;
        return mlItem.numberOfChildren;
    }
    return 0;
}


- (BOOL)outlineView:(NSOutlineView *)outlineView isItemExpandable:(id)item {
    if ([item isKindOfClass:MediaLibraryItem.class]) {
        MediaLibraryItem *mlItem = item;
        return mlItem.numberOfChildren > 0;
    }
    else if (item == nil || item == self.medialibRootItem) {
        return YES;
    }
    return NO;
}

- (BOOL)outlineView:(NSOutlineView *)outlineView isGroupItem:(id)item {
    return item == self.medialibRootItem;
}

- (id)outlineView:(NSOutlineView *)outlineView child:(NSInteger)index ofItem:(id)item {
    if (item == nil) {
        return self.topLevelItems[index];
    }
    else if ([item isKindOfClass:MediaLibraryItem.class]) {
        MediaLibraryItem *mlItem = item;
        return [mlItem childAtIndex:index];
    }

    return [NSString stringWithFormat:@"Error %d", (int)index];
}

#pragma mark - NSOutlineViewDataSource - Drag and drop

- (id<NSPasteboardWriting>)outlineView:(NSOutlineView *)outlineView pasteboardWriterForItem:(MediaLibraryItem *)item {
    if (![item isKindOfClass:MediaLibraryItem.class]) {
        return nil;
    }

    NSMutableArray<MediaLibraryItem *> *items = [NSMutableArray new];
    [self arrayOfPlayableItemsForItem:item outputArray:items];

    ddb_playItem_t **playItems = calloc(items.count, sizeof (ddb_playItem_t *));
    NSInteger count = 0;

    for (MediaLibraryItem *playableItem in items) {
        playItems[count++] = playableItem.playItem;
    }

    return [[MedialibItemDragDropHolder alloc] initWithItems:playItems count:count];
}


- (NSDragOperation)outlineView:(NSOutlineView *)outlineView validateDrop:(id<NSDraggingInfo>)info proposedItem:(id)item proposedChildIndex:(NSInteger)index {
    return NSDragOperationNone;
}

- (BOOL)outlineView:(NSOutlineView *)outlineView acceptDrop:(id<NSDraggingInfo>)info item:(id)item childIndex:(NSInteger)index {
    return NO;
}

- (BOOL)outlineView:(NSOutlineView *)outlineView shouldSelectItem:(id)item {
    return [item isKindOfClass:MediaLibraryItem.class];
}

#pragma mark - NSOutlineViewDelegate

static void cover_get_callback (int error, ddb_cover_query_t *query, ddb_cover_info_t *cover) {
    void (^completionBlock)(ddb_cover_query_t *query, ddb_cover_info_t *cover, int error) = (void (^)(ddb_cover_query_t *query, ddb_cover_info_t *cover, int error))CFBridgingRelease(query->user_data);
    completionBlock(query, cover, error);
}

- (NSString *)albumArtCacheKeyForTrack:(ddb_playItem_t *)track {
    const char *artist = deadbeef->pl_find_meta (track, "artist") ?: "Unknown Artist";
    const char *album = deadbeef->pl_find_meta (track, "album") ?: "Unknown Album";

    return [NSString stringWithFormat:@"artist:%s;album:%s", artist, album];
}

// NOTE: this is running on background thread
- (NSImage *)getImage:(ddb_cover_query_t *)query coverInfo:(ddb_cover_info_t *)cover error:(int)error {
    if (error) {
        return nil;
    }

    NSImage *image;
    if (cover->image_filename) {
        image = [[NSImage alloc] initByReferencingFile:@(cover->image_filename)];
    }

    if (image) {
        // resize
        CGFloat scale;
        NSSize size = image.size;
        if (size.width > size.height) {
            scale = 24/size.width;
        }
        else {
            scale = 24/size.height;
        }
        size.width *= scale;
        size.height *= scale;

        if (size.width >= 1 && size.height >= 1) {
            NSImage *smallImage = [[NSImage alloc] initWithSize:size];
            [smallImage lockFocus];
            image.size = size;
            NSGraphicsContext.currentContext.imageInterpolation = NSImageInterpolationHigh;
            [image drawAtPoint:NSZeroPoint fromRect:CGRectMake(0, 0, size.width, size.height) operation:NSCompositingOperationCopy fraction:1.0];
            [smallImage unlockFocus];
            image = smallImage;
        }
        else {
            image = nil;
        }
    }

    // NOTE: this would not cause a memory leak, since the artwork plugin keeps track of the covers, and will free them at exit
    if (self.artworkPlugin != NULL) {
        self.artworkPlugin->cover_info_release (cover);
    }
    cover = NULL;

    return image;
}

- (void)updateCoverForItem:(MediaLibraryItem *)item track:(ddb_playItem_t *)track {
    void (^completionBlock)(ddb_cover_query_t *query, ddb_cover_info_t *cover, int error) = ^(ddb_cover_query_t *query, ddb_cover_info_t *cover, int error) {
        NSImage *image = [self getImage:query coverInfo:cover error:error];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (image != nil) {
                NSString *key = [self albumArtCacheKeyForTrack:query->track];
                self.albumArtCache[key] = image;
            }
            deadbeef->pl_item_unref (query->track);
            free (query);
            NSInteger row = [self.outlineView rowForItem:item];
            if (row == -1) {
                return;
            }
            item.coverImage = image;
            NSTableRowView *rowView = [self.outlineView rowViewAtRow:row makeIfNecessary:NO];
            NSTableCellView *cellView = [rowView viewAtColumn:0];
            cellView.imageView.image = image;
        });
    };
    ddb_cover_query_t *query = calloc (1, sizeof (ddb_cover_query_t));
    query->_size = sizeof (ddb_cover_query_t);
    query->user_data = (void *)CFBridgingRetain(completionBlock);
    query->track = track;
    deadbeef->pl_item_ref (track);
    self.artworkPlugin->cover_get(query, cover_get_callback);

}

- (nullable NSView *)outlineView:(NSOutlineView *)outlineView viewForTableColumn:(nullable NSTableColumn *)tableColumn item:(id)item {
    NSTableCellView *view;
    if ([item isKindOfClass:MediaLibraryItem.class]) {
        MediaLibraryItem *mlItem = item;
        ddb_playItem_t *it = NULL;
        if (mlItem.numberOfChildren) {
            it = [mlItem childAtIndex:0].playItem;
        }
        if (item == self.medialibRootItem) {
            view = [outlineView makeViewWithIdentifier:@"TextCell" owner:self];
        }
        else {
            view = [outlineView makeViewWithIdentifier:@"ImageTextCell" owner:self];
        }
        if (item == self.medialibRootItem) {
            [self updateMedialibStatusForView:view];
        }
        else {
            view.textField.stringValue = mlItem.stringValue;
            view.imageView.image = nil;

            if (it) {
                if (mlItem.coverImage) {
                    view.imageView.image = mlItem.coverImage;
                }
                else {
                    NSString *key = [self albumArtCacheKeyForTrack:it];
                    NSImage *image = self.albumArtCache[key];
                    if (image) {
                        view.imageView.image = image;
                    }
                    else if (self.artworkPlugin != NULL) {
                        view.imageView.image = nil;
                        if (!mlItem.coverObtained) {
                            NSInteger row = [self.outlineView rowForItem:mlItem];
                            if (row >= 0) {
                                NSTableCellView *cellView = [[self.outlineView rowViewAtRow:row makeIfNecessary:NO] viewAtColumn:0];
                                if (cellView) {
                                    [self updateCoverForItem:mlItem track:it];
                                }
                            }
                            mlItem.coverObtained = YES;
                        }
                    }
                }
            }
        }
    }
    return view;
}

- (void)outlineViewItemDidExpand:(NSNotification *)notification {
    NSObject *object = notification.userInfo[@"NSObject"];
    if (![object isKindOfClass:MediaLibraryItem.class]) {
        return;
    }

    MediaLibraryItem *item = (MediaLibraryItem *)object;

    const ddb_medialib_item_t *medialibItem = item.medialibItem;
    if (medialibItem != NULL) {
        self.medialibPlugin->set_tree_item_expanded (self.medialibSource, medialibItem, 1);
    }
}

- (void)outlineViewItemDidCollapse:(NSNotification *)notification {
    NSObject *object = notification.userInfo[@"NSObject"];
    if (![object isKindOfClass:MediaLibraryItem.class]) {
        return;
    }

    MediaLibraryItem *item = (MediaLibraryItem *)object;

    const ddb_medialib_item_t *medialibItem = item.medialibItem;
    if (medialibItem != NULL) {
        self.medialibPlugin->set_tree_item_expanded (self.medialibSource, medialibItem, 0);
    }
}

- (void)outlineViewSelectionDidChange:(NSNotification *)notification {
    [self saveSelectionStateWithItem:self.medialibRootItem];
}

#pragma mark - MediaLibraryOutlineViewDelegate

- (void)mediaLibraryOutlineViewDidActivateAlternative:(MediaLibraryOutlineView *)outlineView {
    ddb_playlist_t * curr_plt = [self getDestPlaylist];
    if (!curr_plt) {
        return;
    }

    deadbeef->plt_set_curr (curr_plt);

    [self addSelectionToPlaylist:curr_plt];

    deadbeef->plt_unref (curr_plt);

    deadbeef->sendmessage (DB_EV_PLAYLISTCHANGED, DDB_PLAYLIST_CHANGE_CONTENT, 0, 0);
}

- (BOOL)mediaLibraryOutlineView:(MediaLibraryOutlineView *)outlineView shouldDisplayMenuForRow:(NSInteger)row {
    id item = [self.outlineView itemAtRow:row];
    return [item isKindOfClass:MediaLibraryItem.class];
}

#pragma mark - TrackContextMenuDelegate

- (void)trackContextMenuShowTrackProperties:(TrackContextMenu *)trackContextMenu {
    if (!self.trkProperties) {
        self.trkProperties = [[TrackPropertiesWindowController alloc] initWithWindowNibName:@"TrackProperties"];
    }
    self.trkProperties.mediaLibraryItems = self.selectedItems;
    self.trkProperties.delegate = self;
    [self.trkProperties showWindow:self];
}

- (void)trackContextMenuDidReloadMetadata:(TrackContextMenu *)trackContextMenu {
    self.medialibPlugin->refresh(self.medialibSource);
}

- (void)trackContextMenuDidDeleteFiles:(TrackContextMenu *)trackContextMenu cancelled:(BOOL)cancelled {
    if (!cancelled) {
        self.medialibPlugin->refresh(self.medialibSource);
    }
}

#pragma mark - TrackPropertiesWindowControllerDelegate

- (void)trackPropertiesWindowControllerDidUpdateTracks:(TrackPropertiesWindowController *)windowController {
    self.medialibPlugin->refresh(self.medialibSource);
}

- (MediaLibraryItem *)selectedItem {
    NSInteger row = -1;
    MediaLibraryItem *item;

    row = self.outlineView.selectedRow;
    if (row == -1) {
        return NULL;
    }

    item = [self.outlineView itemAtRow:row];
    if (!item || ![item isKindOfClass:MediaLibraryItem.class]) {
        return NULL;
    }

    return item;
}

- (void)addSelectedItemsRecursively:(MediaLibraryItem *)item {
    if (![item isKindOfClass:MediaLibraryItem.class]) {
        return;
    }

    ddb_playItem_t *it = item.playItem;
    if (it) {
        [self.selectedItems addObject:item];
    }

    for (NSUInteger i = 0; i < item.numberOfChildren; i++) {
        [self addSelectedItemsRecursively:item.children[i]];
    }
}

- (void)menuNeedsUpdate:(TrackContextMenu *)menu {
    [self.selectedItems removeAllObjects];
    NSInteger clickedRow = self.outlineView.clickedRow;
    if (clickedRow != -1 && [self.outlineView isRowSelected:clickedRow]) {
        [self.outlineView.selectedRowIndexes enumerateIndexesUsingBlock:^(NSUInteger row, BOOL * _Nonnull stop) {
            [self addSelectedItemsRecursively:[self.outlineView itemAtRow:row]];
        }];
    }
    else if (clickedRow != -1) {
        [self addSelectedItemsRecursively:[self.outlineView itemAtRow:clickedRow]];
    }

    ddb_playItem_t **tracks = NULL;
    NSInteger count = 0;

    if (self.selectedItems.count) {
        tracks = calloc (self.selectedItems.count, sizeof (ddb_playItem_t *));
        for (MediaLibraryItem *item in self.selectedItems) {
            ddb_playItem_t *it = deadbeef->pl_item_alloc();
            deadbeef->pl_item_copy (it, item.playItem);
            tracks[count++] = it;
        }
    }

    [self.trackContextMenu updateWithTrackList:tracks count:count playlist:NULL currentTrack:NULL currentTrackIdx:-1];

    ddb_playlist_t *plt = deadbeef->plt_alloc("MediaLib Action Playlist");

    ddb_playItem_t *after = NULL;
    for (int i = 0; i < count; i++) {
        after = deadbeef->plt_insert_item(plt, after, tracks[i]);
    }
    deadbeef->plt_select_all(plt);

    deadbeef->action_set_playlist(plt);
    [self.trackContextMenu update:plt  actionContext:DDB_ACTION_CTX_PLAYLIST];

    deadbeef->plt_unref(plt);

    for (int i = 0; i < count; i++) {
        deadbeef->pl_item_unref (tracks[i]);
    }

    free (tracks);
}

- (NSIndexSet *)outlineView:(NSOutlineView *)outlineView selectionIndexesForProposedSelection:(NSIndexSet *)proposedSelectionIndexes {
    NSMutableIndexSet *selectionIndexes = [NSMutableIndexSet new];

    // prevent selecting filter items
    [proposedSelectionIndexes enumerateIndexesUsingBlock:^(NSUInteger row, BOOL * _Nonnull stop) {
        id item = [self.outlineView itemAtRow:row];
        if (item != self.medialibRootItem) {
            [selectionIndexes addIndex:row];
        }
    }];
    return selectionIndexes;
}

#pragma mark - NSPopUpButton

- (void)filterSelectorChanged:(NSPopUpButton *)sender {
    self.lastSelectedIndex = self.selectorPopup.indexOfSelectedItem;
    [self filterChanged];
}

#pragma mark - NSSearchField

- (void)mediaLibrarySearchCellViewTextChanged:(nonnull NSString *)text {
}

- (IBAction)searchFieldAction:(NSSearchField *)sender {
    NSString *text = self.searchField.stringValue;
    if ([text isEqualToString:@""]) {
        self.searchString = nil;
    }
    else {
        self.searchString = text;
    }
    [self filterChanged];
}

@end
