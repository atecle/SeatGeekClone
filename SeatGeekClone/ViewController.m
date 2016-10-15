//
//  ViewController.m
//  SGHTTPRequest
//
//  Created by Adam on 10/11/16.
//  Copyright © 2016 atecle. All rights reserved.
//

#import "ViewController.h"
#import <SGAPI/SGAPI.h>

@interface ViewController () <UITableViewDataSource>

@property (weak, nonatomic) IBOutlet UISearchBar *searchBar;
@property (weak, nonatomic) IBOutlet UITableView *tableView;
@property (strong, nonatomic) UIRefreshControl *refreshControl;
@property (strong, nonatomic) SGEventSet *eventSet;
@property (copy, nonatomic) NSArray *events;

@end

@implementation ViewController

- (void)viewDidLoad
{
    [super viewDidLoad];

    [self configureTableView];
    [self configureEventSet];
}

#pragma mark - Set up

- (void)configureTableView
{
    self.refreshControl = [[UIRefreshControl alloc] init];
    [self.refreshControl addTarget:self action:@selector(refresh) forControlEvents:UIControlEventValueChanged];

    [self.tableView addSubview:self.refreshControl];
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:NSStringFromClass([UITableViewCell class])];
    self.tableView.dataSource = self;
}

- (void)configureEventSet
{
    self.eventSet = [SGEventSet eventsSet];
    
    __weakSelf me = self;
    self.eventSet.onPageLoaded = ^(NSOrderedSet *events) {
        __strong typeof(self) self = me;
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(self) self = me;
            [self.tableView reloadData];

        });
        [self.refreshControl endRefreshing];
    };
    
    self.eventSet.onPageLoadFailed = ^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSLog(@"Page load failed. %@", error.localizedDescription);
        });
    };
}

#pragma mark - UI

- (void)refresh
{    
    [self loadData];
}

#pragma mark - Networking
- (void)loadData
{
    [self.eventSet fetchNextPage];
}

#pragma mark - UITableViewDataSource

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return self.eventSet.orderdSet.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:NSStringFromClass([UITableViewCell class])];
    
    SGEvent *event = [self.eventSet.orderdSet objectAtIndex:indexPath.row];
    
    cell.textLabel.text = event.title;
    return cell;
}

@end
