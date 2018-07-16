#!/usr/bin/env perl
#
#-------------------------------------------------------------------------------
# Copyright (c) 2014-2018 René Just, Darioush Jalali, and Defects4J contributors.
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.
#-------------------------------------------------------------------------------

=pod

=head1 NAME

fix_test_suite.pl -- remove failing tests from test suite until all tests pass.

=head1 SYNOPSIS

  fix_test_suite.pl -p project_id -d suite_dir [-f include_file_pattern] [-v version_id] [-s test_suite_src] [-t tmp_dir] [-A] [-D] [-L]

=head1 OPTIONS

=over 4

=item -p C<project_id>

The id of the project for which the generated test suites are analyzed.
See L<Project|Project/"Available Project IDs"> module for available project IDs.

=item -d F<suite_dir>

The directory that contains the test suite archives.
See L<Test suites|/"Test suites">.

=item -f C<include_file_pattern>

The pattern of the file names of the test classes that should be included (optional).
Per default all files (*.java) are included.

=item -v C<version_id>

Only analyze test suites for this version id (optional). Per default all
test suites for the given project id are analyzed.

=item -s C<test_suite_src>

Only analyze test suites originating from this source (optional).
A test suite source is a specific tool or configuration (e.g., evosuite-branch).
Per default all test suite sources for the given project id are considered.

=item -t F<tmp_dir>

The temporary root directory to be used to check out program versions (optional).
The default is F</tmp>.

=item -A

Assertions: Try to remove failing assertions first, before removing the entire
test method (optional). By default failing test methods are entirely removed.

=item -D

Debug: Enable verbose logging and do not delete the temporary check-out directory
(optional).

=item -L

Logging: Enable logging of runtime information (optional). By default no database
is used to keep the runtime information generated by this script.

=back

=head1 DESCRIPTION

Runs the following worflow for each provided test suite (i.e., each test suite
archive in F<suite_dir>):

=over 4

=item 1) Remove uncompilable test classes until the test suite compiles.

=item 2) Run test suite and monitor failing tests -- remove failing test methods
         and repeat until:


=over 4

=item * The entire test suite passes 5 times in a row.

=cut
my $RUNS = 5;

=pod

=item * Each test method passes in isolation (B<TODO: not yet implemented!>).

=back

=back

If a test suite was fixed, its original archive is backed up and replaced with
the fixed version. The results of the fix are stored in the database table
F<suite_dir/L<TAB_FIX|DB>>.

=cut
use warnings;
use strict;

use FindBin;
use File::Basename;
use Cwd qw(abs_path);
use Getopt::Std;
use Pod::Usage;

use lib abs_path("$FindBin::Bin/../core");
use Constants;
use Project;
use Utils;
use Log;

#
# Process arguments and issue usage message if necessary.
#
my %cmd_opts;
getopts('p:d:v:s:t:f:ADL', \%cmd_opts) or pod2usage(1);

pod2usage(1) unless defined $cmd_opts{p} and defined $cmd_opts{d};

my $SUITE_DIR = abs_path($cmd_opts{d});
my $PID = $cmd_opts{p};
my $VID = $cmd_opts{v} if defined $cmd_opts{v};
my $TEST_SRC = $cmd_opts{s} if defined $cmd_opts{s};
my $INCL = $cmd_opts{f} // "*.java";
my $RM_ASSERTS = defined $cmd_opts{A} ? 1 : 0;
# Enable debugging if flag is set
$DEBUG = 1 if defined $cmd_opts{D};
my $DB_LOGGING = defined $cmd_opts{L} ? 1 : 0;

# Check format of target version id
if (defined $VID) {
    Utils::check_vid($VID);
}

# Enable verbose logging (DB module) if flag is set; by default DB is not used.
my $dbh_out;
my $sth;
my @COLS;
if ($DB_LOGGING) {
    require DB;
    import DB;

    # Get database handle for result table
    $dbh_out = DB::get_db_handle($DB::TAB_FIX, $SUITE_DIR);

    $sth = $dbh_out->prepare("SELECT * FROM $DB::TAB_FIX WHERE $DB::PROJECT=? AND $DB::TEST_SUITE=? AND $DB::ID=? AND $DB::TEST_ID=?")
            or die $dbh_out->errstr;

    # Cache column names for table fix
    @COLS = DB::get_tab_columns($DB::TAB_FIX) or die "Cannot obtain table columns!";
}

=pod

=head2 Test Suites

To be considered for the analysis, a test suite has to be provided as an archive in
F<suite_dir>. Format of the archive file name:

C<project_id-version_id-test_suite_src(\.test_id)?\.tar\.bz2>

Note that C<test_id> is optional, the default is 1.

Examples:

=over 4

=item * F<Lang-11f-randoop.1.tar.bz2 (equal to Lang-1-randoop.tar.bz2)>

=item * F<Lang-11b-randoop.2.tar.bz2>

=item * F<Lang-12b-evosuite-weakmutation.1.tar.bz2>

=item * F<Lang-12f-evosuite-branch.1.tar.bz2>

=back

=cut
my @list;
opendir(DIR, $SUITE_DIR) or die "Could not open directory: $SUITE_DIR!";
my @entries = readdir(DIR);
closedir(DIR);
foreach (@entries) {
    next unless /^([^-]+)-(\d+[bf])-([^\.]+)(\.(\d+))?\.tar\.bz2$/;
    my $pid = $1;
    my $vid = $2;
    my $src = $3;
    my $tid = ($5 or "1");
    # Check whether target pid matches
    next if ($PID ne $pid);
    # Check whether a target src is defined
    next if defined($TEST_SRC) and ($TEST_SRC ne $src);
    # Check whether a target version_id is defined
    next if defined($VID) and ($VID ne $vid);

    push (@list, {name => $_, pid => $pid, vid=>$vid, src=>$src, tid=>$tid});
}

# Set up project
my $TMP_DIR = Utils::get_tmp_dir($cmd_opts{t});
system("mkdir -p $TMP_DIR");


=pod

=head2 Logging

This script logs all test-compilation steps information to fix_test_suite.compile.log,
all test-execution steps to fix_test_suite.run.log, and it also logs summary
information (e.g., how many tests were removed) to fix_test_suite.summary.log
in the test suite directory F<SUITE_DIR>.

=cut
my $COMPILE_LOG = Log::create_log("$SUITE_DIR/fix_test_suite.compile.log");
my $RUN_LOG     = Log::create_log("$SUITE_DIR/fix_test_suite.run.log");
my $SUMMARY_LOG = Log::create_log("$SUITE_DIR/fix_test_suite.summary.log");

# Line separator
my $sep = "-"x80;

# Log current time
$SUMMARY_LOG->log_time("Start fixing tests");
$SUMMARY_LOG->log_msg("- Found " . scalar(@list) . " test archive(s)");

suite: foreach (@list) {
    my $name = $_->{name};
    my $pid  = $_->{pid};
    my $vid  = $_->{vid};
    my $src  = $_->{src};
    my $tid  = $_->{tid};
    my $project = Project::create_project($pid);
    $project->{prog_root} = $TMP_DIR;

    if (defined $sth) {
        # Skip existing entries
        $sth->execute($pid, $src, $vid, $tid);
        if ($sth->rows != 0) {
            $SUMMARY_LOG->log_msg(" - Skipping $name since results already exist in database!");
            next;
        }
    }

    my $num_failing_tests = 0;
    my $num_uncompilable_tests = 0;
    my $num_uncompilable_test_classes = 0;

    printf ("$sep\n$name\n$sep\n");

    $project->checkout_vid($vid);

    # Extract generated tests into temp directory
    Utils::extract_test_suite("$SUITE_DIR/$name", "$TMP_DIR/$src")
        or die "Cannot extract test suite!";

    # Counter for successful runs of fixed test suite
    my $counter = $RUNS;

    my $fixed = 0;
    while ($counter > 0) {
        # Temporary log file to monitor uncompilable tests
        my $comp_log = Log::create_log("$TMP_DIR/comp_tests.log", ">")->{file_name};

        # Check for compilation errors
        if (! $project->compile_ext_tests("$TMP_DIR/$src", $comp_log)) {
            $COMPILE_LOG->log_file("- Compilation issues: $name", $comp_log);
            my ($n_uncompilable_tests, $n_uncompilable_test_classes) = _rm_classes($comp_log, $src, $name);
            # Update counters
            $num_uncompilable_tests += $n_uncompilable_tests;
            $num_uncompilable_test_classes += $n_uncompilable_test_classes;
            # Indicate that test suite changed
            $fixed = 1;
            next;
        }

        # Temporary log file to monitor failing tests
        my $tests = Log::create_log("$TMP_DIR/run_tests.log", ">")->{file_name};

        # Check for errors of runtime system
        if (! $project->run_ext_tests("$TMP_DIR/$src", "$INCL", $tests)) {
            $SUMMARY_LOG->log_file(" - Tests not executable: $name", $tests);
            _insert_row($pid, $vid, $src, $tid);
            next suite;
        }

        # Check failing test classes and methods
        my $list = Utils::get_failing_tests($tests) or die;
        if (scalar(@{$list->{classes}}) != 0) {
            $SUMMARY_LOG->log_msg(" - Failing test classes: $name");
            $SUMMARY_LOG->log_msg(join("\n", @{$list->{classes}}));
            $SUMMARY_LOG->log_msg("Failing test classes are NOT automatically removed!");
            $SUMMARY_LOG->log_file("Stack traces:", $tests);
            #
            # TODO: Automatically remove failing test classes?
            #
            # This should be fine for generated test suites as
            # there are usually no compilation dependencies
            # between the individual test classes.
            #
            # However, a failing test class most probably indicates
            # a configuration issue, which should be fixed before
            # any broken test is removed.
            #
#            if (scalar(@{$list->{classes}}) != 0) {
#                foreach my $class (@{$list->{classes}}) {
#                    my $file = $class;
#                    $file =~ s/\./\//g;
#                    $file = "$TMP_DIR/$src/$file.java";
#                    system("mv $file $file.broken") == 0 or die "Cannot rename broken test class";
#                }
#                # Indicate that test suite changed
#                $fixed = 1;
#                next;
#            }
            _insert_row($pid, $vid, $src, $tid);
            next suite;
        }

        # No failing methods -> decrease counter and continue iteration
        if (scalar(@{$list->{methods}}) == 0) {
            --$counter;
            next;
        } else {
            $RUN_LOG->log_file(scalar(@{$list->{methods}}) . " broken test method(s): $name", $tests);

            # Reset counter and fix tests
            $counter = $RUNS;
            # Indicate that test suite changed
            $fixed = 1;
            $SUMMARY_LOG->log_msg(" - Removing " . scalar(@{$list->{methods}}) . " broken test method(s): $name");
            $SUMMARY_LOG->log_msg(join("\n", @{$list->{methods}}));
            Utils::exec_cmd("export D4J_RM_ASSERTS=$RM_ASSERTS && $UTIL_DIR/rm_broken_tests.pl $tests $TMP_DIR/$src", "Remove broken test method(s)")
                    or die "Cannot remove broken test method(s)";
            # Update counter
            $num_failing_tests += scalar(@{$list->{methods}});
        }
    }

    # TODO: Run test classes in isolation

    if ($fixed) {
        # Back up archive if necessary
        system("mv $SUITE_DIR/$name $SUITE_DIR/$name.bak") unless -e "$SUITE_DIR/$name.bak";
        system("cd $TMP_DIR/$src && tar -cjf $SUITE_DIR/$name *");
    }

    _insert_row($pid, $vid, $src, $tid, $num_uncompilable_tests, $num_uncompilable_test_classes, $num_failing_tests);
}
if (defined $dbh_out) {
    $dbh_out->disconnect();
}
# Log current time
$SUMMARY_LOG->log_time("End fixing tests");
$SUMMARY_LOG->close();
$COMPILE_LOG->close();
$RUN_LOG->close();

# Clean up
system("rm -rf $TMP_DIR") unless $DEBUG;

#
# Remove uncompilable test cases based on the compiler's log (if there
# is any issue non-related to any test case, the correspondent source
# file is removed)
#
sub _rm_classes {
    my ($comp_log, $src, $name) = @_;
    open(LOG, "<$comp_log") or die "Cannot read compiler log!";
    $SUMMARY_LOG->log_msg(" - Removing uncompilable test method(s): $name");
    my $num_uncompilable_test_classes = 0;
    my @uncompilable_tests = ();
    while (<LOG>) {
        my $removed = 0;

        # Find file names in javac's log: [javac] "path"/"file_name".java:"line_number": error: "error_text"
        next unless /javac.*($TMP_DIR\/$src\/(.*\.java)):(\d+):.*error/;
        my $file = $1;
        my $class = $2;
        my $line_number = $3;

        # Skip already removed files
        next unless -e $file;

        $class =~ s/\.java$//;
        $class =~ s/\//\./g;

        # To which test method does the uncompilable line belong?
        open(JAVA_FILE, $file) or die "Cannot open '$file' file!";
        my $test_name = "";
        my $line_index = 0;
        while (<JAVA_FILE>) {
            ++$line_index;
            next unless /public\s*void\s*(test.*)\s*\(\s*\).*/;
            my $t_name = $1;

            if ($line_index > $line_number) {
                last;
            }

            $test_name = $t_name;
            $removed = 1;
        }
        close(JAVA_FILE);

        if (! $removed) {
            # in case of compilation issues due to, for example, wrong
            # or non-existing imported classes, or problems with any
            # super class, the source file is removed
            $SUMMARY_LOG->log_msg($class);
            system("mv $file $file.broken") == 0 or die "Cannot rename uncompilable source file";

            # get rid of all test cases of this class that have been
            # selected to be removed
            @uncompilable_tests = grep ! /^--- ${class}::/, @uncompilable_tests;
            # Update counter
            ++$num_uncompilable_test_classes;
        } else {
            # e.g., '--- org.foo.BarTest::test09'
            my $test_canonical_name = "--- $class::$test_name";
            # Skip already selected (to be removed) test cases
            if (! grep{/^$test_canonical_name$/} @uncompilable_tests) {
                push(@uncompilable_tests, $test_canonical_name);
            }
        }
    }
    close(LOG);

    if (scalar(@uncompilable_tests) > 0) {
        # Write to a file the name of all uncompilable test cases (one per
        # line) and call 'rm_broken_tests.pl' to remove all of them
        my $uncompilable_tests_file_path = "$TMP_DIR/uncompilable-test-cases.txt";
        open my $uncompilable_tests_file, ">$uncompilable_tests_file_path" or die $!;
        print $uncompilable_tests_file join("\n", @uncompilable_tests);
        close($uncompilable_tests_file);

        $SUMMARY_LOG->log_file("  - Removing " . scalar(@uncompilable_tests) . " uncompilable test method(s):", $uncompilable_tests_file_path);
        Utils::exec_cmd("export D4J_RM_ASSERTS=$RM_ASSERTS && $UTIL_DIR/rm_broken_tests.pl $uncompilable_tests_file_path $TMP_DIR/$src", "Remove uncompilable test method(s)")
                or die "Cannot remove uncompilable test method(s)";
    }

    return (scalar(@uncompilable_tests), $num_uncompilable_test_classes);
}

#
# Insert row into database table.
#
sub _insert_row {
    @_ >= 4 or die $ARG_ERROR;
    my ($pid, $vid, $suite, $test_id, $num_uncompilable_tests, $num_uncompilable_test_classes, $num_failing_tests) = @_;

    $SUMMARY_LOG->log_msg("Number of uncompilable test classes: $num_uncompilable_test_classes" .
                    ($num_uncompilable_test_classes > 0 ? " (see $COMPILE_LOG->{file_name} file for more information)" : ""));
    $SUMMARY_LOG->log_msg("Number of uncompilable tests: $num_uncompilable_tests" .
                    ($num_uncompilable_tests > 0 ? " (see $COMPILE_LOG->{file_name} file for more information)" : ""));
    $SUMMARY_LOG->log_msg("Number of failing tests: $num_failing_tests" .
                    ($num_failing_tests > 0 ? " (see $RUN_LOG->{file_name} file for more information)" : ""));

    if (not defined $dbh_out) {
        return ; # explicitly do nothing
    }

    # Build data hash
    my $data = {
        $DB::PROJECT => $pid,
        $DB::ID => $vid,
        $DB::TEST_SUITE => $suite,
        $DB::TEST_ID => $test_id,
        $DB::NUM_UNCOMPILABLE_TESTS => $num_uncompilable_tests,
        $DB::NUM_UNCOMPILABLE_TEST_CLASSES => $num_uncompilable_test_classes,
        $DB::NUM_FAILING_TESTS => $num_failing_tests,
    };

    # Build row based on data hash
    my @tmp;
    foreach (@COLS) {
        push (@tmp, $dbh_out->quote((defined $data->{$_} ? $data->{$_} : "-")));
    }

    # Concat values and write to database table
    my $row = join(",", @tmp);

    $dbh_out->do("INSERT INTO $DB::TAB_FIX VALUES ($row)");
}
