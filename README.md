# Mojo-MIDIFilter
Apply MIDI Filters to Open Ports

![UI](MIDIFilter-UI.png)

## Installation

Clone the repo and change to that directory:
```shell
git clone https://github.com/ology/Mojo-MIDIFilter.git
cd Mojo-MIDIFilter/
```

Install the Perl dependencies:
```shell
cpanm --verbose --installdeps .
```

Run the app:
```shell
morbo midi-filter.pl --verbose --listen http://127.0.0.1:3333
# or
hypnotoad midi-filter.pl
```

Browse to http://127.0.0.1:3333/ or wherever hypnotoad is configured for.

Voila! :D

## Notes

To generically control another synth (notes, wheels, everything), set the filter type to "single" and don't set any CC, trigger, range, etc. parameters - just the channel.