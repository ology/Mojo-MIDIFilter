#!/usr/bin/env perl

# One filter, one process. This is filter.pl generalized to take every
# MIDI::RtController::Filter::CC attribute as a CLI option instead of
# hardcoding them, so the web app can spawn any number of these
# concurrently -- one per configured, started filter.
#
# Usage:
#   perl filter_runner.pl --input=joystick --output=usb --filter=breathe \
#        --channel=0 --control=50 --range_bottom=0 --range_top=127 \
#        --range_step=2 --time_step=0.25

use v5.36;
use curry;
use MIDI::RtController ();
use MIDI::RtController::Filter::CC ();
use Getopt::Long qw(GetOptions);

my %opt = (
    input   => 'joystick',
    output  => 'usb',
    filter  => 'breathe',
    verbose => 0,
);

GetOptions(\%opt,
    'input=s',
    'output=s',
    'filter=s',
    'channel=i',
    'control=i',
    'trigger=i',
    'value=i',
    'initial_point=i',
    'range_bottom=i',
    'range_top=i',
    'range_step=i',
    'time_step=f',
    'step_up=i',
    'step_down=i',
    'verbose!',
) or die "Bad options\n";

my $controller = MIDI::RtController->new(
    input   => $opt{input},
    output  => $opt{output},
    verbose => $opt{verbose},
);

my $filter = MIDI::RtController::Filter::CC->new(rtc => $controller);

# Only set attributes that were actually passed -- unset ones fall back to
# the module's own defaults, same as the commented-out lines in filter.pl.
$filter->channel($opt{channel})             if defined $opt{channel};
$filter->control($opt{control})             if defined $opt{control};
$filter->trigger($opt{trigger})             if defined $opt{trigger};
$filter->value($opt{value})                 if defined $opt{value};
$filter->initial_point($opt{initial_point}) if defined $opt{initial_point};
$filter->range_bottom($opt{range_bottom})   if defined $opt{range_bottom};
$filter->range_top($opt{range_top})         if defined $opt{range_top};
$filter->range_step($opt{range_step})       if defined $opt{range_step};
$filter->time_step($opt{time_step})         if defined $opt{time_step};
$filter->step_up($opt{step_up})             if defined $opt{step_up};
$filter->step_down($opt{step_down})         if defined $opt{step_down};

my $method = "curry::$opt{filter}";
$controller->add_filter($opt{filter}, all => $filter->$method);

# The web app stops us with SIGTERM (falling back to SIGKILL). Halt the
# filter cleanly first, same intent as filter.pl's END block, but reachable
# from a signal instead of only normal exit.
for my $sig (qw(TERM INT)) {
    $SIG{$sig} = sub {
        $filter->halt(1);
        exit;
    };
}

$controller->run;

END {
    $filter->halt(1);
}
