#!/usr/bin/env perl

# A control panel for running any number of MIDI::RtController::Filter::CC
# filters concurrently.

use v5.36;
use feature qw(try);
no warnings qw(experimental::try);

use Mojolicious::Lite -signatures;
use MIDI::RtMidi::FFI::Device ();
use Storable qw(retrieve store);
use FindBin qw($Bin);
use Fcntl qw(:flock);

use constant {
    STATE     => 'midi-filter-state.dat',
    STATELOCK => 'midi-filter-state.lock',
    RUNNER    => "$Bin/filter_runner.pl",
};

use constant FILTER_TYPES => qw(
    single clock_it breathe scatter stair_step ramp_up ramp_down flicker
);

use constant FIELDS => qw(
    name input output filter channel control trigger value
    initial_point range_bottom range_top range_step time_step
    step_up step_down verbose
);

# --- persisted config: the list of configured filters (survives restarts) ---
my @filters;
my $next_id = 1;

# --- transient, per-process only: PIDs of currently running filters ---
my %pid_of;

my %edit_filter; # single record being edited, mirrors phrase-generator's %edit_part

sub load_state () {
    return unless -e STATE;
    my $state = retrieve(STATE);
    @filters = @{ $state->{filters} // [] };
    $next_id = $state->{next_id} // 1;
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

load_state();

hook before_dispatch => sub ($c) {
    load_state();
};

$SIG{INT} = sub {
    say "\nStopping all filters...";
    stop_filter($_->{id}) for @filters;
    exit;
};

END {
    stop_filter($_->{id}) for @filters;
}

sub save_state () {
    my $tmp = STATE . ".$$.tmp";
    store { filters => \@filters, next_id => $next_id }, $tmp;
    rename $tmp, STATE or warn "Can't replace @{[STATE]}: $!\n";
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
    my $pid = $pid_of{$id} or return 0;
    return kill(0, $pid) ? 1 : 0;
}

sub start_filter ($id) {
    my $f = find_filter($id) or die "No such filter\n";
    return if is_running($id);

    my @cmd = ($^X, RUNNER);
    for my $field (qw(input output filter channel control trigger value
                       initial_point range_bottom range_top range_step
                       time_step step_up step_down)) {
        push @cmd, "--$field=$f->{$field}" if defined $f->{$field} && length $f->{$field};
    }
    push @cmd, '--verbose' if $f->{verbose};

    my $pid = fork();
    die "Can't fork: $!\n" unless defined $pid;

    if ($pid == 0) {
        # child
        exec(@cmd) or die "Can't exec @cmd: $!\n";
        exit 1;
    }

    $pid_of{$id} = $pid;
}

sub stop_filter ($id) {
    my $pid = delete $pid_of{$id} or return;
    return unless kill(0, $pid);
    kill('TERM', $pid);
    for (1 .. 20) { # give it up to ~1s to exit cleanly
        last unless kill(0, $pid);
        select(undef, undef, undef, 0.05);
    }
    kill('KILL', $pid) if kill(0, $pid);
}

# reap children so they don't linger as zombies
$SIG{CHLD} = 'IGNORE';

get '/' => sub ($c) {
    $c->stash(
        filters      => \@filters,
        edit         => \%edit_filter,
        filter_types => [FILTER_TYPES],
        inputs       => known_input_ports(),
        outputs      => known_output_ports(),
        running      => { map { $_->{id} => is_running($_->{id}) } @filters },
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
    stop_filter($id);
    with_filters_lock(sub {
        @filters = grep { $_->{id} != $id } @filters;
    });
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
    my @failed;
    for my $f (@filters) {
        try { start_filter($f->{id}) }
        catch ($e) { push @failed, $f->{name} }
    }
    $c->flash(error => 'Failed to start: ' . join(', ', @failed)) if @failed;
    $c->flash(message => 'Started all filters') unless @failed;
    $c->redirect_to('/');
} => 'start_all';

post '/stop_all' => sub ($c) {
    stop_filter($_->{id}) for @filters;
    $c->flash(message => 'Stopped all filters');
    $c->redirect_to('/');
} => 'stop_all';

plugin Config => { file => 'midi-filter.conf' };

my $log = Mojo::Log->new(
  path  => app->config->{log_path},
  level => app->config->{log_level},
);
app->log($log);

app->start;
