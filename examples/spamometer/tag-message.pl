#!/usr/bin/perl -w
use strict;

use Mail::Message;
use Mail::Box::Mbox::Message;
use Mail::Classifier::GrahamSpam;

my ($saved_classifier) = shift;
die "Can't find filename $saved_classifier" unless [ -r $saved_classifier ];
my $bb = Mail::Classifier::GrahamSpam->new( $saved_classifier );
<>;
my $orig = Mail::Message->read(\*STDIN);
$bb->tagmsg( { 'msg'=>$orig, 'threshold'=>0.9, 'header'=>"X-Mail-Classifier"});
my $msg = Mail::Box::Mbox::Message->coerce($orig);
$msg->write;

exit;
