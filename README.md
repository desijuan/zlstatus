# zlstatus

A minimal, event-driven status monitor for dwl/dwm, inspired by [slstatus](https://tools.suckless.org/slstatus).

![screenshot](https://github.com/desijuan/zlstatus/blob/master/screenshot.png)

## Why?

I’ve been using dwm as my only window manager for several years. To display system information at the top-right corner
of the screen, I’ve relied on slstatus, configured to show battery percentage, volume level, and the current date/time
like this: `B:75 V:95 dom 08 jun 22:13`.

slstatus, in true suckless spirit, is a small and elegant program. It works by updating the root window’s name at
regular intervals, typically once per second.

While this works well, I wanted something more event-driven. For my use case (only battery, volume, and time), polling
every second felt excessive. So I wrote zlstatus, which updates the status string:
- Once per minute (for time and battery)
- Whenever the volume changes (via ALSA events)

## How it works

zlstatus is written in Zig and uses epoll to wait on multiple sources of events efficiently.

### Clock updates

A one-minute timer is set up using timerfd_create, and aligned to fire exactly at the start of each new minute. This
ensures the time display is always in sync with the system clock.

### Volume updates

zlstatus monitors the ALSA Master channel using a file descriptor that becomes readable whenever the volume changes.
This allows instant updates without polling.

### Battery updates

Battery status is read and updated once per minute, alongside the clock.

## Modes of operation

There are 2 modes of operation that have to be defined at compile-time: X11 and Wayland.

In the X11 mode, zlstatus works by setting the name of the root window, this works well with dwm. In the Wayland mode, I
use zlstatus with dwl patched with the [bar](https://codeberg.org/dwl/dwl-patches/src/branch/main/patches/bar) patch.
For that, zlstatus writes directly to stdout, and it is used like this: `zlstatus | dwl`.

## Build

To do a release build:

`zig build -Dmode=MODE -Doptimize=ReleaseSmall --summary all`,

where MODE is either X11 or Wayland (see the [Modes of operation](#modes-of-operation) above). The default build is
Wayland.

To get help about the build options you can do: `zig build -h`.

For convenience there is also a simple Makefile.

## Performance

First I want to make clear that slstatus, as with every other suckless tool that I've used, is a wonderful piece of
code. I really appreciate it, learnt a lot from it. Also slstatus has many features zlstatus lacks. So, with all due
respect, I want to compare my version with my particular usecase in mind.

With that out of the way let me say that zlstatus is half of the size of slstatus. When compiled with the same features
slstatus is around 30K, while zlstatus is approximately 14K. They both use nearly the same RSS, 3K approx.

But zlstatus uses less cpu time:

**slstatus:**
```
real    16m1.609s
user    0m0.163s
sys     0m0.699s
```

**zlstatus:**
```
real    16m1.046s
user    0m0.004s
sys     0m0.011s
```

## Style and language

As I mentioned before, zlstatus is written in Zig. But it is written in a very C style. For this project I didn't use
the Zig's standard library at all and use the C API for epoll and ALSA. The reason for this is that I really like Zig
but for this project I think that the standard library is not mature enough. I wanted zlstatus to be as minimalistic as
possible. So I used Zig as a plain "better C".

## Notes

I have tested zlstatus in both my work computer, in which I have dwm, and also in my personal computer, in which
recently I have installed, trying and enjoying dwl. I use it in both computers daily and it works perfectly. I have to
say though that I use ALSA directly, no Pulseaudio or Pipewire.

I tried using it on an older PC in which I have Pulseaudio and I noticed some problems there. So, if you want to test it
and have Pulseaudio or Pipewire, it may not work correctly. Perhaps in the future I will try addressing that, but I have
to say that I don't like the idea of having an audio server on top of ALSA at all. So, perhaps this never happens xP.
Other than that, if you use only ALSA like me, it should work. Other than ALSA it only depends on epoll(7), which should
be available in any (somewhat) modern Linux installation.

## License

zlstatus is released under the [MIT License](./LICENSE).
