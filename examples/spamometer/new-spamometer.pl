#!/usr/bin/perl -w
use strict;

use Mail::Message;
use Mail::Classifier::GrahamSpam;

my ($saved_classifier) = shift;
my $bb = Mail::Classifier::GrahamSpam->new();
$bb->save($saved_classifier);

exit;
