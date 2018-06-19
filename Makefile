gcmidi: gcmidi.m
	gcc \
    -F/System/Library/PrivateFrameworks \
	  -framework CoreMIDI \
    -framework CoreFoundation \
    -framework CoreAudio \
    -framework Foundation \
    -framework IOKit \
	  gcmidi.m -o gcmidi -std=c99 -Wall

run: gcmidi
	./gcmidi
