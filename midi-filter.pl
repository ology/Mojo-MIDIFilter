#!/usr/bin/env perl

# A control panel for running any number of MIDI::RtController::Filter::CC
# filters concurrently -- IN-PROCESS, using MIDI::RtController's own
# multi-filter support (see continuous.pl), rather than forking a separate
# OS process per filter. Filters that share an (input, output) port pair
# are attached to one shared MIDI::RtController instance via add_filters.
#
# IMPORTANT: because all MIDI I/O now lives inside this single process's
# event loop, this app MUST run with exactly one hypnotoad worker
# (workers => 1 in midi-filter.conf). Multiple workers would each try to
# open the same MIDI ports independently and process every event N times.

use v5.36;
use feature qw(try);
no warnings qw(experimental::try);

use Mojolicious::Lite -signatures;
use Mojo::IOLoop ();
use MIDI::RtMidi::FFI::Device ();
use MIDI::RtController ();
use MIDI::RtController::Filter::CC ();
use Storable qw(retrieve store);
use Fcntl qw(:flock);

use constant {
    STATE     => 'midi-filter-state.dat',
    STATELOCK => 'midi-filter-state.lock',
    SETS      => 'midi-filter-sets.dat',
    SETSLOCK  => 'midi-filter-sets.lock',
};

use constant FILTER_TYPES => qw(
    single clock_it breathe scatter stair_step ramp_up ramp_down flicker
);

use constant FIELDS => qw(
    name input output filter channel control trigger value
    initial_point range_bottom range_top range_step time_step
    step_up step_down verbose
);

# how often (seconds) to pump each live MIDI::RtController's event loop
use constant PUMP_INTERVAL => 0.005;

# --- persisted config: the list of configured filters (survives restarts) ---
my @filters;
my $next_id = 1;

# --- persisted config: named, saved snapshots of @filters ---
my %saved_sets;

# --- persisted: which filter ids should currently be running. Since
# starting/stopping no longer spawns/kills an OS process, it's safe (and
# useful) to persist this: a restarted server reattaches automatically. ---
my %running_ids;

# --- transient, per-process only: live MIDI::RtController instances,
# keyed by "$input\0$output" ---
my %controllers;

my %edit_filter; # single record being edited, mirrors phrase-generator's %edit_part

sub load_state () {
    return unless -e STATE;
    my $state = retrieve(STATE);
    @filters     = @{ $state->{filters} // [] };
    $next_id     = $state->{next_id} // 1;
    %running_ids = %{ $state->{running} // {} };
}

sub load_sets () {
    return unless -e SETS;
    my $data = retrieve(SETS);
    %saved_sets = %{ $data // {} };
}

# Runs $code with an exclusive lock held across the whole
# load -> mutate -> save cycle
sub with_filters_lock ($code) {
    open my $lock_fh, '>', STATELOCK or die "Can't open @{[STATELOCK]}: $!\n";
    flock($lock_fh, LOCK_EX) or die "Can't lock @{[STATELOCK]}: $!\n";

    load_state();
    $code->();
    save_state();

    close $lock_fh; # releases the lock
}

# Same pattern as with_filters_lock, but for the saved-sets store
sub with_sets_lock ($code) {
    open my $lock_fh, '>', SETSLOCK or die "Can't open @{[SETSLOCK]}: $!\n";
    flock($lock_fh, LOCK_EX) or die "Can't lock @{[SETSLOCK]}: $!\n";

    load_sets();
    $code->();
    save_sets();

    close $lock_fh; # releases the lock
}

sub save_state () {
    my $tmp = STATE . ".$$.tmp";
    store { filters => \@filters, next_id => $next_id, running => \%running_ids }, $tmp;
    rename $tmp, STATE or warn "Can't replace @{[STATE]}: $!\n";
}

sub save_sets () {
    my $tmp = SETS . ".$$.tmp";
    store \%saved_sets, $tmp;
    rename $tmp, SETS or warn "Can't replace @{[SETS]}: $!\n";
}

sub known_output_ports () {
    my $device = RtMidiOut->new;
    return [
        map { $device->get_port_name($_) }
            sort { $a <=> $b } keys $device->get_all_port_nums->%*
    ];
}

sub known_input_ports () {
    my $device = RtMidiIn->new;
    return [
        map { $device->get_port_name($_) }
            sort { $a <=> $b } keys $device->get_all_port_nums->%*
    ];
}

sub find_filter ($id) {
    return (grep { $_->{id} == $id } @filters)[0];
}

sub is_running ($id) {
    return $running_ids{$id} ? 1 : 0;
}

sub _port_key ($f) {
    return "$f->{input}\0$f->{output}";
}

# The library's own shutdown signal (see halt.pl): stopping a
# controller's loop is presumably what lets MIDI::RtController clean up
# its internal worker process in an orderly way, as it would when a
# blocking ->run() call returns naturally. We never call ->run()
# ourselves (we pump loop_once() instead), so we call this explicitly
# before discarding each controller.
sub _stop_controller ($controller) {
    eval { $controller->loop->loop_stop };
}

# MIDI::RtController spawns its blocking read loop (_rtmidi_loop) as a
# genuine child OS process, internally, on every ->new -- this isn't
# something our code controls. Simply dropping our reference to a
# $controller object (letting it fall out of scope) does NOT reliably
# terminate that worker; something continues to keep it alive. Until/
# unless MIDI::RtController exposes an explicit shutdown method, we
# reap these ourselves: find our own process's direct children whose
# command line mentions _rtmidi_loop, and kill them.
sub _kill_stray_workers () {
    open my $fh, '-|', 'pgrep', '-P', $$ or return;
    chomp(my @kids = <$fh>);
    close $fh;
    return unless @kids;

    my @workers;
    for my $pid (@kids) {
        open my $cmd_fh, '-|', 'ps', '-o', 'command=', '-p', $pid or next;
        my $cmdline = <$cmd_fh> // '';
        close $cmd_fh;
        push @workers, $pid if $cmdline =~ /_rtmidi_loop/;
    }
    return unless @workers;

    kill('TERM', @workers);
    for (1 .. 20) { # give them up to ~1s to exit cleanly
        last unless grep { kill(0, $_) } @workers;
        select(undef, undef, undef, 0.05);
    }
    kill('KILL', grep { kill(0, $_) } @workers);
}

sub _filter_spec ($f, $input) {
    my %spec = (
        port  => $input,
        type  => $f->{filter} || 'single',
        event => 'all',
    );
    for my $field (qw(channel control trigger value initial_point
                       range_bottom range_top range_step time_step
                       step_up step_down)) {
        $spec{$field} = $f->{$field} if defined $f->{$field} && length $f->{$field};
    }
    return \%spec;
}

# Rebuilds %controllers from scratch to match the current %running_ids /
# @filters. Filters sharing an (input, output) pair share one controller,
# attached via MIDI::RtController::Filter::CC::add_filters (same mechanism
# as continuous.pl). Returns %errors (filter id => message) for any
# port-group that failed to start; does NOT itself touch %running_ids --
# callers decide whether/how to reconcile and persist that.
sub rebuild_controllers () {
    _stop_controller($_) for values %controllers; # ask nicely first
    %controllers = (); # drop old connections
    _kill_stray_workers(); # ...then make sure their worker processes actually die

    my %by_key;
    for my $f (@filters) {
        next unless $running_ids{ $f->{id} };
        push @{ $by_key{ _port_key($f) } }, $f;
    }

    my %errors;
    for my $key (keys %by_key) {
        my @group = @{ $by_key{$key} };
        my ($input, $output) = split /\0/, $key, 2;
        my $verbose = (grep { $_->{verbose} } @group) ? 1 : 0;

        my $controller = eval {
            MIDI::RtController->new(input => $input, output => $output, verbose => $verbose);
        };
        if (!$controller) {
            my $err = $@ || 'Unknown error';
            $errors{ $_->{id} } = "Can't open '$input' -> '$output': $err" for @group;
            next;
        }

        my @specs = map { _filter_spec($_, $input) } @group;
        eval {
            MIDI::RtController::Filter::CC::add_filters(\@specs, { $input => $controller });
        };
        if ($@) {
            $errors{ $_->{id} } = "Can't configure filter: $@" for @group;
            next;
        }

        $controllers{$key} = $controller;
    }

    return %errors;
}

sub start_filter ($id) {
    my $f = find_filter($id) or die "No such filter\n";
    return if is_running($id);

    with_filters_lock(sub { $running_ids{$id} = 1 });
    my %errors = rebuild_controllers();

    if (my $err = $errors{$id}) {
        with_filters_lock(sub { delete $running_ids{$id} });
        rebuild_controllers(); # drop the broken attempt from live state too
        die "$err\n";
    }
}

sub stop_filter ($id) {
    return unless is_running($id);
    with_filters_lock(sub { delete $running_ids{$id} });
    rebuild_controllers();
}

# Pump every live controller's event loop non-blockingly, inside
# Mojolicious's own reactor -- no threads, no forks, one process.
Mojo::IOLoop->recurring(PUMP_INTERVAL, sub {
    for my $key (keys %controllers) {
        my $c = $controllers{$key};
        eval { $c->loop->loop_once(0) };
        if ($@) {
            warn "MIDI controller for '$key' failed: $@";
            with_filters_lock(sub {
                for my $f (@filters) {
                    delete $running_ids{ $f->{id} } if _port_key($f) eq $key;
                }
            });
            rebuild_controllers(); # rebuilds everything cleanly from corrected state
        }
    }
});

load_state();
load_sets();
rebuild_controllers(); # reattach anything that was running before a restart

hook before_dispatch => sub ($c) {
    load_state();
    load_sets();
};

$SIG{CHLD} = 'IGNORE';

$SIG{INT} = sub {
    say "\nStopping all filters...";
    _stop_controller($_) for values %controllers;
    %controllers = ();
    _kill_stray_workers();
    exit;
};

END {
    _stop_controller($_) for values %controllers;
    %controllers = ();
    _kill_stray_workers();
}

get '/' => sub ($c) {
    $c->stash(
        filters      => \@filters,
        edit         => \%edit_filter,
        filter_types => [FILTER_TYPES],
        inputs       => known_input_ports(),
        outputs      => known_output_ports(),
        running      => { map { $_->{id} => is_running($_->{id}) } @filters },
        saved_sets   => [ sort keys %saved_sets ],
    );
    $c->render('index');
} => 'index';

post '/filters' => sub ($c) {
    my $v = $c->req->params->to_hash;

    my %params;
    $params{name}          = $v->{name} || 'Filter';
    $params{input}         = $v->{input}  || 'joystick';
    $params{output}        = $v->{output} || 'usb';
    $params{filter}        = $v->{filter} || 'breathe';
    $params{channel}       = length($v->{channel} // '')       ? $v->{channel}       : undef;
    $params{control}       = length($v->{control} // '')       ? $v->{control}       : undef;
    $params{trigger}       = length($v->{trigger} // '')       ? $v->{trigger}       : undef;
    $params{value}         = length($v->{value} // '')         ? $v->{value}         : undef;
    $params{initial_point} = length($v->{initial_point} // '') ? $v->{initial_point} : undef;
    $params{range_bottom}  = length($v->{range_bottom} // '')  ? $v->{range_bottom}  : undef;
    $params{range_top}     = length($v->{range_top} // '')     ? $v->{range_top}     : undef;
    $params{range_step}    = length($v->{range_step} // '')    ? $v->{range_step}    : undef;
    $params{time_step}     = length($v->{time_step} // '')     ? $v->{time_step}     : undef;
    $params{step_up}       = length($v->{step_up} // '')       ? $v->{step_up}       : undef;
    $params{step_down}     = length($v->{step_down} // '')     ? $v->{step_down}     : undef;
    $params{verbose}       = $v->{verbose} ? 1 : 0;

    my $running_conflict = 0;

    with_filters_lock(sub {
        if (defined $v->{edit_id} && length $v->{edit_id}) {
            if (my $f = find_filter($v->{edit_id})) {
                if (is_running($f->{id})) { # don't edit while running
                    $running_conflict = 1;
                    return;
                }
                %$f = (%$f, %params, id => $f->{id});
                %edit_filter = ();
                $c->flash(message => "Filter '$f->{name}' updated");
            }
            else {
                %edit_filter = ();
                $c->flash(error => 'Filter no longer exists — edit cancelled');
            }
        }
        else {
            push @filters, { %params, id => $next_id++ };
            $c->flash(message => "Filter '$params{name}' added");
        }
    });

    $c->flash(error => "Can't edit a running filter — stop it first") if $running_conflict;
    $c->redirect_to('/');
} => 'filters';

post '/edit' => sub ($c) {
    my $id = $c->param('edit_id');
    my $f = find_filter($id) or return $c->redirect_to('/');
    return $c->redirect_to('/') if is_running($id); # don't edit while running
    %edit_filter = (%$f);
    $c->redirect_to('/');
} => 'edit';

get '/cancel' => sub ($c) {
    %edit_filter = ();
    $c->redirect_to('/');
} => 'cancel';

post '/delete' => sub ($c) {
    my $id = $c->param('delete_id');
    my $f = find_filter($id) or return $c->redirect_to('/');
    with_filters_lock(sub {
        delete $running_ids{$id};
        @filters = grep { $_->{id} != $id } @filters;
    });
    rebuild_controllers();
    %edit_filter = () if $edit_filter{id} && $edit_filter{id} == $id;
    $c->flash(message => "Filter '$f->{name}' deleted");
    $c->redirect_to('/');
} => 'delete';

post '/start' => sub ($c) {
    my $id = $c->param('id');
    my $f = find_filter($id) or return $c->redirect_to('/');
    try {
        start_filter($id);
        $c->flash(message => "Filter '$f->{name}' started");
    }
    catch ($e) {
        $c->flash(error => "Can't start '$f->{name}': $e");
    }
    $c->redirect_to('/');
} => 'start';

post '/stop' => sub ($c) {
    my $id = $c->param('id');
    my $f = find_filter($id) or return $c->redirect_to('/');
    stop_filter($id);
    $c->flash(message => "Filter '$f->{name}' stopped");
    $c->redirect_to('/');
} => 'stop';

post '/start_all' => sub ($c) {
    with_filters_lock(sub {
        $running_ids{ $_->{id} } = 1 for @filters;
    });
    my %errors = rebuild_controllers();

    if (%errors) {
        with_filters_lock(sub {
            delete $running_ids{$_} for keys %errors;
        });
        rebuild_controllers();
        my @failed = map { (find_filter($_) // {})->{name} // $_ } keys %errors;
        $c->flash(error => 'Failed to start: ' . join(', ', @failed));
    }
    else {
        $c->flash(message => 'Started all filters');
    }
    $c->redirect_to('/');
} => 'start_all';

post '/stop_all' => sub ($c) {
    with_filters_lock(sub { %running_ids = () });
    rebuild_controllers();
    $c->flash(message => 'Stopped all filters');
    $c->redirect_to('/');
} => 'stop_all';

post '/filters/clear' => sub ($c) {
    with_filters_lock(sub {
        %running_ids = ();
        @filters = ();
    });
    rebuild_controllers();
    %edit_filter = (); # any in-progress edit no longer refers to a real filter
    $c->flash(message => 'Cleared all filters');
    $c->redirect_to('/');
} => 'clear_filters';

post '/sets/save' => sub ($c) {
    my $name = $c->param('set_name') // '';
    $name =~ s/^\s+|\s+$//g;

    if (!length $name) {
        $c->flash(error => 'Enter a name to save this set of filters');
        return $c->redirect_to('/');
    }
    if (!@filters) {
        $c->flash(error => 'No filters configured to save');
        return $c->redirect_to('/');
    }

    with_sets_lock(sub {
        # snapshot the current filters, stripped of the per-run 'id'
        # (a fresh id is assigned to each filter when a set is loaded)
        $saved_sets{$name} = [
            map { my %f = %$_; delete $f{id}; \%f } @filters
        ];
    });

    $c->flash(message => "Saved set '$name'");
    $c->redirect_to('/');
} => 'save_set';

post '/sets/load' => sub ($c) {
    my $name = $c->param('set_name') // '';
    my $set  = $saved_sets{$name};

    if (!$set) {
        $c->flash(error => "No such saved set '$name'");
        return $c->redirect_to('/');
    }
    if (grep { is_running($_->{id}) } @filters) {
        $c->flash(error => 'Stop all running filters before loading a set');
        return $c->redirect_to('/');
    }

    with_filters_lock(sub {
        @filters = map { { %$_, id => $next_id++ } } @$set;
    });
    %edit_filter = (); # ids from any in-progress edit no longer apply

    $c->flash(message => "Loaded set '$name'");
    $c->redirect_to('/');
} => 'load_set';

post '/sets/delete' => sub ($c) {
    my $name = $c->param('set_name') // '';

    if (!$saved_sets{$name}) {
        $c->flash(error => "No such saved set '$name'");
        return $c->redirect_to('/');
    }

    with_sets_lock(sub {
        delete $saved_sets{$name};
    });

    $c->flash(message => "Deleted set '$name'");
    $c->redirect_to('/');
} => 'delete_set';

plugin Config => { file => 'midi-filter.conf' };

my $log = Mojo::Log->new(
  path  => app->config->{log_path},
  level => app->config->{log_level},
);
app->log($log);

app->start;
