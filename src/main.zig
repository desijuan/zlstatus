const c = @cImport({
    @cInclude("locale.h");
    @cInclude("unistd.h");
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
    @cInclude("time.h");
    @cInclude("alsa/asoundlib.h");
    @cInclude("sys/timerfd.h");
    @cInclude("sys/epoll.h");
});

const config = @import("config");
const OutMode: type = config.@"build.OutMode";
const out_mode: OutMode = config.out_mode;

const Out: type = switch (out_mode) {
    .X11 => struct {
        const x = @cImport(@cInclude("X11/Xlib.h"));

        var display: ?*x.Display = null;

        inline fn init() void {
            display = x.XOpenDisplay(null);
            if (display == null) @panic("XOpenDisplay");
        }

        inline fn deinit() void {
            _ = x.XStoreName(display, x.DefaultRootWindow(display), null);
            _ = x.XCloseDisplay(display);
            display = null;
        }

        inline fn write() void {
            if (x.XStoreName(display, x.DefaultRootWindow(display), fStatus.ptr) < 0) @panic("XStoreName");
            _ = x.XFlush(display);
        }
    },

    .Wayland => struct {
        inline fn write() void {
            _ = c.write(1, fStatus.ptr, fStatus.len);
        }
    },
};

const FMT_BATVOL = " B:%d V:%d%s ";
const FMT_DATE = "%a %d %b %H:%M ";

const BUF_LEN = 32;
var status_buf: [BUF_LEN]u8 = undefined;
var fStatus: [:0]u8 = undefined;
fn setStatus() void {
    const buf1: []u8 = status_buf[0..];
    const n1: usize = @intCast(c.snprintf(
        buf1.ptr,
        buf1.len,
        FMT_BATVOL,
        fBatCapacity,
        fVolume,
        (if (fIsOn) "" else "M").ptr,
    ));
    if (n1 >= buf1.len) @panic("snprintf");

    const buf2: []u8 = status_buf[n1..];
    const tm_ptr = c.localtime(&fTime.tv_sec);
    const n2: usize = c.strftime(buf2.ptr, buf2.len, FMT_DATE, tm_ptr);
    if (n2 >= buf2.len) @panic("strftime");

    const n = n1 + n2;
    return switch (comptime out_mode) {
        .X11 => {
            fStatus = status_buf[0..n :0];
        },
        .Wayland => {
            status_buf[n] = '\n';
            status_buf[n + 1] = 0;
            fStatus = status_buf[0 .. n + 1 :0];
        },
    };
}

var bcfd: c_int = -1;
var fBatCapacity: u8 = 0;
fn readBatCapacity() void {
    var buf: [8]u8 = undefined;
    _ = c.lseek(bcfd, 0, c.SEEK_SET);
    const n: usize = @intCast(c.read(bcfd, &buf, 8));
    if (n < 1) @panic("read bcfd");

    if (buf[n - 1] == '\n')
        buf[n - 1] = 0
    else
        buf[n] = 0;

    var endptr: [*c]u8 = undefined;
    const value: c_long = c.strtol(&buf, &endptr, 10);
    if (endptr == @as([*c]u8, @ptrCast(&buf))) @panic("strtol");

    fBatCapacity = @intCast(value);
}

var mixer: ?*c.snd_mixer_t = null;
var vol_min: f32 = 0;
var vol_max: f32 = 0;
var is_on: c_int = 1;
var fVolume: u8 = 0;
var fIsOn: bool = true;
fn boolFromInt(value: c_int) bool {
    return switch (value) {
        0 => false,
        else => true,
    };
}
fn readMasterVolume(elem: ?*c.snd_mixer_elem_t, _: c_uint) callconv(.c) c_int {
    var vol_int: c_long = undefined;
    _ = c.snd_mixer_selem_get_playback_volume(elem, c.SND_MIXER_SCHN_FRONT_LEFT, &vol_int);
    const vol: f32 = @floatFromInt(vol_int);
    fVolume = @intFromFloat(@round(100 * (vol - vol_min) / (vol_max - vol_min)));
    _ = c.snd_mixer_selem_get_playback_switch(elem, c.SND_MIXER_SCHN_FRONT_LEFT, &is_on);
    fIsOn = boolFromInt(is_on);
    return 0;
}

var timerfd: c_int = -1;

var fTime: c.timespec = undefined;
fn readTime() void {
    if (c.clock_gettime(c.CLOCK_REALTIME, &fTime) != 0)
        @panic("clock_gettime");
}

const BAT = "/sys/class/power_supply/BAT1/";
const MAX_EVENTS = 8;

pub fn main() u8 {
    if (comptime @hasDecl(Out, "init")) Out.init();
    defer if (comptime @hasDecl(Out, "deinit")) Out.deinit();

    const epollfd: c_int = c.epoll_create1(0);
    if (epollfd < 0) @panic("epoll_create1");
    defer _ = c.close(epollfd);

    // Date and time
    if (c.setlocale(c.LC_TIME, "") == null)
        @panic("setlocale");

    timerfd = c.timerfd_create(c.CLOCK_MONOTONIC, 0);
    if (timerfd < 0) @panic("timerfd_create");
    defer _ = c.close(timerfd);

    readTime();

    const itval = c.itimerspec{ .it_value = .{
        .tv_sec = 60 - @rem(fTime.tv_sec, 60) - 1,
        .tv_nsec = @as(c_long, 1e9) - fTime.tv_nsec,
    }, .it_interval = .{
        .tv_sec = 60,
        .tv_nsec = 0,
    } };

    if (c.timerfd_settime(timerfd, 0, &itval, null) < 0)
        @panic("timerfd_settime");

    var event = c.epoll_event{
        .events = @as(u32, c.EPOLLIN) | c.EPOLLET,
        .data = .{ .u64 = @intFromEnum(EventType.TimeOut1m) },
    };
    if (c.epoll_ctl(epollfd, c.EPOLL_CTL_ADD, timerfd, &event) < 0)
        @panic("epoll_ctl");

    // Battery capacity
    bcfd = c.open(BAT ++ "capacity", c.O_RDONLY);
    if (bcfd < 0) @panic("open BAT capacity");
    defer _ = c.close(bcfd);

    readBatCapacity();

    // ALSA
    if (c.snd_mixer_open(&mixer, 0) < 0 or
        c.snd_mixer_attach(mixer, "default") < 0 or
        c.snd_mixer_selem_register(mixer, null, null) < 0 or
        c.snd_mixer_load(mixer) < 0)
        @panic("Failed to setup ALSA mixer");
    defer _ = c.snd_mixer_close(mixer);

    var elem: ?*c.snd_mixer_elem_t = c.snd_mixer_first_elem(mixer);
    while (elem) |_| : (elem = c.snd_mixer_elem_next(elem)) {
        if (c.strcmp("Master", c.snd_mixer_selem_get_name(elem)) == 0) {
            var min: c_long = undefined;
            var max: c_long = undefined;
            _ = c.snd_mixer_selem_get_playback_volume_range(elem, &min, &max);
            vol_min = @floatFromInt(min);
            vol_max = @floatFromInt(max);

            c.snd_mixer_elem_set_callback(elem, readMasterVolume);
            _ = readMasterVolume(elem, 0);

            break;
        }
    } else @panic("Master channel not found");

    var alsafd: c.pollfd = undefined;
    if (c.snd_mixer_poll_descriptors(mixer, &alsafd, 1) != 1)
        @panic("snd_mixer_poll_descriptors");
    event = c.epoll_event{
        .events = @as(u32, c.EPOLLIN) | c.EPOLLET,
        .data = .{ .u64 = @intFromEnum(EventType.VolChange) },
    };
    if (c.epoll_ctl(epollfd, c.EPOLL_CTL_ADD, alsafd.fd, &event) < 0)
        @panic("epoll_ctl");

    setStatus();
    Out.write();

    // Main epoll loop
    var events: [MAX_EVENTS]c.epoll_event = undefined;
    while (true)
        for (0..@intCast(c.epoll_wait(epollfd, &events, MAX_EVENTS, -1))) |i| {
            const ev: c.epoll_event = events[i];
            @as(EventType, @enumFromInt(ev.data.u64)).handleEvent();
            setStatus();
            Out.write();
        };

    return 0;
}

const EventType = enum(u8) {
    TimeOut1m,
    VolChange,

    fn handleEvent(self: EventType) void {
        switch (self) {
            .TimeOut1m => {
                readTime();
                var buf: [8]u8 = undefined;
                _ = c.read(timerfd, &buf, 8);
                readBatCapacity();
            },

            .VolChange => _ = c.snd_mixer_handle_events(mixer),
        }
    }
};
