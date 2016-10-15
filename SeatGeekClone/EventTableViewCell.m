//
//  EventTableViewCell.m
//  SGHTTPRequest
//
//  Created by Adam on 10/11/16.
//  Copyright © 2016 atecle. All rights reserved.
//

#import "EventTableViewCell.h"

@implementation EventTableViewCell

- (void)awakeFromNib {
    [super awakeFromNib];
    // Initialization code
}

- (void)setSelected:(BOOL)selected animated:(BOOL)animated {
    [super setSelected:selected animated:animated];

    // Configure the view for the selected state
}

- (void)setEvent:(SGEvent *)event
{
    _event = event;
}

@end
