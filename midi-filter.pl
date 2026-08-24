#!/usr/bin/env perl

use v5.36;
use feature qw(try);

use Mojolicious::Lite -signatures;
use Mojo::IOLoop ();
use MIDI::RtMidi::FFI::Device ();
use MIDI::RtController ();
use MIDI::RtController::Filter::CC ();
use Storable qw(retrieve store);
use Fcntl qw(:flock);

no warnings qw(experimental::try);

use constant {
    STATE     => 'midi-filter-state.dat',
    STATELOCK => 'midi-filter-state.lock',
    SETS      => 'midi-filter-sets.dat',
    SETSLOCK  => 'midi-filter-sets.lock',
    SESSION_EXPIRATION => 60 * 60 * 24 * 14, # 14 days
    PUMP_INTERVAL => 0.005, # how often in seconds to pump each live MIDI::RtController's event loop
};
use constant FILTER_TYPES => qw(
    single clock_it breathe scatter stair_step ramp_up ramp_down flicker
);
use constant FIELDS => qw(
    name input output filter channel control trigger value
    initial_point range_bottom range_top range_step time_step
    step_up step_down verbose
);

my @filters;
my $next_id = 1;
my $current_set_name;
my %saved_sets;
my %running_ids;
my %controllers;
my %worker_pid;
my %edit_filter; # single record being edited

sub load_state () {
    return unless -e STATE;
    my $state = retrieve(STATE);
    @filters          = @{ $state->{filters} // [] };
    $next_id          = $state->{next_id} // 1;
    %running_ids      = %{ $state->{running} // {} };
    $current_set_name = $state->{current_set};
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

    try {
        load_state();
        $code->();
        save_state();
    }
    catch ($e) {
        die $e; # preserve the original failure for the caller
    }
    finally {
        close $lock_fh; # always releases the lock, even if $code->() dies
    }
}

sub with_sets_lock ($code) {
    open my $lock_fh, '>', SETSLOCK or die "Can't open @{[SETSLOCK]}: $!\n";
    flock($lock_fh, LOCK_EX) or die "Can't lock @{[SETSLOCK]}: $!\n";

    try {
        load_sets();
        $code->();
        save_sets();
    }
    catch ($e) {
        die $e; # preserve the original failure for the caller
    }
    finally {
        close $lock_fh; # always releases the lock, even if $code->() dies
    }
}

sub save_state () {
    my $tmp = STATE . ".$$.tmp";
    store {
        filters     => \@filters,
        next_id     => $next_id,
        running     => \%running_ids,
        current_set => $current_set_name,
    }, $tmp;
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

sub _direct_children () {
    # Using 'ps -U <current_user>' grabs all tasks run by you
    my $user = $ENV{USER} || 'gene';
    open my $fh, '-|', 'ps', '-U', $user, '-o', 'pid=' or do {
        app->log->info("ps query failed to run: $!");
        return ();
    };
    chomp(my @kids = <$fh>);
    close $fh;
    # Clean up whitespace padding from the process list
    return map { s/^\s+|\s+$//g; $_ } @kids;
}

sub _stop_controller ($key) {
    my $controller = $controllers{$key} or return;
    eval { $controller->stop };
    app->log->info("controller->stop failed for '$key': $@") if $@;
    _stop_worker($key);
}

sub _stop_worker ($key) {
    my $pid = delete $worker_pid{$key} or return;

    app->log->info("Targeted cleanup: Sending TERM to worker PID $pid for '$key'");

    kill('TERM', $pid);

    # Wait explicitly for this child using non-blocking waitpid
    for (1 .. 20) { 
        my $res = waitpid($pid, 1); # WNOHANG = 1
        last if $res == $pid || $res == -1;
        select(undef, undef, undef, 0.05);
    }

    # Ultimate fallback if it refuses to close
    if (kill(0, $pid)) {
        app->log->info("Worker PID $pid stubborn after TERM. Escalating to KILL.");
        kill('KILL', $pid);
        waitpid($pid, 0); # Block briefly to guarantee it reaps
    }
}

sub _kill_stray_workers () {
    my @all_pids = _direct_children();

    my @workers;
    for my $pid (@all_pids) {
        next if $pid == $$; # Absolutely skip killing our own Mojolicious server!

        if (open my $cmd_fh, '-|', 'ps', '-ww', '-o', 'command=', '-p', $pid) {
            my $cmdline = <$cmd_fh> // '';
            close $cmd_fh;

            # Match the exact IO::Async channel setup strings seen in the ps logs
            if ($cmdline =~ /MIDI::RtController|_rtmidi_loop|IO::Async::Channel/i) {
                push @workers, $pid;
            }
        }
    }

    return unless @workers;
    app->log->info("Killing unlinked asynchronous worker processes: @workers");

    kill('TERM', @workers);
    for (1 .. 25) {
        @workers = grep { kill(0, $_) } @workers;
        last unless @workers;
        select(undef, undef, undef, 0.04);
    }

    if (@workers) {
        app->log->info("Forcing absolute KILL on lingering loops: @workers");
        kill('KILL', @workers);
        waitpid($_, 1) for @workers;
    }
}

sub _filter_spec ($f, $input) {
    my %spec = (
        port  => $input,
        type  => $f->{filter} || 'single',
        event => 'all',
    );
    for my $field (qw(channel control trigger value initial_point
        range_bottom range_top range_step time_step
        step_up step_down))
    {
        $spec{$field} = $f->{$field} if defined $f->{$field} && length $f->{$field};
    }
    return \%spec;
}

sub rebuild_controllers () {
    app->log->info("rebuild_controllers: stopping " . scalar(keys %controllers) . " existing controller(s)");
    _stop_controller($_) for keys %controllers;
    %controllers = ();
    _kill_stray_workers(); # catch anything our tracking missed

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

        my %before = map { $_ => 1 } _direct_children();
        my $controller = eval {
            MIDI::RtController->new(input => $input, output => $output, verbose => $verbose);
        };
        if (!$controller) {
            my $err = $@ || 'Unknown error';
            $errors{ $_->{id} } = "Can't open '$input' -> '$output': $err" for @group;
            next;
        }

        # The worker process isn't spawned synchronously inside ->new --
        # it's deferred until the controller's own loop first ticks. Pump
        # it here (up to ~1s) so the spawn actually happens before we try
        # to capture its PID by diffing our child-process list.
        my $new_pid;
        for (1 .. 20) {
            eval { $controller->loop->loop_once(0) };
            ($new_pid) = grep { !$before{$_} } _direct_children();
            last if $new_pid;
            select(undef, undef, undef, 0.05);
        }
        if ($new_pid) {
            $worker_pid{$key} = $new_pid;
            app->log->info("Started worker PID $new_pid for '$key'");
        }
        else {
            app->log->info("WARNING: no new worker PID detected for '$key' after construction (waited up to 1s)");
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
    my $f = find_filter($id) or return;
    return unless is_running($id);

    my $key = _port_key($f);
    with_filters_lock(sub { delete $running_ids{$id} });

    # Forcefully shut down and delete the object reference immediately
    if ($controllers{$key}) {
        _stop_controller($key);
        delete $controllers{$key};
    }

    rebuild_controllers();
}

Mojo::IOLoop->recurring(PUMP_INTERVAL, sub {
    for my $key (keys %controllers) {
        # Skip if the controller was deleted by a stop action mid-tick
        my $c = $controllers{$key} or next; 

        eval { $c->loop->loop_once(0) };
        if ($@) {
            warn "MIDI controller for '$key' failed: $@";
            with_filters_lock(sub {
                for my $f (@filters) {
                    delete $running_ids{ $f->{id} } if _port_key($f) eq $key;
                }
            });
            _stop_controller($key);
            delete $controllers{$key};
            rebuild_controllers(); 
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

$SIG{CHLD} = 'DEFAULT';
$SIG{INT}  = sub {
    say "\nStopping all filters...";
    _stop_controller($_) for keys %controllers;
    %controllers = ();
    _kill_stray_workers();
    exit;
};

END {
    _stop_controller($_) for keys %controllers;
    %controllers = ();
    _kill_stray_workers();
}

sub _require_csrf ($c) {
    my $v = $c->validation;
    $v->csrf_protect;
    if ($v->has_error('csrf_token')) {
        $c->flash(error => 'Your session expired — please try again');
        $c->redirect_to('/');
        return 0;
    }
    return 1;
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
        current_set  => $current_set_name,
        any_running  => (grep { is_running($_->{id}) } @filters) ? 1 : 0,
    );
    $c->render('index');
} => 'index';

post '/filters' => sub ($c) {
    return unless _require_csrf($c);

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
                $current_set_name = undef;
                $c->flash(message => "Filter '$f->{name}' updated");
            }
            else {
                %edit_filter = ();
                $c->flash(error => 'Filter no longer exists — edit cancelled');
            }
        }
        else {
            push @filters, { %params, id => $next_id++ };
            $current_set_name = undef;
            $c->flash(message => "Filter '$params{name}' added");
        }
    });

    $c->flash(error => "Can't edit a running filter — stop it first") if $running_conflict;
    $c->redirect_to('/');
} => 'filters';

post '/edit' => sub ($c) {
    return unless _require_csrf($c);

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
    return unless _require_csrf($c);

    my $id = $c->param('delete_id');
    my $f = find_filter($id) or return $c->redirect_to('/');
    with_filters_lock(sub {
        delete $running_ids{$id};
        @filters = grep { $_->{id} != $id } @filters;
        $current_set_name = undef;
    });
    rebuild_controllers();
    %edit_filter = () if $edit_filter{id} && $edit_filter{id} == $id;
    $c->flash(message => "Filter '$f->{name}' deleted");
    $c->redirect_to('/');
} => 'delete';

post '/start_all' => sub ($c) {
    return unless _require_csrf($c);

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
    return unless _require_csrf($c);

    with_filters_lock(sub { %running_ids = () });

    # Stop every individual controller instance explicitly 
    for my $key (keys %controllers) {
        _stop_controller($key);
        delete $controllers{$key};
    }

    %controllers = ();
    rebuild_controllers();

    $c->flash(message => 'Stopped all filters');
    $c->redirect_to('/');
} => 'stop_all';

post '/filters/clear' => sub ($c) {
    return unless _require_csrf($c);

    with_filters_lock(sub {
        %running_ids = ();
        @filters = ();
        $current_set_name = undef;
    });
    rebuild_controllers();
    %edit_filter = (); # any in-progress edit no longer refers to a real filter
    $c->flash(message => 'Cleared all filters');
    $c->redirect_to('/');
} => 'clear_filters';

post '/sets/save' => sub ($c) {
    return unless _require_csrf($c);

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

    # The filters just saved now match this set, so mark it current.
    # Separate lock (own state file) from with_sets_lock above.
    with_filters_lock(sub { $current_set_name = $name });

    $c->flash(message => "Saved set '$name'");
    $c->redirect_to('/');
} => 'save_set';

post '/sets/load' => sub ($c) {
    return unless _require_csrf($c);

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
        $current_set_name = $name;
    });
    %edit_filter = (); # ids from any in-progress edit no longer apply

    $c->flash(message => "Loaded set '$name'");
    $c->redirect_to('/');
} => 'load_set';

post '/sets/delete' => sub ($c) {
    return unless _require_csrf($c);

    my $name = $c->param('set_name') // '';

    if (!$saved_sets{$name}) {
        $c->flash(error => "No such saved set '$name'");
        return $c->redirect_to('/');
    }

    with_sets_lock(sub {
        delete $saved_sets{$name};
    });
    with_filters_lock(sub {
        $current_set_name = undef if defined $current_set_name && $current_set_name eq $name;
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

app->sessions->default_expiration(SESSION_EXPIRATION);

app->start;
