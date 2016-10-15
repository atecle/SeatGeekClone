//
//  EventTableViewCell.h
//  SGHTTPRequest
//
//  Created by Adam on 10/11/16.
//  Copyright © 2016 atecle. All rights reserved.
//

#import <UIKit/UIKit.h>
#import "SGEvent.h"

@interface EventTableViewCell : UITableViewCell

@property (weak, nonatomic) IBOutlet UIImageView *imageView;

@property (weak, nonatomic) SGEvent *event;

@end
