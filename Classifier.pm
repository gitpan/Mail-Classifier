package Mail::Classifier;

use 5.008;
use strict;
use warnings;

use Fcntl qw(:DEFAULT :flock);        # for file creation flags
use Carp;
use MLDBM::Sync;
use MLDBM qw(MLDBM::Sync::SDBM_File Storable);
use File::Copy;
use Mail::Box::Manager;
use Mail::Address;
use File::Temp;
use File::Spec;
use Storable qw(lock_nstore lock_retrieve);

our $VERSION = '0.11';

### Initial Documentation ###

=head1 NAME

Mail::Classifier - Perl extension for probabilistic mail classification

=head1 SYNOPSIS

    use Mail::Classifier;
    $bb = Mail::Classifier->new();
    $bb->train( 
        {   'spam.mbox' => 'SPAM', 
            'nonspam.mbox' => 'NONSPAM'
        }
    );         
    %xval = $bb->crossval(  
        {   'folds' => 4, 
            'threshold' => .9, 
            'corpus_list' => {   
                'spam.mbox' => 'SPAM',
                'nonspam.mbox' => 'NONSPAM 
            } 
        } 
    );

In practice, Mail::Classifier is just a stub that must be overridden in a 
subclass, but the general interface is documented here.  See a subclass for 
implementation-specific options or extensions.

=head1 ABSTRACT

Mail::Classifier - Perl extension for probabilistic mail classification

=head1 DESCRIPTION

Mail::Classifier is an abstract base class for mail classification.  As
such provides capabilities for defining working data tables (which may
be stored in memory or on disk) that will persist across saves/restores.
It also provides the message handling capabilities necessary to process
mailboxes and conduct statistical validation.  

Classes inherit from Mail::Classifier to implement a particular
classification algorithm or technique.  Derived classes must implement
methods for learning and scoring messages.  Typically, derived classes
will also define methods for parsing messages into tokens for use in the
learning and scoring methods.

Two derivied classes are included with Mail::Classifier.  The first, 
Mail::Classifier::Trivial
is an example of how to extend the base class.  The second class,
Mail::Classifier::GrahamSpam, implements a Naive Bayesian Filtering
based on the article "A Plan For Spam" by Paul Graham
(http://www.paulgraham.com/spam.html), and is a fully-functional spam
filter.  See the RESULTS section, below.

One of the key benefits of Mail::Classifier is built-in support for generating
classification matrices, both in the standard approach of a test sample and a
holdout sample, or, more powerfully, through cross-validation.
Cross-validation divides training data into "N" folds and iteratively scores
each fold based on a model built on all remaining folds to maximize available
data used in model evaluation. [See "An Introduction to the Bootstrap" by Efron
and Tibshirani (1998), p. 239.  for more details.]  The result is an
out-of-sample evaluation of the performance (i.e. accuracy) of the
classification engine which can operate on smaller training sets without
explicit hold-out samples for validation.  This is often preferable for use in
development as it validates the algorithm and parameter tuning setting 
used without requiring a manipulation of separate hold-out samples.
	
Mail::Classifier is not (yet) an efficient approach to high-volume
classification.  (It's in Perl, not C.)  However, it is ideal for rapid
experimentation and testing of classification algorithms, and benefits
from Perl Regexp capabilities for exploring alternative message
tokenization routines.

=head1 METHODS THAT SHOULD/MUST BE EXTENDED IN A SUBCLASS

    * new 
    * init
    * forget
    * isvalid
    * parse
    * learn
    * unlearn
    * score

With the exception of I<new> and I<init>, these methods are little more than stubs.  
Subclass developers will want to extend these functions to implement
a particular classification algorithm and the associated data structures.

In particular, the I<init> function should be extended using I<_add_data_table>
to provide data structures used by the subclass, and I<forget> will need 
to reflect an appropriate "reset" of these data structures.

The other functions are specific to the algorithm and message handling method
chosen.

=over 4

=cut

######## PUT CODE HERE ##########

=item I<new> [options|FILENAME|CLASSIFIER]

Create a new classifier object, setting any class options by
passing a hash-reference to key/value pairs.  Alternatively, can
be called with a filename from a previous saved classifier, or
another classifier object, in which case the classifier will be cloned,
duplicating all data and datafiles.

    $bb = Mail::Classifier->new();
    $bb = Mail::Classifier->new( { OPTION1 => 'foo', OPTION2 => 'bar' } );
    $bb = Mail::Classifier->new( "/tmp/saved-classifier" );
    $cc = Mail::Classifier->new( $bb );

=cut

sub new {
    my ($caller,$arg) = @_;
    my $class = ref($caller) || $caller;
    my $self  = {};
    bless ($self, $class);
    my %options;
    if ($arg) {
        if (ref $arg eq 'HASH') {       # Passed an options hash ref
            %options = %{$arg};
        }
        elsif (ref \$arg eq 'SCALAR') { # Passed a filename to open
            $self = $self->_load_from_file($arg);
            return $self; 
        }
        elsif (ref $arg eq $class) {    # Passed an object to clone
            $arg->LockAll;
            $self = $self->_clone($arg);
            $arg->UnLockAll;
            return $self;
        }
    }
    # Call initialization -- this should hit actual class, not the base class
    $self->init( {%options} ); 
    return $self;    
}

=item I<init>

Called during I<new> to initialize the class with any options specific to the 
class.  This should include creating data tables with I<_add_data_table>.

    $self->init( {%options} );

=cut 

sub init {
    my ($self, $opts) = @_;
    # Set up basic class members
    $self->_add_data_table('options');
    $self->_add_data_table('filenames');
    # Set up basic options
    $self->{options}{debug} = 0;                     # Crude, but effective 
    # Add any user-set options
    foreach my $key ( keys %{$opts} ) {
        $self->{options}{$key} = $opts->{$key};
    }
}

=item I<forget>        

Blanks out data and structures.  Must be implemented by subclasses.

    $bb->forget;
    
=cut

sub forget {
    my $self = shift;
}    

=item I<isvalid> MESSAGE        
    
Confirm that a message can be handled -- e.g. text vs attachment, etc.  MESSAGE
is a Mail::Message object;

Stub function to be implemented by subclasses. Parent class only returns true. 

    $bb->isvalid($msg);

=cut

sub isvalid { 1; }

=item I<parse> MESSAGE

breaks up a message into tokens -- this is just a stub for where/how
class extensions should place parsing.

    $bb->parse($msg);

=cut

sub parse { 1; }

=item I<learn> CATEGORY, MESSAGE
    
=item I<unlearn> CATEGORY, MESSAGE

I<learn> processes a message as an example of a category according to
some algorithm. MESSAGE is a Mail::Message.

I<unlearn> reverses the process, for example to "unlearn" a message that
has been falsely classified.

Stub functions to be implemented in subclasses.  Does nothing in parent.

    $bb->learn('SPAM', $msg);
    $bb->unlearn('SPAM', $msg);

=cut

sub learn {
    my $self = shift;
    my ($cat, $msg) = @_;
    
    # A real function might do something here to parse out the message
    # using a function call like
    #             my @tokens = $self->parse($msg);
    # to get tokens and then process them
}

sub unlearn {
    my $self = shift;
    my ($cat, $msg) = @_;
    
}

=item I<score> MESSAGE        

Takes a message and returns a list of categories and probabilities in
decending order.  MESSAGE is a Mail::Message

Stub function to be implemented in subclasses.  Parent returns ('NONE',1).

    ($best-cat, $best-cat-prob, @rest) = $bb->score($msg);
    %probs = $bb->score($msg);
    
=cut

sub score {
    my ($self, $msg) = @_;
    
    # in a real class, do something smart; here, just calculate the
    # probabilities and return them

    return ('NONE',1);
}

=head1 METHODS THAT (PROBABLY) DON'T NEED EXTENSION IN COMMON SUBCLASSES

    * train/retrain
	* classify
	* crossval
    * tagmsg
	* tagmbox
    * save
    * setparse  -- DEPRECATED
    * setconfig
    * saveconfig
    * loadconfig
    * debug
    
These functions are part of the "standard" interface to Mail::Classifier.  In a 
properly written subclass, these functions will perform as expected with hopefully
no modifications.

=item I<train>  CORPUS-LIST

=item I<retrain> CORPUS-LIST        

Takes a hash of training corpi filenames and categories, walk through
each message and learn() from them -- may do some post
processing (e.g. trimming a resulting data set).  Training corpi
must be files that Mail::Box::Manager can recognize and process. 
(E.g., unix mbox format.)
                    
I<retrain> is the same as I<train>, but erases any prior training first

    $bb->train( {   'spam.mbox' => 'SPAM', 
                    'nonspam.mbox' => 'NONSPAM'});         

=cut

sub train{
    my ($self, $args) = @_;
    
    while ( my ($file,$cat) = each ( %{$args}) ) {
        my $mgr = Mail::Box::Manager->new;
        $mgr->defaultTrace('NONE') unless $self->{options}{debug};
        my $mbox = $mgr->open($file);
        confess "Can't open mailbox '$file': $!" unless defined $mbox;
        foreach my $msg ($mbox->messages){
            $self->learn($cat,$msg) if $self->isvalid($msg);
        }
        $mbox->close();    
    }
}

sub retrain {
    my ($self, $href) = @_;
    $self->forget;
    $self->train($href);
}

=item I<classify> OPTIONS
                             
    OPTIONS =   {   threshold'   =>  .9,
                    'corpus_list' =>  {   'spam.mbox' => 'SPAM',
                                        'nonspam.mbox' => 'NONSPAM }
                }
                
Takes a a probability threshold, plus a hash reference to
categories and training corpi filenames.  To be counted a message as being scored into a category, the highest 
probability category returned from I<score> must exceed the threshold or else the message 
is scored as the reserved category 'UNK' for unknown.

I<classify> does B<not> destroy prior training -- it merely creates a
classification matrix for a given set of data using the existing 
probabilities.

    %xval = $bb->classify(  {   'threshold' => .9, 
                                'corpus_list' => 
                                    {   'spam.mbox' => 'SPAM',
                                        'nonspam.mbox' => 'NONSPAM } } );
    
=cut 

sub classify {
    my ( $self, $opts) = @_;
    my %mboxes = ();
    my %mresults = ();

    confess("Threshold must be [0,1].") 
        if ( ($opts->{threshold} > 1) || ($opts->{threshold} < 0) ); 

    my $mgr = Mail::Box::Manager->new;
    $mgr->defaultTrace('NONE') unless $self->{options}{debug};

    # prep mailboxes and prep the results array
    my %temp;
    foreach my $cat (values %{$opts->{corpus_list}}) {
    	confess("Can't accept reserved category 'UNK'.") 
        	if $cat eq "UNK";
        $temp{$cat}=1;
    }
    while ( my ($file, $cat) = each %{$opts->{corpus_list}} ) {    
        $mboxes{$file} = $mgr->open($file);
        confess "Can't open mailbox '$file': $!" unless defined $mboxes{$file};
        if ($self->{options}{debug}) {
            my $msg_count = $mboxes{$file}->messages();
            printf "%d messages in mailbox %s\n", $msg_count, $file;
        }
        $mresults{$cat} = {};
        $mresults{$cat}{UNK} = 0;
        foreach my $key ( keys %temp ) {
            $mresults{$cat}{$key} = 0;
        }
    }
    
	while ( my ($file,$cat) = each %{$opts->{corpus_list}} ) {
		print "Scoring mailbox $file\n" if ($self->{options}{debug} >= 1);
		foreach my $msg ($mboxes{$file}->messages){
			next unless $self->isvalid($msg);
			print "Xval: " . $msg->subject() . "\n" if ($self->{options}{debug} >= 5); 
			my ($rv, $p) = $self->score($msg);
			if ( $p >= $opts->{threshold}) {
				$mresults{$cat}{$rv} += 1;
			} else {
				$mresults{$cat}{UNK} += 1;
			}
			printf("\tResult: %s,%.2f\n", $rv, $p) if ($self->{options}{debug} >= 5);
		}
	}
    $mgr->closeAllFolders;
    return %mresults;
}
                
=item I<crossval> OPTIONS
                             
    OPTIONS =   {   'folds'       =>  4,
                    'threshold'   =>  .9,
                    'corpus_list' =>  {   'spam.mbox' => 'SPAM',
                                        'nonspam.mbox' => 'NONSPAM }
                }
                
Takes a integer number of folds, a probability threshold, plus a hash reference to
categories and training corpi filenames.  Return a classification table built with N-fold
cross validation.  To be count a message as being scored into a category, the highest 
probability category returned from I<score> must exceed the threshold or else the message 
is scored as the reserved category 'UNK' for unknown.

I<crossval> destroys prior training -- users should consider cloning and then cross-validating if 
they do not want to lose prior training.  Because of this, cross-validation
is a good test of a specific implementation of an algorithm and option 
settings.  To test the validity of the model trained on a particular data
set on a new data set, use I<classify> instead.

    %xval = $bb->crossval(  {   'folds' => 4, 'threshold' => .9, 
                                'corpus_list' => 
                                    {   'spam.mbox' => 'SPAM',
                                        'nonspam.mbox' => 'NONSPAM } } );
    
=cut 

sub crossval {
    my ( $self, $opts) = @_;
    my %mboxes = ();
    my %mtags = ();
    my %mresults = ();

    confess("Can't crossval with less than 2 folds.") 
        if ($opts->{folds} < 2);
    confess("Threshold must be [0,1].") 
        if ( ($opts->{threshold} > 1) || ($opts->{threshold} < 0) ); 

    my $mgr = Mail::Box::Manager->new;
    $mgr->defaultTrace('NONE') unless $self->{options}{debug};

    # tag all messages with a random number for dividing up sets
    # and prep the results array
    my %temp;
    foreach my $cat (values %{$opts->{corpus_list}}) {
    	confess("Can't accept reserved category 'UNK'.") 
        	if $cat eq "UNK";
        $temp{$cat}=1;
    }
    while ( my ($file, $cat) = each %{$opts->{corpus_list}} ) {    
        $mboxes{$file} = $mgr->open($file);
        confess "Can't open mailbox '$file': $!" unless defined $mboxes{$file};
        if ($self->{options}{debug}) {
            my $msg_count = $mboxes{$file}->messages();
            printf "%d messages in mailbox %s\n", $msg_count, $file;
        }
        foreach my $msg ($mboxes{$file}->messages){
            $mtags{$msg} = int(rand($opts->{folds}));
        }
        $mresults{$cat} = {};
        $mresults{$cat}{UNK} = 0;
        foreach my $key ( keys %temp ) {
            $mresults{$cat}{$key} = 0;
        }
    }
    
    # cross validate by leaving out each fold from build and then
    # scoring that fold with the model trained on the rest
    
    for (my $i=0; $i < $opts->{folds}; $i++) {
        # first, train on all but $i
        print "Training without fold @{[$i+1]}\n" if ($self->{options}{debug} >= 1);
        $self->forget;
        while ( my ($file,$cat) = each %{$opts->{corpus_list}} ) {
            foreach my $msg ($mboxes{$file}->messages){
                next if ($mtags{$msg} == $i);
                next unless $self->isvalid($msg);
                print "Learning: " . $msg->subject() . "\n" if ($self->{options}{debug} >= 5); 
                $self->learn($cat,$msg); 
            }
        }
        # next, score $i
        print "Scoring fold @{[$i+1]}\n" if ($self->{options}{debug} >= 1);
        while ( my ($file,$cat) = each %{$opts->{corpus_list}} ) {
            foreach my $msg ($mboxes{$file}->messages){
                next if ($mtags{$msg} != $i);
                next unless $self->isvalid($msg);
                print "Xval: " . $msg->subject() . "\n" if ($self->{options}{debug} >= 5); 
                my ($rv, $p) = $self->score($msg);
                if ( $p >= $opts->{threshold}) {
                    $mresults{$cat}{$rv} += 1;
                } else {
                    $mresults{$cat}{UNK} += 1;
                }
                printf("\tResult: %s,%.2f\n", $rv, $p) if ($self->{options}{debug} >= 5);
            }
        }
    }
    $mgr->closeAllFolders;
    return %mresults;
}
                
=item I<tagmsg> OPTIONS

I<tagmsg> takes a Mail::Message object and adds a header with all categories with likelihood 
over a threshold, returns a new Mail::Message object.  Any previous headers of 
that type are deleted prior to the tagging.

    $bb->tagmsg(   {    'msg' => $msg,
                        'threshold' =>  .9,
                        'header' => 'X-Mail-Classifier' } );

=item I<tagmbox> OPTIONS
    
I<tagmbox> is like I<tagmsg>, but tags an entire mailbox given by FILENAME.

    $bb->tagmbox(   {   'mailbox' => '/home/fred/mbox',
                        'threshold' =>  .9,
                        'header' => 'X-Mail-Classifier' } );

=cut     

sub tagmsg { 
    my ($self, $args) = @_;
    confess "Bad arguments to tagmsg()"
        unless ($args->{msg} and $args->{threshold} and $args->{header});
    $args->{msg}->head->delete($args->{header});
    my %probs = $self->score($args->{msg});
    foreach my $key ( keys %probs ) {
        if ( $probs{$key} >= $args->{threshold} ) {
            $args->{msg}->head->add("$args->{header}: $key");
        }
    }

}

sub tagmbox {
    my ($self, $args) = @_;
    confess "Bad arguments to tagmbox()"
        unless ($args->{mailbox} and $args->{threshold} and $args->{header});
    my $mgr = Mail::Box::Manager->new;
    $mgr->defaultTrace('NONE') unless $self->{options}{debug};
    my $mbox = $mgr->open($args->{mailbox}, access=>'rw') 
        or confess "Can't open mailbox '$args->{mailbox}': $!";
    foreach my $msg ($mbox->messages) {
        $self->tagmsg($msg, $args);
    }
    $mbox->write;       # Avoids a bug in certain versions of Mail::Box
    $mbox->close;       
}
 
=item I<save> FILENAME

Dump the entire classifier to a Perl Storable file, given by FILENAME.  

    $bb->save("/tmp/saved-classifier");
    
=cut

sub save {
    my ($self, $filename) = @_;
    # Lock all the data tables to ensure a clean copy
    $self->LockAll;
    lock_nstore($self,$filename);
	$self->UnLockAll;
}

=item I<setparse> FUNCTION-REFERENCE    

B<DEPRECATED>: Used to optionally set an external function for parsing.
Now, use of a separate parser should be done by subclassing and overriding
the parsing function.

=cut

=item I<saveconfig> FILENAME

Save configuration options only into a textfile
    
    $bb->saveconfig('/tmp/options-only.txt/');

=cut

sub saveconfig {
    my ($self, $filename) = @_;
    open (CFG, ">$filename") or confess "Can't open $filename: $!";
    my $date = localtime;
    print CFG "# Mail::Classifier options file created $date\n";
    while ( my ($key, $val) = each %{$self->{options}} ) {
        print CFG "$key=$val\n";
    }
    close CFG or confess "Can't close $filename: $!";
}

=item I<loadconfig> FILENAME

Load configuration options from a file.  Options are KEY=VALUE
pairs.  Comments (using '#') and lines with leading whitespace are
ignored.  Will clobber existing options with the same name.

    $bb->loadconfig('/tmp/options-only.txt');

=cut

sub loadconfig {
    my ($self, $filename) = @_;
    open (CFG, "<$filename") or confess "Can't open $filename: $!";
    flock CFG, LOCK_SH;
    while ( <CFG> ) {
        chomp;
        s/#.*//;
        s/^\s+//;
        s/\s+$//;
        next unless length;
        my ($var, $value) = split(/\s*=\s*/, $_, 2);
        $self->{options}{$var} = $value;
    }
    close CFG;
}

=item I<setconfig> HASHREF

Sets parameters controlling how messages are processed
(e.g. thresholds, defaults probs, caps/floors, etc.).  
This will clobber existing options so use with caution 
or override to check and handle appropriately

    $bb->setconfig( { option1 => 'foo', option2 => 'bar' });

=cut

sub setconfig {
    my ($self, $vars) = @_;

    while ( my ($key, $val) = each %{$vars} ) {
        $self->{options}{$key}=$val;
    } 
}

=item I<debug> [INTEGER]

Accessor to get/set debug level 

    $bb->debug(1);
    print "stuff" if ($bb->debug);
    
The stub parent uses the following levels:

    0: no debugging info
    1: basic flow info
    5: detailed message-level info
 
=cut

sub debug {
    my ( $self, $level) = @_;
    defined $level and $self->{options}{debug}=$level; 
    return $self->{options}{debug};
}
                
=head1 INTERNAL METHODS

These methods should not be called by the end-user, but are listed as a
reference for developers subclassing this file.

    * _add_data_table
    * _load_from_file
    * _clone
    * Lock/ReadLock/Unlock/LockAll/UnLockAll
    * DESTROY

=item I<_add_data_table> HASHNAME [STORE-ON-DISK-FLAG]

Internal function to add a hash reference to $self object for data storage.  If 
STORE-ON-DISK is true, then a temporary datafile is created with MLDBM::Sync,
using MLDBM::Sync::SDBM_File as the underlying datastore and Storable as 
the data freezing method. Data structures created with this function will be 
appropriately saved/loaded/locked by other methods.  This method will check to
ensure existing class members are not overwritten.  Note:  Using temporary disk
files can be B<exceedingly> slow.  Use with caution (until I implement a more
efficient solution).

    $bb->_add_data_table('cache');
    $bb->_add_data_table('words', 1);
    $bb->{words}{perl} = [ 1, 2, 3 ];
    
=cut

sub _add_data_table {
    my ($self, $hashname, $store) = @_;
    if ( exists $self->{$hashname} ) { 
        confess "Data table $hashname conflicts with existing element."; 
    }
    $self->{$hashname} = {};
    return unless $store;
    my (undef, $fn) = File::Temp::tempfile();
    tie %{$self->{$hashname}},'MLDBM::Sync', $fn, O_RDWR|O_CREAT, 0640
        or confess "Can't tie datafile $hashname: $!";
    unless ( exists $self->{filenames} ) { $self->_add_data_table('filenames') }
    $self->{filenames}{$hashname} = $fn;
}

=item I<_load_from_file> FILENAME

Load the classifier from a file, overwriting $self.  Internal function called
from new.

    $self->_load_from_filename('/tmp/saved-classifier');

=cut

sub _load_from_file {
    my ($self, $filename) = @_;
    $self = lock_retrieve($filename);
    # Now figure out which tables are supposed to be cached and cache them
	# while storing new scratch filenames into a fresh hash 
	my $cachedfiles = $self->{filenames};
    delete $self->{filenames};
	$self->_add_data_table('filenames');
    foreach my $key ( keys %{$self} ) {
        next unless exists($cachedfiles->{$key});
		my (undef, $fn) = File::Temp::tempfile();
		tie %{$self->{$key}},'MLDBM::Sync', $fn, O_RDWR|O_CREAT, 0640
			or confess "Can't tie datafile $key: $!";
		$self->{filenames}{$key} = $fn;
    }
	return $self;
}

=item I<_clone> OBJECT

Clones a classifier/hash's options and data into a new object and returns the new
object. Locking of the source OBJECT should be done B<outside> this call.

    $cc = $bb->_clone( $bb );
    
=cut

sub _clone {
    my ($self, $href) = @_;
    my $newobj = {};
    bless($newobj, ref($self) || $self);
    foreach my $key ( keys %{$href} ) {
        next if $key eq 'filenames';  # don't clone the filenames entry 
        $newobj->_add_data_table($key, exists($href->{filenames}{$key}) );
        $newobj->Lock($key);
        $newobj->{$key} = { %{$href->{$key}} };
        $newobj->UnLock($key);
    }
    return $newobj;
}

=item I<DESTROY>

Destructor function -- shouldn't be called by users. Blows away the 
temporary files when the object is done.

=cut 

sub DESTROY {
    my $self = shift;
    while ( my ($key, $val) = each %{$self->{filenames}} ) {
        unlink $val, "$val.pag", "$val.dir", "$val.lock";
    }
}

=item I<Lock> HASHNAME

=item I<ReadLock> HASHNAME

=item I<UnLock> HASHNAME

=item I<LockAll>

=item I<UnLockAll>

Wrappers around MLDBM::Sync locking calls.  Manages locking on the data hash 
given in HASHNAME.  This will do nothing but is still safe if the hash only 
lives in memory and is not tied.

    $self->Lock('words')      # r/w-lock on $self->{words} 
    $self->ReadLock('words')  # read-lock on $self->{words}
    $self->UnLock('words')    # unlocks $self->{words}

    $self->LockAll;            # Locks all data tables for $self
    $self->UnLockAll;          # UnLocks all data tables for $self
        
=cut

sub Lock { 
    my ($self, $hashname) = @_;
    my $tiedobj = tied %{$self->{$hashname}};
    $tiedobj && $tiedobj->Lock;
}

sub ReadLock { 
    my ($self, $hashname) = @_;
    my $tiedobj = tied %{$self->{$hashname}};
    $tiedobj && $tiedobj->ReadLock;
}

sub UnLock { 
    my ($self, $hashname) = @_;
    my $tiedobj = tied %{$self->{$hashname}};
    $tiedobj && $tiedobj->UnLock;
}

sub LockAll {
    my ($self) = @_;
    foreach my $key ( keys %{$self} ) {
        $self->Lock($key) if ref($self->{$key}) eq 'HASH';
    }
}
 
sub UnLockAll {
    my ($self) = @_;
    foreach my $key ( keys %{$self} ) {
        $self->UnLock($key) if ref($self->{$key}) eq 'HASH';
    }
}

1;
__END__

######## END OF CODE #####################

=back

=head1 PREREQUISITES

    MLDBM 
    MLDBM::Sync
    File::Copy
    Mail::Box
    Mail::Address
    File::Temp
    File::Spec

=head1 BUGS

There are always bugs...

=head1 SEE ALSO

For more on cross-validation, see "An Introduction to 
the Bootstrap" by Efron and Tibshirani (1998), p. 239.

Inspiration for this kind of spam classification came from the article "A Plan
For Spam" by Paul Graham: http://www.paulgraham.com/spam.html

For a specific implementation of Paul Graham's algorithm, see 
Mail::SpamTest::Bayesian

Another module of this type, though not integrated with mailbox processing, is 
AI::Categorizer.

For a public corpus of spam and non-spam for testing, see the SpamAssassin
site:  http://spamassassin.org/publiccorpus/

=head1 AUTHOR

David Golden, E<lt>david@hyperbolic.netE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright 2002 and 2003 by David Golden

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself. 

=cut
