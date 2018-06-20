# Game Controller MIDI

Reads continuous controller values from a PS4 controller and sends them out
as MIDI CC messages.  Mac only.

## Usage:

No dependencies beyond the compiler; just run:

```
$ make run
```

This will build it and start it running.  It will present as a midi device
labeled "game controller" which sends CC values.

## Mapping:

```
left linear button:  CC-20
right linear button: CC-21
left joystick:
  left:              CC-22
  right:             CC-23
  up:                CC-24
  down:              CC-25
right joystick:
  left:              CC-26
  right:             CC-27
  up:                CC-28
  down:              CC-29
```

