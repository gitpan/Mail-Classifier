use 5.008;
use ExtUtils::MakeMaker;
# See lib/ExtUtils/MakeMaker.pm for details of how to influence
# the contents of the Makefile that is written.
WriteMakefile(
    'NAME'		=> 'Mail::Classifier',
    'VERSION_FROM'	=> 'Classifier.pm', # finds $VERSION
    'PREREQ_PM'		=> {    Mail::Box => 2.033,
                                MLDBM::Sync => 0.30,
                                MLDBM => 0,
                                MLDBM::Sync => 0,
                                File::Copy => 0,
                                Mail::Box => 0,
								Mail::Box::Manager => 0,
                                Mail::Address => 0,
								Storable => 0,
                                File::Temp => 0,
                                File::Spec => 0,
					   			HTML::Strip => 1.01,
								HTML::Entities => 1.27,
								Statistics::Distributions => 1.02		},
    ($] >= 5.005 ?    ## Add these new keywords supported since 5.005
      (ABSTRACT_FROM => 'Classifier.pm', # retrieve abstract from module
       AUTHOR     => 'David Golden <david@hyperbolic.net>') : ()),
);
