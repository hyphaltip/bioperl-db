#!/usr/local/bin/perl
#
# $Id$
#

=head1 NAME 

load_seqdatabase.pl

=head1 SYNOPSIS

   load_seqdatabase.pl -host somewhere.edu -dbname biosql \
                       -namespace bioperl -format swiss \
                       swiss_sptrembl swiss.dat primate.dat

=head1 DESCRIPTION

This script loads a bioperl-db with sequences. There are a number of
options to do with where the bioperl-db database is (ie, hostname,
user for database, password, database name) followed by the database
name you wish to load this into and then any number of files. The
files are assumed formatted identically with the format given in the
-format flag.

There are more options than the ones shown above. See below.

=head1 ARGUMENTS

  The arguments after the named options constitute the filelist. If
  there are no such files, input is read from stdin. Mandatory options
  are marked by (M). Default values for each parameter are shown in
  square brackets.  (Note that -bulk is no longer available):

=over 2 

=item --host $URL

the host name or IP address incl. port [localhost]

=item --dbname $db_name

the name of the schema [biosql]

=item --dbuser $username

database username [root]

=item --dbpass $password

password [undef]

=item --driver $driver

the DBI driver name for the RDBMS e.g., mysql, Pg, or Oracle [mysql]

=item --namespace $namesp 

The namespace under which the sequences in the input files are to be
created in the database [bioperl]. Note that the namespace will be
left untouched if the object to be submitted has it set already.

=item --lookup

flag to look-up by unique key first, converting the insert into an
update if the object is found

=item --noupdate

don't update if object is found (with --lookup)

=item --remove

flag to remove sequences before actually adding them (this
necessitates a prior lookup)

=item --safe

flag to continue despite errors when loading (the entire object
transaction will still be rolled back)

=item --testonly 

don't commit anything, rollback at the end

=item --format

This may theoretically be any IO subsytem and the format understood by
that subsystem to parse the input file(s). IO subsytem and format must
be separated by a double colon. See below for which subsystems are
currently supported.

The default IO subsystem is SeqIO. 'Bio::' will automatically be
prepended if not already present. As of presently, the other supported
subsystem is ClusterIO. All input files must have the same format.

Examples: 
    # this is the default
    --format genbank  
    # SeqIO format EMBL
    --format embl     
    # Bio::ClusterIO stream with -format => 'unigene'
    --format ClusterIO::unigene 

=item --fmtargs

Use this argument to specify initialization parameters for the parser
for the input format. The argument value is expected to be a string
with parameter names and values delimited by comma.

Usually you will want to protect the argument list from interpretation
by the shell, so surround it with double or single quotes.

Examples:

    # turn parser exceptions into warnings (don't try this at home)
    --fmtargs "-verbose,-1"
    # verbose parser with an additional path argument
    --fmtargs "-verbose,1,-indexpath,/home/luke/warp"

=item --pipeline

This is a sequence of L<Bio::Factory::SeqProcessorI> implementing
objects that will be instantiated and chained in exactly this
order. This allows you to write re-usable modules for custom
post-processing of objects after the stream parser returns
them. Cf. L<Bio::Seq::BaseSeqProcessor> for a base implementation for
such modules.

Modules are separated by the pipe character '|'. In addition, you can
specify initialization parameters for each of the modules by enclosing
a comma-separated list of alternating parameter name and value pairs
in parentheses or angle brackets directly after the module.

Examples: 
    # one module
    --pipeline "My::SeqProc" 
    # two modules in the specified order
    --pipeline "My::SeqProc|My::SecondSeqProc" 
    # two modules, the first of which has two initialization parameters
    --pipeline "My::SeqProc(-maxlength,1500,-minlength,300)|My::SecondProc"

=item --seqfilter

This is either a string or a file defining a closure to be used as
sequence filter. The value is interpreted as a file if it refers to a
readable file, and a string otherwise. Cf. add_condition() in
L<Bio::Seq::SeqBuilder> for more information about what the code will
be used for. The closure will be passed a hash reference with an
accumulated list of initialization paramaters for the prospective
object. It returns TRUE if the object is to be built and FALSE
otherwise.

Note that this closure operates at the stream parser level. Objects it
rejects will be skipped by the parser. Objects it accepts can still be
intercepted at a later stage (options --remove, --update, --noupdate,
--mergeobjs).

Note that not necessarily all stream parsers support a
L<Bio::Factory::ObjectBuilderI> object. Email bioperl-l@bioperl.org to
find out which ones do. In fact, at the time of writing this, only
Bio::SeqIO::genbank supports it.

=item --mergeobjs

This is also a string or a file defining a closure. If provided, the
closure is called if a look-up for the unique key of the new object
was successful (hence, it will never be called without supplying
--lookup, but not --noupdate, at the same time).

The closure will be passed three (3) arguments: the object found by
lookup, the new object to be submitted, and the L<Bio::DB::DBAdaptorI>
implementing object for the desired database. If the closure returns a
value, it must be the object to be inserted or updated in the database
(if $obj->primary_key returns a value, the object will be updated). If
it returns undef, the script will skip to the next object in the input
stream.

The purpose of the closure can be manifold. It was originally
conceived as a means to customarily merge attributes or associated
objects of the new object to the existing (found) one in order to
avoid duplications but still capture additional information (e.g.,
annotation). However, there is a multitude of other operations it can
be used for, like physically deleting or altering certain associated
information from the database (the found object and all its associated
objects will implement L<Bio::DB::PersistentObjectI>). Since the third
argument is the persistent object and adaptor factory for the
database, there is literally no limit as to the database operations
the closure could possibly do.

=item more args

The remaining arguments will be treated as files to parse and load. If
there are no additional arguments, input is expected to come from
standard input.

=back

=head1 Authors

=head1 Contributors

Hilmar Lapp E<lt>hlapp at gmx.netE<gt>

=cut


use Getopt::Long;
use Bio::Root::Root;
use Bio::DB::BioDB;
use Bio::Annotation::SimpleValue;
use Bio::SeqIO;
use Bio::ClusterIO;
use Symbol;

####################################################################
# Defaults for options changeable through command line
####################################################################
my $host; # should make the driver to default to localhost
my $dbname = "biosql";
my $dbuser = "root";
my $driver = 'mysql';
my $dbpass;
my $format = 'genbank';
my $fmtargs = '';
my $namespace = "bioperl";
my $seqfilter;           # see conditions in Bio::Seq::SeqBuilder
my $mergefunc;           # if and how to merge old (found) and new objects
my $pipeline;            # see Bio::Factory::SequenceProcessorI
# flags
my $remove_flag = 0;     # remove object before creating?
my $lookup_flag = 0;     # look up object before creating, update if found?
my $no_update_flag = 0;  # do not update if found on look up?
my $help = 0;            # WTH?
my $debug = 0;           # try it ...
my $testonly_flag = 0;   # don't commit anything, rollback at the end?
my $safe_flag = 0;       # tolerate exceptions on create?
####################################################################
# Global defaults or definitions not changeable through commandline
####################################################################

#
# map of I/O type to the next_XXXX method name
#
my %nextobj_map = (
		   'Bio::SeqIO'     => 'next_seq',
		   'Bio::ClusterIO' => 'next_cluster',
		   );

####################################################################
# End of defaults
####################################################################

#
# get options from commandline 
#
my $ok = GetOptions( 'host:s'      => \$host,
		     'driver:s'    => \$driver,
		     'dbname:s'    => \$dbname,
		     'dbuser:s'    => \$dbuser,
		     'dbpass:s'    => \$dbpass,
		     'format:s'    => \$format,
		     'fmtargs=s'   => \$fmtargs,
		     'seqfilter:s' => \$seqfilter,
		     'namespace:s' => \$namespace,
		     'pipeline:s'  => \$pipeline,
		     'mergeobjs:s' => \$mergefunc,
		     'safe'        => \$safe_flag,
		     'remove'      => \$remove_flag,
		     'lookup'      => \$lookup_flag,
		     'noupdate'    => \$no_update_flag,
		     'debug'       => \$debug,
		     'testonly'    => \$testonly_flag,
		     'h'           => \$help,
		     'help'        => \$help
		     );

if((! $ok) || $help) {
    if(! $ok) {
	print STDERR "missing or unsupported option(s) on commandline\n";
    }
    system("perldoc $0");
    exit($ok ? 0 : 2);
}

#
# load and/or parse condition if supplied
#
my $condition = parse_code($seqfilter) if $seqfilter;

#
# load and/or parse object merge function if supplied
#
my $merge_objs = parse_code($mergefunc) if $mergefunc;

#
# determine input source(s)
#
my @files = @ARGV ? @ARGV : (\*STDIN);

#
# determine input format and type
#
my $objio;
my @fmtelems = split(/::/, $format);
if(@fmtelems > 1) {
    $format = pop(@fmtelems);
    $objio = join('::', @fmtelems);
} else {
    # default is SeqIO
    $objio = "SeqIO";
}
$objio = "Bio::".$objio if $objio !~ /^Bio::/;
my $nextobj = $nextobj_map{$objio} || "next_seq"; # next_seq is the default
# the format might come with argument specifications
my @fmtargs = split(/\s*,\s*/,$fmtargs);

#
# setup the pipeline if desired
#
my @pipemods = ();
if($pipeline) {
    if($objio ne "Bio::SeqIO") {
	die "pipelining sequence processors not supported for non-SeqIOs\n";
    }
    @pipemods = setup_pipeline($pipeline);
    warn "you specified -pipeline, but no processor modules resulted\n"
	unless @pipemods;
}

#
# create the DBAdaptorI for our database
#
my $db = Bio::DB::BioDB->new(-database => "biosql",
			     -host     => $host,
			     -dbname   => $dbname,
			     -driver   => $driver,
			     -user     => $dbuser,
			     -pass     => $dbpass,
			     );
$db->verbose($debug) if $debug > 0;

# declarations
my ($pseq);

#
# loop over every input file and load its content
#
foreach $file ( @files ) {
    
    my $fh = $file;
    my $seqin;

    # create a handle if it's not one already
    if(! ref($fh)) {
	$fh = gensym;
	if(! open($fh, "<$file")) {
	    warn "unable to open $file for reading, skipping: $!\n";
	    next;
	}
	print STDERR "Loading $file ...\n";
    }
    # create stream
    $seqin = $objio->new(-fh => $fh,
			 $format ? (-format => $format) : (),
			 @fmtargs);

    # establish filter if provided
    if($condition) {
	if(! $seqin->can('sequence_builder')) {
	    $seqin->throw("object IO parser ".ref($seqin).
			  " does not support control by ObjectBuilderIs");
	}
	$seqin->sequence_builder->add_object_condition($condition);
    }

    # chain to pipeline if pipelining is requested
    if(@pipemods) {
	$pipemods[0]->source_stream($seqin);
	$seqin = $pipemods[$#pipemods];
    }

    # adaptor - we'll set this on demand
    my $adp;

    # loop over the stream
    while( my $seq = $seqin->$nextobj ) {
	# we can't store the structure for structured values yet, so
	# flatten them
	if($seq->isa("Bio::AnnotatableI")) {
	    flatten_annotations($seq->annotation);
	}
	# don't forget to add namespace if the parser doesn't supply one
	$seq->namespace($namespace) unless $seq->namespace();
	# look up or delete first?
	my ($lseq);
	if($lookup_flag || $remove_flag) {
	    # look up
	    #$lseq = clone_identifiable($seq, $seqin->object_factory());
	    my $adp = $db->get_object_adaptor($seq);
	    $lseq = $adp->find_by_unique_key($seq,
					     -obj_factory =>
					     $seqin->object_factory());
	    # found?
	    if($lseq) {
		# delete if requested
		$lseq->remove() if $remove_flag;
		# skip the rest if we are not supposed to update
		next if $no_update_flag;
		# merge old and new if a function for this is provided
		$seq = &$merge_objs($lseq, $seq, $db) if $merge_objs;
		# the return value may indicate to skip to the next
		next unless $seq;
	    }
	}
	# create a persistent object out of the seq
	$pseq = $db->create_persistent($seq);
	# store the primary key of we found it by lookup (this is going to
	# be an udate then)
	if($lseq && $lseq->primary_key) {
	    $pseq->primary_key($lseq->primary_key);
	}
	# try to serialize
	eval {
	    $pseq->store();
	    $pseq->commit() unless $testonly_flag;
	};
	if ($@) {
	    my $msg = "Could not store ".$seq->object_id().": $@\n";
	    $pseq->rollback();
	    if($safe_flag) {
		$pseq->warn($msg);
	    } else {
		$pseq->throw($msg);
	    }
	}
    }
    $seqin->close();
}

$pseq->rollback() if $pseq && $testonly_flag;

# done!

#################################################################
# Implementation of functions                                   #
#################################################################

sub parse_code{
    my $src = shift;
    my $code;

    # file or subroutine?
    if(-r $src) {
	if(! (($code = do $src) && (ref($code) eq "CODE"))) {
	    die "error in parsing code block $src: $@" if $@;
	    die "unable to read file $src: $!" if $!;
	    die "failed to run $src, or it failed to return a closure";
	}
    } else {
	$code = eval $src;
	die "error in parsing code block \"$src\": $@" if $@;
	die "\"$src\" fails to return a closure"
	    unless ref($code) eq "CODE";
    }
    return $code;
}

sub setup_pipeline{
    my $pipeline = shift;
    my @pipemods = ();

    # split into modules
    my @mods = split(/\|/, $pipeline);
    # instantiate a module 'loader'
    my $loader = Bio::Root::Root->new();
    # load and instantiate each one, then concatenate
    foreach my $mod (@mods) {
	# separate module name from potential arguments
	my $modname = $mod;
	my @modargs = ();
	if($modname =~ /^(.+)[\(<](.*)[>\)]$/) {
	    $modname = $1;
	    @modargs = split(/,/, $2);
	}
	$loader->_load_module($modname);
	my $proc = $modname->new(@modargs);
	if(! $proc->isa("Bio::Factory::SequenceProcessorI")) {
	    die "Pipeline processing module $modname does not implement ".
		"Bio::Factory::SequenceProcessorI. Bummer.\n";
	}
	$proc->source_stream($pipemods[$#pipemods]) if @pipemods;
	push(@pipemods, $proc);
    }
    return @pipemods;
}

sub clone_identifiable{
    my ($obj, $fact) = @_;

    my $newobj = $fact->create_object(-object_id => $obj->object_id,
				      -version   => $obj->version,
				      -namespace => $obj->namespace,
				      -authority => $obj->authority);
    if(! $newobj->isa("Bio::IdentifiableI")) {
	die "trouble: factory class ".ref($fact)." does not create ".
	    "Bio::IdentifiableI compliant objects. Bad.\n";
    }
    if($newobj->can('primary_id') &&
       ($obj->primary_id() !~ /=(HASH|ARRAY)\(0x/)) {
	$newobj->primary_id($obj->primary_id());
    }
    return $newobj;
}

sub flatten_annotations {
    my $anncoll = shift;
    foreach my $ann ($anncoll->remove_Annotations()) {
	if($ann->isa("Bio::Annotation::StructuredValue")) {
	    foreach my $val ($ann->get_all_values()) {
		$anncoll->add_Annotation(Bio::Annotation::SimpleValue->new(
					   -value => $val,
					   -tagname => $ann->tagname()));
	    }
	} else {
	    $anncoll->add_Annotation($ann);
	}
    }
}