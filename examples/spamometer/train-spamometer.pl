#!/usr/bin/perl -w
use strict;

use Mail::Message;
use Mail::Classifier::GrahamSpam;

my ($saved_classifier, $testcat, $testfile) = @ARGV;
my $bb = Mail::Classifier::GrahamSpam->new( $saved_classifier );
$bb->train( { $testfile => $testcat } );
$bb->updatepredictors();
$bb->save($saved_classifier);

exit;
