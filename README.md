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

Write-up: https://ology.github.io/2026/08/21/loving-the-kaoss-pad-v/

To generically control another synth (notes, wheels, everything), just don't set any CC, trigger, range, etc. parameters - just the channel.